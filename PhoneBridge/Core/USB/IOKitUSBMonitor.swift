import Foundation
import IOKit
import IOKit.usb

/// Watches IOUSBHostDevice / IOUSBHostInterface publication and termination.
///
/// Every IOKit call and all mutable state are confined to `queue`; the
/// notification port delivers its callbacks on that same queue. Nothing here
/// talks to the device itself: reading IORegistry properties is not USB I/O.
final class IOKitUSBMonitor: USBDeviceMonitoring, @unchecked Sendable {
    let events: AsyncStream<USBEvent>

    private let continuation: AsyncStream<USBEvent>.Continuation
    private let queue = DispatchQueue(label: "com.phonebridge.usb-monitor", qos: .utility)
    private let settleDelay: TimeInterval
    private let interfaceCoalesceDelay: TimeInterval = 0.3

    // queue-confined state
    private var notificationPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var retainedSelf: Unmanaged<IOKitUSBMonitor>?
    private var pendingInterfaceRefresh: Set<UInt64> = []

    init(settleDelay: TimeInterval = 1.5) {
        (events, continuation) = AsyncStream.makeStream(of: USBEvent.self, bufferingPolicy: .unbounded)
        self.settleDelay = settleDelay
    }

    func start() {
        queue.async { self.startOnQueue() }
    }

    func stop() {
        queue.async { self.stopOnQueue() }
    }

    func exclusiveOwner(registryID: UInt64) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.readExclusiveOwner(registryID: registryID))
            }
        }
    }

    // MARK: - Notification setup

    private func startOnQueue() {
        guard notificationPort == nil else { return }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            Log.usb.error("IONotificationPortCreate failed; USB hot-plug detection is unavailable")
            return
        }
        notificationPort = port
        IONotificationPortSetDispatchQueue(port, queue)

        let retained = Unmanaged.passRetained(self)
        retainedSelf = retained
        let context = retained.toOpaque()

        // Order matters: devices first so the initial drain reports every
        // device once; the interface iterator is armed silently afterwards.
        if let iterator = addNotification(port, kIOFirstMatchNotification, "IOUSBHostDevice", context, { context, iterator in
            IOKitUSBMonitor.from(context)?.devicesMatched(iterator)
        }) {
            devicesMatched(iterator)
        }
        if let iterator = addNotification(port, kIOTerminatedNotification, "IOUSBHostDevice", context, { context, iterator in
            IOKitUSBMonitor.from(context)?.devicesTerminated(iterator)
        }) {
            drain(iterator)
        }
        if let iterator = addNotification(port, kIOFirstMatchNotification, "IOUSBHostInterface", context, { context, iterator in
            IOKitUSBMonitor.from(context)?.interfacesMatched(iterator)
        }) {
            drain(iterator)
        }
        Log.usb.info("USB monitor started")
    }

    private func stopOnQueue() {
        for iterator in iterators {
            IOObjectRelease(iterator)
        }
        iterators.removeAll()
        if let port = notificationPort {
            IONotificationPortDestroy(port)
            notificationPort = nil
        }
        retainedSelf?.release()
        retainedSelf = nil
        Log.usb.info("USB monitor stopped")
    }

    private func addNotification(_ port: IONotificationPortRef, _ type: String, _ className: String,
                                 _ context: UnsafeMutableRawPointer,
                                 _ callback: IOServiceMatchingCallback) -> io_iterator_t? {
        var iterator: io_iterator_t = 0
        let result = IOServiceAddMatchingNotification(port, type, IOServiceMatching(className), callback, context, &iterator)
        guard result == KERN_SUCCESS else {
            Log.usb.error("IOServiceAddMatchingNotification(\(type, privacy: .public), \(className, privacy: .public)) failed: \(result)")
            return nil
        }
        iterators.append(iterator)
        return iterator
    }

    private static func from(_ context: UnsafeMutableRawPointer?) -> IOKitUSBMonitor? {
        guard let context else { return nil }
        return Unmanaged<IOKitUSBMonitor>.fromOpaque(context).takeUnretainedValue()
    }

    private func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }

    // MARK: - Callbacks (on queue)

    private func devicesMatched(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let snapshot = Self.makeSnapshot(service, forceSettled: false) else { continue }
            emit(.attached(snapshot))
            if !snapshot.interfacesSettled {
                let registryID = snapshot.registryID
                queue.asyncAfter(deadline: .now() + settleDelay) { [weak self] in
                    self?.refresh(registryID: registryID, forceSettled: true)
                }
            }
        }
    }

    private func devicesTerminated(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var registryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &registryID)
            emit(.detached(registryID: registryID))
        }
    }

    /// Interfaces appear after the device and again after a configuration
    /// change. Re-snapshot the parent device, coalescing bursts.
    private func interfacesMatched(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(parent) }
            guard IOObjectConformsTo(parent, "IOUSBHostDevice") != 0 else { continue }
            var registryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(parent, &registryID)
            let parentID = registryID
            guard pendingInterfaceRefresh.insert(parentID).inserted else { continue }
            queue.asyncAfter(deadline: .now() + interfaceCoalesceDelay) { [weak self] in
                guard let self else { return }
                self.pendingInterfaceRefresh.remove(parentID)
                self.refresh(registryID: parentID, forceSettled: false)
            }
        }
    }

    private func refresh(registryID: UInt64, forceSettled: Bool) {
        guard notificationPort != nil else { return }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryID))
        guard service != 0 else { return } // already gone; termination is reported separately
        defer { IOObjectRelease(service) }
        guard let snapshot = Self.makeSnapshot(service, forceSettled: forceSettled) else { return }
        emit(.attached(snapshot))
    }

    private func emit(_ event: USBEvent) {
        switch event {
        case .attached(let snapshot):
            Log.usb.debug("""
                attached \(snapshot.idPairDescription, privacy: .public) \(snapshot.displayName, privacy: .public) \
                registry=\(snapshot.registryID) bus=\(snapshot.busNumber) addr=\(snapshot.address) \
                interfaces=\(snapshot.interfaces.count) settled=\(snapshot.interfacesSettled)
                """)
        case .detached(let registryID):
            Log.usb.debug("detached registry=\(registryID)")
        }
        continuation.yield(event)
    }

    // MARK: - IORegistry reading

    static func makeSnapshot(_ device: io_service_t, forceSettled: Bool) -> USBDeviceSnapshot? {
        guard let vendorID = intProperty(device, "idVendor"),
              let productID = intProperty(device, "idProduct") else { return nil }
        var registryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(device, &registryID)
        let interfaces = readInterfaces(of: device)
        return USBDeviceSnapshot(
            registryID: registryID,
            vendorID: UInt16(truncatingIfNeeded: vendorID),
            productID: UInt16(truncatingIfNeeded: productID),
            vendorName: stringProperty(device, "USB Vendor Name", "kUSBVendorString"),
            productName: stringProperty(device, "USB Product Name", "kUSBProductString"),
            serialNumber: stringProperty(device, "USB Serial Number", "kUSBSerialNumberString"),
            locationID: UInt32(truncatingIfNeeded: intProperty(device, "locationID") ?? 0),
            address: UInt8(truncatingIfNeeded: intProperty(device, "USB Address", "kUSBAddress") ?? 0),
            interfaces: interfaces,
            interfacesSettled: forceSettled || !interfaces.isEmpty
        )
    }

    private static func readInterfaces(of device: io_service_t) -> [USBInterfaceInfo] {
        var result: [USBInterfaceInfo] = []
        forEachChild(of: device) { child in
            guard IOObjectConformsTo(child, "IOUSBHostInterface") != 0,
                  let interfaceClass = intProperty(child, "bInterfaceClass") else { return }
            var name = stringProperty(child, "kUSBString", "USB Interface Name")
            if name == nil {
                let registryName = registryEntryName(child)
                if registryName != "IOUSBHostInterface" { name = registryName }
            }
            result.append(USBInterfaceInfo(
                number: UInt8(truncatingIfNeeded: intProperty(child, "bInterfaceNumber") ?? 0),
                interfaceClass: UInt8(truncatingIfNeeded: interfaceClass),
                interfaceSubClass: UInt8(truncatingIfNeeded: intProperty(child, "bInterfaceSubClass") ?? 0),
                interfaceProtocol: UInt8(truncatingIfNeeded: intProperty(child, "bInterfaceProtocol") ?? 0),
                name: name
            ))
        }
        return result.sorted { $0.number < $1.number }
    }

    private func readExclusiveOwner(registryID: UInt64) -> String? {
        let device = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryID))
        guard device != 0 else { return nil }
        defer { IOObjectRelease(device) }

        var candidates: [String] = []
        if let owner = Self.stringProperty(device, "UsbExclusiveOwner") { candidates.append(owner) }
        Self.forEachChild(of: device) { interface in
            if let owner = Self.stringProperty(interface, "UsbExclusiveOwner") { candidates.append(owner) }
            Self.forEachChild(of: interface) { client in
                if let creator = Self.stringProperty(client, "IOUserClientCreator") { candidates.append(creator) }
            }
        }
        return candidates.lazy.compactMap { Self.describeOwner($0) }.first
    }

    /// Turns IOKit's "pid 512, ptpcamerad" into "ptpcamerad (pid 512)".
    /// Returns nil for our own process.
    static func describeOwner(_ raw: String, ownPID: Int32 = getpid()) -> String? {
        let parts = raw.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, parts[0].hasPrefix("pid "), let pid = Int32(parts[0].dropFirst(4)) else {
            return raw.isEmpty ? nil : raw
        }
        guard pid != ownPID else { return nil }
        return "\(parts[1]) (pid \(pid))"
    }

    private static func forEachChild(of entry: io_registry_entry_t, _ body: (io_registry_entry_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let child = IOIteratorNext(iterator), child != 0 {
            body(child)
            IOObjectRelease(child)
        }
    }

    private static func registryProperty(_ entry: io_registry_entry_t, _ key: String) -> AnyObject? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func intProperty(_ entry: io_registry_entry_t, _ keys: String...) -> Int? {
        for key in keys {
            if let number = registryProperty(entry, key) as? NSNumber { return number.intValue }
        }
        return nil
    }

    private static func stringProperty(_ entry: io_registry_entry_t, _ keys: String...) -> String? {
        for key in keys {
            if let value = registryProperty(entry, key) as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func registryEntryName(_ entry: io_registry_entry_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(entry, &buffer) == KERN_SUCCESS else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }
}
