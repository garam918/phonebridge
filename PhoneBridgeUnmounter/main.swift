import Foundation
import os

/// Unmounts PhoneBridge volumes for the sandboxed app. Runs outside the
/// sandbox, accepts only its own app and only `phonebridge` mounts.
final class Unmounter: NSObject, VolumeUnmounting {
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PhoneBridgeUnmounter", category: "unmounter")

    func unmountVolume(atPath path: String, reply: @escaping @Sendable (Int32, String?) -> Void) {
        let verdict = VolumeUnmountPolicy.check(path: path)
        guard verdict == 0 else {
            // log-privacy: public-ok — mount point under /Volumes (the only paths the app sends)
            log.error("refused \(path, privacy: .public): errno \(verdict)")
            reply(verdict, "refused")
            return
        }
        FileManager.default.unmountVolume(at: URL(fileURLWithPath: path), options: [.withoutUI]) { [log] error in
            if let error {
                // log-privacy: public-ok — mount point under /Volumes (the only paths the app sends)
                log.error("unmount \(path, privacy: .public) failed: \(error.publicSummary, privacy: .public) \(error.localizedDescription, privacy: .private)")
                reply(EBUSY, error.localizedDescription)
            } else {
                // log-privacy: public-ok — mount point under /Volumes (the only paths the app sends)
                log.info("unmounted \(path, privacy: .public)")
                reply(0, nil)
            }
        }
    }
}

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(Self.hostRequirement)
        connection.exportedInterface = NSXPCInterface(with: VolumeUnmounting.self)
        connection.exportedObject = Unmounter()
        connection.resume()
        return true
    }

    /// Only the host app, signed by the same team as this helper. Ad-hoc
    /// builds fall back to the identifier: this XPC service is private to the
    /// app bundle, and the app's cdhash differs from the helper's.
    static var hostRequirement: String {
        PeerRequirement.text(identifiers: [FinderIPC.appBundleIdentifier], team: PeerRequirement.ownSignature()?.team, ownCDHash: nil)
            ?? "identifier \"\(FinderIPC.appBundleIdentifier)\""
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
