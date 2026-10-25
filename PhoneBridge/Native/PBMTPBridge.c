//
//  PBMTPBridge.c
//  PhoneBridge
//

#include "PBMTPBridge.h"

#include <libmtp.h>
#include <libusb.h>

#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct pb_device {
    LIBMTP_mtpdevice_t *mtp;
};

static pthread_once_t pb_init_once = PTHREAD_ONCE_INIT;
// libmtp's device-open path touches process-wide libusb state; opening two
// devices at the same time is not something libmtp promises to support.
static pthread_mutex_t pb_open_lock = PTHREAD_MUTEX_INITIALIZER;
static libusb_context *pb_usb_context = NULL;
static int pb_usb_init_result = LIBUSB_ERROR_OTHER;

static char pb_unknown_vendor[] = "Unknown";
static char pb_unknown_product[] = "Unknown";

static void pb_do_initialize(void) {
    LIBMTP_Set_Debug(LIBMTP_DEBUG_NONE);
    LIBMTP_Init();
    pb_usb_init_result = libusb_init_context(&pb_usb_context, NULL, 0);
}

void pb_initialize(void) {
    pthread_once(&pb_init_once, pb_do_initialize);
}

const char *pb_libmtp_version(void) {
    return LIBMTP_VERSION_STRING;
}

const char *pb_error_message(const pb_error *error) {
    return error ? error->message : "";
}

static void pb_set_error(pb_error *error, pb_status status, int32_t native_code, const char *format, ...) {
    if (error == NULL) {
        return;
    }
    error->status = status;
    error->native_code = native_code;
    va_list args;
    va_start(args, format);
    vsnprintf(error->message, sizeof(error->message), format, args);
    va_end(args);
}

static void pb_clear_error(pb_error *error) {
    if (error == NULL) {
        return;
    }
    error->status = PB_STATUS_OK;
    error->native_code = 0;
    error->message[0] = '\0';
}

static char *pb_strdup_or_null(const char *value) {
    return value ? strdup(value) : NULL;
}

// MARK: - libusb helpers

static pb_status pb_status_from_libusb(int code) {
    switch (code) {
    case LIBUSB_SUCCESS: return PB_STATUS_OK;
    case LIBUSB_ERROR_ACCESS: return PB_STATUS_ACCESS_DENIED;
    case LIBUSB_ERROR_BUSY: return PB_STATUS_BUSY;
    case LIBUSB_ERROR_NO_DEVICE: return PB_STATUS_NO_DEVICE;
    case LIBUSB_ERROR_NOT_FOUND: return PB_STATUS_NOT_FOUND;
    case LIBUSB_ERROR_TIMEOUT: return PB_STATUS_TIMEOUT;
    case LIBUSB_ERROR_NO_MEM: return PB_STATUS_MEMORY;
    case LIBUSB_ERROR_INVALID_PARAM: return PB_STATUS_INVALID_ARGUMENT;
    default: return PB_STATUS_USB_LAYER;
    }
}

int32_t pb_usb_device_count(void) {
    pb_initialize();
    if (pb_usb_init_result != LIBUSB_SUCCESS || pb_usb_context == NULL) {
        return pb_usb_init_result;
    }
    libusb_device **list = NULL;
    ssize_t count = libusb_get_device_list(pb_usb_context, &list);
    if (count >= 0) {
        libusb_free_device_list(list, 1);
    }
    return (int32_t)count;
}

/// Returns the number of the first interface that looks like an MTP/PTP data
/// interface (bulk IN + bulk OUT + interrupt IN), or -1. The ADB interface has
/// no interrupt endpoint and is therefore skipped.
static int pb_find_mtp_interface(libusb_device *device) {
    struct libusb_config_descriptor *config = NULL;
    if (libusb_get_active_config_descriptor(device, &config) != LIBUSB_SUCCESS) {
        if (libusb_get_config_descriptor(device, 0, &config) != LIBUSB_SUCCESS) {
            return -1;
        }
    }

    int fallback = -1;
    int preferred = -1;
    for (uint8_t i = 0; i < config->bNumInterfaces && preferred < 0; i++) {
        const struct libusb_interface *interface = &config->interface[i];
        if (interface->num_altsetting < 1) {
            continue;
        }
        const struct libusb_interface_descriptor *alt = &interface->altsetting[0];
        bool bulk_in = false, bulk_out = false, interrupt_in = false;
        for (uint8_t e = 0; e < alt->bNumEndpoints; e++) {
            const struct libusb_endpoint_descriptor *endpoint = &alt->endpoint[e];
            uint8_t type = endpoint->bmAttributes & LIBUSB_TRANSFER_TYPE_MASK;
            bool is_in = (endpoint->bEndpointAddress & LIBUSB_ENDPOINT_DIR_MASK) == LIBUSB_ENDPOINT_IN;
            if (type == LIBUSB_TRANSFER_TYPE_BULK) {
                if (is_in) bulk_in = true; else bulk_out = true;
            } else if (type == LIBUSB_TRANSFER_TYPE_INTERRUPT && is_in) {
                interrupt_in = true;
            }
        }
        if (!(bulk_in && bulk_out && interrupt_in)) {
            continue;
        }
        if (alt->bInterfaceClass == LIBUSB_CLASS_IMAGE || alt->bInterfaceClass == LIBUSB_CLASS_VENDOR_SPEC) {
            preferred = alt->bInterfaceNumber;
        } else if (fallback < 0) {
            fallback = alt->bInterfaceNumber;
        }
    }
    libusb_free_config_descriptor(config);
    return preferred >= 0 ? preferred : fallback;
}

pb_status pb_usb_preflight(uint32_t bus, uint8_t address, pb_error *error) {
    pb_initialize();
    pb_clear_error(error);

    if (pb_usb_init_result != LIBUSB_SUCCESS || pb_usb_context == NULL) {
        pb_set_error(error, PB_STATUS_USB_LAYER, pb_usb_init_result,
                     "libusb initialisation failed: %s", libusb_error_name(pb_usb_init_result));
        return PB_STATUS_USB_LAYER;
    }

    libusb_device **list = NULL;
    ssize_t count = libusb_get_device_list(pb_usb_context, &list);
    if (count < 0) {
        pb_set_error(error, pb_status_from_libusb((int)count), (int32_t)count,
                     "libusb could not list devices: %s", libusb_error_name((int)count));
        return error ? error->status : PB_STATUS_USB_LAYER;
    }

    libusb_device *found = NULL;
    for (ssize_t i = 0; i < count; i++) {
        if (libusb_get_bus_number(list[i]) == bus && libusb_get_device_address(list[i]) == address) {
            found = libusb_ref_device(list[i]);
            break;
        }
    }
    libusb_free_device_list(list, 1);

    if (found == NULL) {
        pb_set_error(error, PB_STATUS_NO_DEVICE, LIBUSB_ERROR_NO_DEVICE,
                     "No USB device at bus %u address %u", bus, address);
        return PB_STATUS_NO_DEVICE;
    }

    pb_status result = PB_STATUS_OK;
    int interface_number = pb_find_mtp_interface(found);
    if (interface_number < 0) {
        pb_set_error(error, PB_STATUS_NO_INTERFACE, 0, "The device exposes no MTP/PTP data interface");
        libusb_unref_device(found);
        return PB_STATUS_NO_INTERFACE;
    }

    libusb_device_handle *handle = NULL;
    int rc = libusb_open(found, &handle);
    if (rc != LIBUSB_SUCCESS) {
        result = pb_status_from_libusb(rc);
        pb_set_error(error, result, rc, "libusb_open failed: %s", libusb_error_name(rc));
        libusb_unref_device(found);
        return result;
    }

    rc = libusb_claim_interface(handle, interface_number);
    if (rc == LIBUSB_SUCCESS) {
        libusb_release_interface(handle, interface_number);
    } else if (rc == LIBUSB_ERROR_ACCESS || rc == LIBUSB_ERROR_BUSY) {
        // On macOS the darwin backend reports kIOReturnExclusiveAccess as
        // LIBUSB_ERROR_ACCESS: another process holds the interface open.
        result = PB_STATUS_BUSY;
        pb_set_error(error, result, rc, "MTP interface %d is claimed by another process (%s)",
                     interface_number, libusb_error_name(rc));
    } else {
        result = pb_status_from_libusb(rc);
        pb_set_error(error, result, rc, "libusb_claim_interface(%d) failed: %s",
                     interface_number, libusb_error_name(rc));
    }

    libusb_close(handle);
    libusb_unref_device(found);
    return result;
}

// MARK: - libmtp helpers

static pb_status pb_status_from_libmtp(LIBMTP_error_number_t number) {
    switch (number) {
    case LIBMTP_ERROR_NONE: return PB_STATUS_OK;
    case LIBMTP_ERROR_PTP_LAYER: return PB_STATUS_PTP_LAYER;
    case LIBMTP_ERROR_USB_LAYER: return PB_STATUS_USB_LAYER;
    case LIBMTP_ERROR_MEMORY_ALLOCATION: return PB_STATUS_MEMORY;
    case LIBMTP_ERROR_NO_DEVICE_ATTACHED: return PB_STATUS_NO_DEVICE;
    case LIBMTP_ERROR_STORAGE_FULL: return PB_STATUS_STORAGE_FULL;
    case LIBMTP_ERROR_CONNECTING: return PB_STATUS_OPEN_FAILED;
    case LIBMTP_ERROR_CANCELLED: return PB_STATUS_CANCELLED;
    case LIBMTP_ERROR_GENERAL:
    default: return PB_STATUS_GENERAL;
    }
}

/// Moves the newest libmtp error into `error` and clears libmtp's error stack.
/// Returns false when the stack was empty.
static bool pb_take_errorstack(LIBMTP_mtpdevice_t *mtp, pb_error *error, const char *context) {
    LIBMTP_error_t *stack = LIBMTP_Get_Errorstack(mtp);
    if (stack == NULL) {
        return false;
    }
    LIBMTP_error_t *last = stack;
    while (last->next != NULL) {
        last = last->next;
    }
    pb_set_error(error, pb_status_from_libmtp(last->errornumber), (int32_t)last->errornumber,
                 "%s: %s", context, last->error_text ? last->error_text : "unknown libmtp error");
    LIBMTP_Clear_Errorstack(mtp);
    return true;
}

pb_device *pb_open(uint32_t bus, uint8_t address, uint16_t vendor_id, uint16_t product_id, pb_error *error) {
    pb_initialize();
    pb_clear_error(error);

    LIBMTP_raw_device_t raw;
    memset(&raw, 0, sizeof(raw));
    raw.bus_location = bus;
    raw.devnum = address;
    raw.device_entry.vendor = pb_unknown_vendor;
    raw.device_entry.product = pb_unknown_product;
    raw.device_entry.vendor_id = vendor_id;
    raw.device_entry.product_id = product_id;

    // Reuse libmtp's quirk flags for known devices without letting libmtp probe
    // every USB device on the bus (LIBMTP_Detect_Raw_Devices would do that).
    // Unknown Android devices get DEVICE_FLAGS_ANDROID_BUGS from libmtp itself
    // once it sees the "android.com" vendor extension.
    LIBMTP_device_entry_t *entries = NULL;
    int entry_count = 0;
    if (LIBMTP_Get_Supported_Devices_List(&entries, &entry_count) == 0) {
        for (int i = 0; i < entry_count; i++) {
            if (entries[i].vendor_id == vendor_id && entries[i].product_id == product_id) {
                raw.device_entry = entries[i];
                break;
            }
        }
    }

    pthread_mutex_lock(&pb_open_lock);
    LIBMTP_mtpdevice_t *mtp = LIBMTP_Open_Raw_Device_Uncached(&raw);
    pthread_mutex_unlock(&pb_open_lock);

    if (mtp == NULL) {
        pb_set_error(error, PB_STATUS_OPEN_FAILED, LIBMTP_ERROR_CONNECTING,
                     "libmtp could not open an MTP session on %04x:%04x (bus %u, address %u)",
                     vendor_id, product_id, bus, address);
        return NULL;
    }
    LIBMTP_Clear_Errorstack(mtp);

    pb_device *device = calloc(1, sizeof(pb_device));
    if (device == NULL) {
        LIBMTP_Release_Device(mtp);
        pb_set_error(error, PB_STATUS_MEMORY, 0, "Out of memory");
        return NULL;
    }
    device->mtp = mtp;
    return device;
}

void pb_close(pb_device *device) {
    if (device == NULL) {
        return;
    }
    if (device->mtp != NULL) {
        LIBMTP_Release_Device(device->mtp);
        device->mtp = NULL;
    }
    free(device);
}

void pb_get_device_info(pb_device *device, pb_device_info *out_info) {
    if (out_info == NULL) {
        return;
    }
    memset(out_info, 0, sizeof(*out_info));
    out_info->battery_percent = -1;
    if (device == NULL || device->mtp == NULL) {
        return;
    }
    LIBMTP_mtpdevice_t *mtp = device->mtp;

    // libmtp returns freshly allocated strings; ownership moves to out_info.
    out_info->manufacturer = LIBMTP_Get_Manufacturername(mtp);
    out_info->model = LIBMTP_Get_Modelname(mtp);
    out_info->serial_number = LIBMTP_Get_Serialnumber(mtp);
    out_info->device_version = LIBMTP_Get_Deviceversion(mtp);
    out_info->friendly_name = LIBMTP_Get_Friendlyname(mtp);

    uint8_t maximum = 0, current = 0;
    if (LIBMTP_Get_Batterylevel(mtp, &maximum, &current) == 0 && maximum > 0) {
        out_info->battery_percent = (int32_t)((current * 100) / maximum);
    }
    // Missing optional properties (friendly name, battery) are not errors.
    LIBMTP_Clear_Errorstack(mtp);
}

void pb_free_device_info(pb_device_info *info) {
    if (info == NULL) {
        return;
    }
    free(info->manufacturer);
    free(info->model);
    free(info->serial_number);
    free(info->device_version);
    free(info->friendly_name);
    memset(info, 0, sizeof(*info));
    info->battery_percent = -1;
}

pb_status pb_list_storages(pb_device *device, pb_storage **out_storages, size_t *out_count, pb_error *error) {
    pb_clear_error(error);
    if (out_storages == NULL || out_count == NULL) {
        pb_set_error(error, PB_STATUS_INVALID_ARGUMENT, 0, "Invalid arguments");
        return PB_STATUS_INVALID_ARGUMENT;
    }
    *out_storages = NULL;
    *out_count = 0;
    if (device == NULL || device->mtp == NULL) {
        pb_set_error(error, PB_STATUS_NO_DEVICE, 0, "Session is closed");
        return PB_STATUS_NO_DEVICE;
    }
    LIBMTP_mtpdevice_t *mtp = device->mtp;
    LIBMTP_Clear_Errorstack(mtp);

    if (LIBMTP_Get_Storage(mtp, LIBMTP_STORAGE_SORTBY_NOTSORTED) < 0) {
        if (pb_take_errorstack(mtp, error, "LIBMTP_Get_Storage")) {
            return error ? error->status : PB_STATUS_GENERAL;
        }
        // libmtp returns -1 without an error entry when the device reports zero
        // storages. Android does exactly that while the screen is locked.
        return PB_STATUS_OK;
    }

    size_t count = 0;
    for (LIBMTP_devicestorage_t *s = mtp->storage; s != NULL; s = s->next) {
        count++;
    }
    if (count == 0) {
        return PB_STATUS_OK;
    }

    pb_storage *storages = calloc(count, sizeof(pb_storage));
    if (storages == NULL) {
        pb_set_error(error, PB_STATUS_MEMORY, 0, "Out of memory");
        return PB_STATUS_MEMORY;
    }
    size_t index = 0;
    for (LIBMTP_devicestorage_t *s = mtp->storage; s != NULL; s = s->next, index++) {
        storages[index].storage_id = s->id;
        storages[index].storage_type = s->StorageType;
        storages[index].filesystem_type = s->FilesystemType;
        storages[index].access_capability = s->AccessCapability;
        storages[index].max_capacity = s->MaxCapacity;
        storages[index].free_space = s->FreeSpaceInBytes;
        storages[index].description = pb_strdup_or_null(s->StorageDescription);
        storages[index].volume_identifier = pb_strdup_or_null(s->VolumeIdentifier);
    }
    *out_storages = storages;
    *out_count = count;
    return PB_STATUS_OK;
}

void pb_free_storages(pb_storage *storages, size_t count) {
    if (storages == NULL) {
        return;
    }
    for (size_t i = 0; i < count; i++) {
        free(storages[i].description);
        free(storages[i].volume_identifier);
    }
    free(storages);
}

pb_status pb_list_folder(pb_device *device, uint32_t storage_id, uint32_t parent_id,
                         pb_object **out_objects, size_t *out_count, pb_error *error) {
    pb_clear_error(error);
    if (out_objects == NULL || out_count == NULL) {
        pb_set_error(error, PB_STATUS_INVALID_ARGUMENT, 0, "Invalid arguments");
        return PB_STATUS_INVALID_ARGUMENT;
    }
    *out_objects = NULL;
    *out_count = 0;
    if (device == NULL || device->mtp == NULL) {
        pb_set_error(error, PB_STATUS_NO_DEVICE, 0, "Session is closed");
        return PB_STATUS_NO_DEVICE;
    }
    LIBMTP_mtpdevice_t *mtp = device->mtp;
    LIBMTP_Clear_Errorstack(mtp);

    LIBMTP_file_t *files = LIBMTP_Get_Files_And_Folders(mtp, storage_id, parent_id);
    if (files == NULL) {
        // NULL means either "empty folder" or "error"; only the error stack tells.
        if (pb_take_errorstack(mtp, error, "LIBMTP_Get_Files_And_Folders")) {
            return error ? error->status : PB_STATUS_GENERAL;
        }
        return PB_STATUS_OK;
    }

    size_t count = 0;
    for (LIBMTP_file_t *f = files; f != NULL; f = f->next) {
        count++;
    }
    pb_object *objects = calloc(count, sizeof(pb_object));
    if (objects == NULL) {
        while (files != NULL) {
            LIBMTP_file_t *next = files->next;
            LIBMTP_destroy_file_t(files);
            files = next;
        }
        pb_set_error(error, PB_STATUS_MEMORY, 0, "Out of memory");
        return PB_STATUS_MEMORY;
    }

    size_t index = 0;
    LIBMTP_file_t *file = files;
    while (file != NULL) {
        objects[index].object_id = file->item_id;
        objects[index].parent_id = file->parent_id;
        objects[index].storage_id = file->storage_id;
        objects[index].size = file->filesize;
        objects[index].modified = (int64_t)file->modificationdate;
        objects[index].is_folder = file->filetype == LIBMTP_FILETYPE_FOLDER;
        objects[index].filetype = (int32_t)file->filetype;
        objects[index].name = pb_strdup_or_null(file->filename);
        index++;
        LIBMTP_file_t *next = file->next;
        LIBMTP_destroy_file_t(file);
        file = next;
    }
    LIBMTP_Clear_Errorstack(mtp);

    *out_objects = objects;
    *out_count = count;
    return PB_STATUS_OK;
}

void pb_free_objects(pb_object *objects, size_t count) {
    if (objects == NULL) {
        return;
    }
    for (size_t i = 0; i < count; i++) {
        free(objects[i].name);
    }
    free(objects);
}

// MARK: - Capabilities

uint32_t pb_capabilities(pb_device *device) {
    if (device == NULL || device->mtp == NULL) {
        return 0;
    }
    LIBMTP_mtpdevice_t *mtp = device->mtp;
    uint32_t caps = 0;
    if (LIBMTP_Check_Capability(mtp, LIBMTP_DEVICECAP_MoveObject)) caps |= PB_CAP_MOVE_OBJECT;
    if (LIBMTP_Check_Capability(mtp, LIBMTP_DEVICECAP_CopyObject)) caps |= PB_CAP_COPY_OBJECT;
    if (LIBMTP_Check_Capability(mtp, LIBMTP_DEVICECAP_GetPartialObject)) caps |= PB_CAP_PARTIAL_GET;
    if (LIBMTP_Check_Capability(mtp, LIBMTP_DEVICECAP_SendPartialObject)) caps |= PB_CAP_PARTIAL_SEND;
    if (LIBMTP_Check_Capability(mtp, LIBMTP_DEVICECAP_EditObjects)) caps |= PB_CAP_EDIT_OBJECTS;
    // Renaming sets the ObjectFileName property. -1 means libmtp could not
    // tell; let the operation itself report failure in that case.
    int file_rename = LIBMTP_Is_Property_Supported(mtp, LIBMTP_PROPERTY_ObjectFileName, LIBMTP_FILETYPE_UNKNOWN);
    int folder_rename = LIBMTP_Is_Property_Supported(mtp, LIBMTP_PROPERTY_ObjectFileName, LIBMTP_FILETYPE_FOLDER);
    if (file_rename != 0 || folder_rename != 0) caps |= PB_CAP_RENAME;
    LIBMTP_Clear_Errorstack(mtp);
    return caps;
}

// MARK: - Object metadata and editing

static pb_status pb_require_device(pb_device *device, pb_error *error) {
    pb_clear_error(error);
    if (device == NULL || device->mtp == NULL) {
        pb_set_error(error, PB_STATUS_NO_DEVICE, 0, "Session is closed");
        return PB_STATUS_NO_DEVICE;
    }
    LIBMTP_Clear_Errorstack(device->mtp);
    return PB_STATUS_OK;
}

/// Converts a libmtp failure into `error`, falling back to `fallback`.
static pb_status pb_fail(pb_device *device, pb_error *error, pb_status fallback, const char *context) {
    if (pb_take_errorstack(device->mtp, error, context)) {
        return error ? error->status : fallback;
    }
    pb_set_error(error, fallback, 0, "%s failed", context);
    return fallback;
}

pb_status pb_count_children(pb_device *device, uint32_t storage_id, uint32_t parent_id,
                            uint32_t *out_count, pb_error *error) {
    pb_status status = pb_require_device(device, error);
    if (status != PB_STATUS_OK) return status;
    if (out_count == NULL) {
        pb_set_error(error, PB_STATUS_INVALID_ARGUMENT, 0, "Invalid arguments");
        return PB_STATUS_INVALID_ARGUMENT;
    }
    *out_count = 0;
    uint32_t *handles = NULL;
    int count = LIBMTP_Get_Children(device->mtp, storage_id, parent_id, &handles);
    free(handles);
    if (count < 0) {
        return pb_fail(device, error, PB_STATUS_GENERAL, "LIBMTP_Get_Children");
    }
    *out_count = (uint32_t)count;
    return PB_STATUS_OK;
}

pb_status pb_get_object(pb_device *device, uint32_t object_id, pb_object *out_object, pb_error *error) {
    pb_status status = pb_require_device(device, error);
    if (status != PB_STATUS_OK) return status;
    if (out_object == NULL) {
        pb_set_error(error, PB_STATUS_INVALID_ARGUMENT, 0, "Invalid arguments");
        return PB_STATUS_INVALID_ARGUMENT;
    }
    memset(out_object, 0, sizeof(*out_object));
    LIBMTP_file_t *file = LIBMTP_Get_Filemetadata(device->mtp, object_id);
    if (file == NULL) {
        return pb_fail(device, error, PB_STATUS_NOT_FOUND, "LIBMTP_Get_Filemetadata");
    }
    out_object->object_id = file->item_id;
    out_object->parent_id = file->parent_id;
    out_object->storage_id = file->storage_id;
    out_object->size = file->filesize;
    out_object->modified = (int64_t)file->modificationdate;
    out_object->is_folder = file->filetype == LIBMTP_FILETYPE_FOLDER;
    out_object->filetype = (int32_t)file->filetype;
    out_object->name = pb_strdup_or_null(file->filename);
    LIBMTP_destroy_file_t(file);
    return PB_STATUS_OK;
}

void pb_free_object_fields(pb_object *object) {
    if (object == NULL) return;
    free(object->name);
    object->name = NULL;
}

pb_status pb_create_folder(pb_device *device, const char *name, uint32_t storage_id, uint32_t parent_id,
                           uint32_t *out_object_id, pb_error *error) {
    pb_status status = pb_require_device(device, error);
    if (status != PB_STATUS_OK) return status;
    if (name == NULL || out_object_id == NULL) {
        pb_set_error(error, PB_STATUS_INVALID_ARGUMENT, 0, "Invalid arguments");
        return PB_STATUS_INVALID_ARGUMENT;
    }
    // libmtp takes a mutable name (it may sanitise it in place).
    char *copy = strdup(name);
    if (copy == NULL) {
        pb_set_error(error, PB_STATUS_MEMORY, 0, "Out of memory");
        return PB_STATUS_MEMORY;
    }
    // SendObjectInfo names the storage root 0xFFFFFFFF (PTP); Android's MTP
    // server rejects 0 there with "Invalid Object Handle" (seen on SM-S937N).
    uint32_t new_id = LIBMTP_Create_Folder(device->mtp, copy, parent_id, storage_id);
    free(copy);
    if (new_id == 0) {
        return pb_fail(device, error, PB_STATUS_GENERAL, "LIBMTP_Create_Folder");
    }
    *out_object_id = new_id;
    return PB_STATUS_OK;
}

pb_status pb_rename(pb_device *device, uint32_t object_id, const char *new_name, pb_error *error) {
    pb_status status = pb_require_device(device, error);
    if (status != PB_STATUS_OK) return status;
    if (new_name == NULL) {
        pb_set_error(error, PB_STATUS_INVALID_ARGUMENT, 0, "Invalid arguments");
        return PB_STATUS_INVALID_ARGUMENT;
    }
    LIBMTP_file_t *file = LIBMTP_Get_Filemetadata(device->mtp, object_id);
    if (file == NULL) {
        return pb_fail(device, error, PB_STATUS_NOT_FOUND, "LIBMTP_Get_Filemetadata");
    }
    int rc = LIBMTP_Set_File_Name(device->mtp, file, new_name);
    LIBMTP_destroy_file_t(file);
    if (rc != 0) {
        return pb_fail(device, error, PB_STATUS_GENERAL, "LIBMTP_Set_File_Name");
    }
    return PB_STATUS_OK;
}

pb_status pb_delete(pb_device *device, uint32_t object_id, pb_error *error) {
    pb_status status = pb_require_device(device, error);
    if (status != PB_STATUS_OK) return status;
    if (LIBMTP_Delete_Object(device->mtp, object_id) != 0) {
        return pb_fail(device, error, PB_STATUS_GENERAL, "LIBMTP_Delete_Object");
    }
    return PB_STATUS_OK;
}

pb_status pb_move(pb_device *device, uint32_t object_id, uint32_t storage_id, uint32_t parent_id, pb_error *error) {
    pb_status status = pb_require_device(device, error);
    if (status != PB_STATUS_OK) return status;
    uint32_t parent = parent_id == PB_ROOT_PARENT_ID ? 0 : parent_id;
    if (LIBMTP_Move_Object(device->mtp, object_id, storage_id, parent) != 0) {
        return pb_fail(device, error, PB_STATUS_GENERAL, "LIBMTP_Move_Object");
    }
    return PB_STATUS_OK;
}

pb_status pb_copy(pb_device *device, uint32_t object_id, uint32_t storage_id, uint32_t parent_id, pb_error *error) {
    pb_status status = pb_require_device(device, error);
    if (status != PB_STATUS_OK) return status;
    uint32_t parent = parent_id == PB_ROOT_PARENT_ID ? 0 : parent_id;
    if (LIBMTP_Copy_Object(device->mtp, object_id, storage_id, parent) != 0) {
        return pb_fail(device, error, PB_STATUS_GENERAL, "LIBMTP_Copy_Object");
    }
    return PB_STATUS_OK;
}

// MARK: - Transfers

typedef struct {
    pb_progress_fn fn;
    void *context;
} pb_progress_trampoline_t;

static int pb_progress_trampoline(uint64_t const sent, uint64_t const total, void const *const data) {
    const pb_progress_trampoline_t *trampoline = data;
    if (trampoline == NULL || trampoline->fn == NULL) {
        return 0;
    }
    return trampoline->fn(sent, total, trampoline->context);
}

pb_status pb_download_to_fd(pb_device *device, uint32_t object_id, int fd,
                            pb_progress_fn progress, void *context, pb_error *error) {
    pb_status status = pb_require_device(device, error);
    if (status != PB_STATUS_OK) return status;
    pb_progress_trampoline_t trampoline = { progress, context };
    if (LIBMTP_Get_File_To_File_Descriptor(device->mtp, object_id, fd, pb_progress_trampoline, &trampoline) != 0) {
        return pb_fail(device, error, PB_STATUS_GENERAL, "LIBMTP_Get_File_To_File_Descriptor");
    }
    return PB_STATUS_OK;
}

pb_status pb_upload_from_fd(pb_device *device, int fd, const char *name, uint64_t size, int64_t modified,
                            uint32_t storage_id, uint32_t parent_id,
                            pb_progress_fn progress, void *context,
                            uint32_t *out_object_id, pb_error *error) {
    pb_status status = pb_require_device(device, error);
    if (status != PB_STATUS_OK) return status;
    if (name == NULL || out_object_id == NULL) {
        pb_set_error(error, PB_STATUS_INVALID_ARGUMENT, 0, "Invalid arguments");
        return PB_STATUS_INVALID_ARGUMENT;
    }
    LIBMTP_file_t *file = LIBMTP_new_file_t();
    if (file == NULL) {
        pb_set_error(error, PB_STATUS_MEMORY, 0, "Out of memory");
        return PB_STATUS_MEMORY;
    }
    file->filename = strdup(name);
    if (file->filename == NULL) {
        LIBMTP_destroy_file_t(file);
        pb_set_error(error, PB_STATUS_MEMORY, 0, "Out of memory");
        return PB_STATUS_MEMORY;
    }
    file->filesize = size;
    file->filetype = LIBMTP_FILETYPE_UNKNOWN;
    // Root as 0xFFFFFFFF, as for folders (SendObjectInfo).
    file->parent_id = parent_id;
    file->storage_id = storage_id;
    file->modificationdate = (time_t)modified;

    pb_progress_trampoline_t trampoline = { progress, context };
    int rc = LIBMTP_Send_File_From_File_Descriptor(device->mtp, fd, file, pb_progress_trampoline, &trampoline);
    uint32_t new_id = file->item_id;
    LIBMTP_destroy_file_t(file);
    if (rc != 0) {
        return pb_fail(device, error, PB_STATUS_GENERAL, "LIBMTP_Send_File_From_File_Descriptor");
    }
    *out_object_id = new_id;
    return PB_STATUS_OK;
}

pb_status pb_read_partial(pb_device *device, uint32_t object_id, uint64_t offset, uint32_t length,
                          unsigned char **out_data, size_t *out_size, pb_error *error) {
    pb_status status = pb_require_device(device, error);
    if (status != PB_STATUS_OK) return status;
    if (out_data == NULL || out_size == NULL) {
        pb_set_error(error, PB_STATUS_INVALID_ARGUMENT, 0, "Invalid arguments");
        return PB_STATUS_INVALID_ARGUMENT;
    }
    *out_data = NULL;
    *out_size = 0;
    unsigned int size = 0;
    if (LIBMTP_GetPartialObject(device->mtp, object_id, offset, length, out_data, &size) != 0) {
        free(*out_data);
        *out_data = NULL;
        return pb_fail(device, error, PB_STATUS_GENERAL, "LIBMTP_GetPartialObject");
    }
    *out_size = size;
    return PB_STATUS_OK;
}

pb_status pb_begin_edit(pb_device *device, uint32_t object_id, pb_error *error) {
    pb_status status = pb_require_device(device, error);
    if (status != PB_STATUS_OK) return status;
    if (LIBMTP_BeginEditObject(device->mtp, object_id) != 0) {
        return pb_fail(device, error, PB_STATUS_GENERAL, "LIBMTP_BeginEditObject");
    }
    return PB_STATUS_OK;
}

pb_status pb_send_partial(pb_device *device, uint32_t object_id, uint64_t offset, const unsigned char *data,
                          uint32_t size, pb_error *error) {
    pb_status status = pb_require_device(device, error);
    if (status != PB_STATUS_OK) return status;
    if (data == NULL && size > 0) {
        pb_set_error(error, PB_STATUS_INVALID_ARGUMENT, 0, "Invalid arguments");
        return PB_STATUS_INVALID_ARGUMENT;
    }
    // libmtp takes a mutable pointer but only reads from it.
    if (LIBMTP_SendPartialObject(device->mtp, object_id, offset, (unsigned char *)data, size) != 0) {
        return pb_fail(device, error, PB_STATUS_GENERAL, "LIBMTP_SendPartialObject");
    }
    return PB_STATUS_OK;
}

pb_status pb_end_edit(pb_device *device, uint32_t object_id, pb_error *error) {
    pb_status status = pb_require_device(device, error);
    if (status != PB_STATUS_OK) return status;
    if (LIBMTP_EndEditObject(device->mtp, object_id) != 0) {
        return pb_fail(device, error, PB_STATUS_GENERAL, "LIBMTP_EndEditObject");
    }
    return PB_STATUS_OK;
}

pb_status pb_get_thumbnail(pb_device *device, uint32_t object_id, unsigned char **out_data, size_t *out_size,
                           pb_error *error) {
    pb_status status = pb_require_device(device, error);
    if (status != PB_STATUS_OK) return status;
    if (out_data == NULL || out_size == NULL) {
        pb_set_error(error, PB_STATUS_INVALID_ARGUMENT, 0, "Invalid arguments");
        return PB_STATUS_INVALID_ARGUMENT;
    }
    *out_data = NULL;
    *out_size = 0;
    unsigned int size = 0;
    if (LIBMTP_Get_Thumbnail(device->mtp, object_id, out_data, &size) != 0 || *out_data == NULL) {
        // libmtp may have allocated the buffer before failing.
        free(*out_data);
        *out_data = NULL;
        return pb_fail(device, error, PB_STATUS_NOT_FOUND, "LIBMTP_Get_Thumbnail");
    }
    *out_size = size;
    return PB_STATUS_OK;
}

void pb_free_buffer(void *buffer) {
    free(buffer);
}
