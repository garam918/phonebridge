//
//  PBMTPBridge.h
//  PhoneBridge
//
//  Thin C facade over libmtp + libusb. Swift only ever sees the types in this
//  header; libmtp.h / libusb.h stay private to PBMTPBridge.c.
//
//  Threading: every function that takes a pb_device must be called from one
//  serial context per device (DeviceBroker's MTPDeviceSession guarantees this).
//  All calls may block on USB I/O and must never run on the main thread.
//

#ifndef PBMTPBridge_h
#define PBMTPBridge_h

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Parent id that addresses the root of a storage.
#define PB_ROOT_PARENT_ID 0xFFFFFFFFu

typedef enum {
    PB_STATUS_OK = 0,
    PB_STATUS_NO_DEVICE = 1,
    PB_STATUS_BUSY = 2,
    PB_STATUS_ACCESS_DENIED = 3,
    PB_STATUS_OPEN_FAILED = 4,
    PB_STATUS_PTP_LAYER = 5,
    PB_STATUS_USB_LAYER = 6,
    PB_STATUS_MEMORY = 7,
    PB_STATUS_STORAGE_FULL = 8,
    PB_STATUS_CANCELLED = 9,
    PB_STATUS_TIMEOUT = 10,
    PB_STATUS_INVALID_ARGUMENT = 11,
    PB_STATUS_NOT_FOUND = 12,
    PB_STATUS_NO_INTERFACE = 13,
    PB_STATUS_GENERAL = 14,
} pb_status;

typedef struct {
    pb_status status;
    /// libusb error (negative) or libmtp error number, 0 if not applicable.
    int32_t native_code;
    char message[256];
} pb_error;

typedef struct pb_device pb_device;

typedef struct {
    char *manufacturer;
    char *model;
    char *serial_number;
    char *device_version;
    char *friendly_name;
    /// 0...100, or -1 when the device does not report a battery level.
    int32_t battery_percent;
} pb_device_info;

typedef struct {
    uint32_t storage_id;
    uint16_t storage_type;
    uint16_t filesystem_type;
    uint16_t access_capability;
    uint64_t max_capacity;
    uint64_t free_space;
    char *description;
    char *volume_identifier;
} pb_storage;

typedef struct {
    uint32_t object_id;
    uint32_t parent_id;
    uint32_t storage_id;
    uint64_t size;
    /// Seconds since 1970, 0 when unknown.
    int64_t modified;
    bool is_folder;
    int32_t filetype;
    char *name;
} pb_object;

/// Initialises libmtp and the bridge's own libusb context. Safe to call repeatedly.
void pb_initialize(void);

const char *pb_libmtp_version(void);
const char *pb_error_message(const pb_error *error);

/// Number of USB devices libusb can enumerate (diagnostics), or a negative libusb error.
int32_t pb_usb_device_count(void);

/// Opens the device with libusb and tries to claim its MTP interface, then
/// releases everything again. Distinguishes "busy (claimed by another process)"
/// from "no MTP interface" before libmtp is involved.
pb_status pb_usb_preflight(uint32_t bus, uint8_t address, pb_error *error);

/// Opens an MTP session. Returns NULL and fills `error` on failure.
pb_device *pb_open(uint32_t bus, uint8_t address, uint16_t vendor_id, uint16_t product_id, pb_error *error);

/// Closes the MTP session and frees the device. Tolerates an unplugged device.
void pb_close(pb_device *device);

void pb_get_device_info(pb_device *device, pb_device_info *out_info);
void pb_free_device_info(pb_device_info *info);

pb_status pb_list_storages(pb_device *device, pb_storage **out_storages, size_t *out_count, pb_error *error);
void pb_free_storages(pb_storage *storages, size_t count);

pb_status pb_list_folder(pb_device *device, uint32_t storage_id, uint32_t parent_id,
                         pb_object **out_objects, size_t *out_count, pb_error *error);
void pb_free_objects(pb_object *objects, size_t count);

/// Number of object handles in a folder. pb_list_folder silently leaves out
/// objects whose metadata libmtp cannot read; this count does not.
pb_status pb_count_children(pb_device *device, uint32_t storage_id, uint32_t parent_id,
                            uint32_t *out_count, pb_error *error);

// MARK: - Capabilities

enum {
    PB_CAP_MOVE_OBJECT = 1u << 0,
    PB_CAP_COPY_OBJECT = 1u << 1,
    PB_CAP_RENAME = 1u << 2,
    PB_CAP_PARTIAL_GET = 1u << 3,
    PB_CAP_PARTIAL_SEND = 1u << 4,
    PB_CAP_EDIT_OBJECTS = 1u << 5,
};

/// Bitmask of optional MTP operations the device advertises.
uint32_t pb_capabilities(pb_device *device);

// MARK: - Object metadata and editing

/// Metadata of one object. Free `out_object->name` with pb_free_object_fields.
pb_status pb_get_object(pb_device *device, uint32_t object_id, pb_object *out_object, pb_error *error);
void pb_free_object_fields(pb_object *object);

/// Creates a folder and returns its object id.
pb_status pb_create_folder(pb_device *device, const char *name, uint32_t storage_id, uint32_t parent_id,
                           uint32_t *out_object_id, pb_error *error);
pb_status pb_rename(pb_device *device, uint32_t object_id, const char *new_name, pb_error *error);
/// Deletes one object. Callers delete folder contents first.
pb_status pb_delete(pb_device *device, uint32_t object_id, pb_error *error);
pb_status pb_move(pb_device *device, uint32_t object_id, uint32_t storage_id, uint32_t parent_id, pb_error *error);
/// Device-side copy. MTP does not return the new handle; callers look it up.
pb_status pb_copy(pb_device *device, uint32_t object_id, uint32_t storage_id, uint32_t parent_id, pb_error *error);

// MARK: - Transfers

/// Progress callback, invoked on the calling (session) thread during a
/// transfer. Return non-zero to cancel the transfer.
typedef int (*pb_progress_fn)(uint64_t sent, uint64_t total, void *context);

/// Streams an object into `fd` (64-bit sizes supported). The caller owns `fd`.
pb_status pb_download_to_fd(pb_device *device, uint32_t object_id, int fd,
                            pb_progress_fn progress, void *context, pb_error *error);

/// Streams `size` bytes from `fd` into a new object `name` under `parent_id`.
pb_status pb_upload_from_fd(pb_device *device, int fd, const char *name, uint64_t size, int64_t modified,
                            uint32_t storage_id, uint32_t parent_id,
                            pb_progress_fn progress, void *context,
                            uint32_t *out_object_id, pb_error *error);

/// Reads up to `length` bytes at `offset` (MTP GetPartialObject[64]). Only
/// valid when PB_CAP_PARTIAL_GET is set. Free `*out_data` with pb_free_buffer.
pb_status pb_read_partial(pb_device *device, uint32_t object_id, uint64_t offset, uint32_t length,
                          unsigned char **out_data, size_t *out_size, pb_error *error);

/// Android edit extension (PB_CAP_EDIT_OBJECTS): opens an object for
/// SendPartialObject / TruncateObject until pb_end_edit.
pb_status pb_begin_edit(pb_device *device, uint32_t object_id, pb_error *error);

/// Writes `size` bytes at `offset` of an object open for edit. Android only
/// accepts offsets up to the current size, so data is sent front to back.
pb_status pb_send_partial(pb_device *device, uint32_t object_id, uint64_t offset, const unsigned char *data,
                          uint32_t size, pb_error *error);

/// Commits the edits (the device updates its media database).
pb_status pb_end_edit(pb_device *device, uint32_t object_id, pb_error *error);

/// Embedded thumbnail (usually JPEG). Free `*out_data` with pb_free_buffer.
pb_status pb_get_thumbnail(pb_device *device, uint32_t object_id, unsigned char **out_data, size_t *out_size,
                           pb_error *error);
void pb_free_buffer(void *buffer);

#ifdef __cplusplus
}
#endif

#endif /* PBMTPBridge_h */
