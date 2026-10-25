import Foundation

enum USBEvent: Sendable, Equatable {
    /// A device appeared, or an existing device's snapshot changed (interfaces
    /// arrived). Consumers must treat this as an upsert keyed by registryID.
    case attached(USBDeviceSnapshot)
    case detached(registryID: UInt64)
}

/// Source of USB hot-plug events. The production implementation is
/// `IOKitUSBMonitor`; tests drive a mock.
protocol USBDeviceMonitoring: AnyObject, Sendable {
    /// Single-consumer stream of events. Existing devices are reported as
    /// `.attached` right after `start()`.
    var events: AsyncStream<USBEvent> { get }
    func start()
    func stop()
    /// Name of the process that holds the device's interfaces exclusively, if
    /// IOKit exposes it (e.g. "ptpcamerad (pid 512)").
    func exclusiveOwner(registryID: UInt64) async -> String?
}
