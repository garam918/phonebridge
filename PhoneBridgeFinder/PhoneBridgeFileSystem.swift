import Foundation
import FSKit
import os

let finderLog = Logger(subsystem: FinderIPC.extensionBundleIdentifier, category: "fskit")

func posixError(_ code: Int32) -> NSError {
    fs_errorForPOSIXError(code) as NSError
}

extension FinderIPCError {
    var fsError: NSError { posixError(code) }
}

/// Loads `phonebridge://volume?...` generic URL resources.
final class PhoneBridgeFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations, @unchecked Sendable {
    static let shared = PhoneBridgeFileSystem()

    private let lock = NSLock()
    private var clients: [VolumeAddress: [FinderBrokerClient]] = [:]

    func probeResource(resource: FSResource, replyHandler reply: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        guard let address = Self.address(of: resource) else {
            reply(.notRecognized, nil)
            return
        }
        reply(.usable(name: "PhoneBridge", containerID: FSContainerIdentifier(uuid: address.uuid)), nil)
    }

    func loadResource(resource: FSResource, options: FSTaskOptions,
                      replyHandler reply: @escaping (FSVolume?, (any Error)?) -> Void) {
        guard let address = Self.address(of: resource) else {
            reply(nil, posixError(EINVAL))
            return
        }
        guard let socketURL = FinderIPC.defaultSocketURL() else {
            finderLog.error("no App Group container; cannot reach PhoneBridge")
            ExtensionStatusRecorder.shared.record("load-failed", "no App Group container")
            reply(nil, posixError(ENOTCONN))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let client = FinderBrokerClient(socketPath: socketURL.path)
            let writeClient = FinderBrokerClient(socketPath: socketURL.path)
            do throws(FinderIPCError) {
                try client.connect()
                let description = try client.describe(address)
                // Read-only unless the app allows writes for this volume now.
                let writable = (try? client.writeCapabilities(address))?.allowsWrites ?? false
                lock.withLock { clients[address] = [client, writeClient] }
                containerStatus = .ready
                finderLog.info("loaded \(description.name, privacy: .private)\(writable ? " (writable)" : "", privacy: .public)")
                ExtensionStatusRecorder.shared.record("loaded", writable ? "writable" : "read-only")
                let showsStaging = (resource as? FSGenericURLResource).map { VolumeAddress.showsStagingObjects($0.url) } ?? false
                reply(PhoneBridgeVolume(address: address, description: description, client: client, writeClient: writeClient,
                                        writable: writable, bufferDirectory: FinderIPC.defaultWriteBufferDirectory(),
                                        showsStagingObjects: showsStaging), nil)
            } catch {
                finderLog.error("load failed: \(error.message, privacy: .public)")
                ExtensionStatusRecorder.shared.record("load-failed", "\(error.code) \(error.message)")
                reply(nil, error.fsError)
            }
        }
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions,
                        replyHandler reply: @escaping ((any Error)?) -> Void) {
        if let address = Self.address(of: resource) {
            lock.withLock { clients.removeValue(forKey: address) }?.forEach { $0.close() }
        }
        reply(nil)
    }

    static func address(of resource: FSResource) -> VolumeAddress? {
        guard let resource = resource as? FSGenericURLResource else { return nil }
        return VolumeAddress(url: resource.url)
    }
}
