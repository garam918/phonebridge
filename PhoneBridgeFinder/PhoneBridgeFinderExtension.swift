import ExtensionFoundation
import Foundation
import FSKit

/// FSKit module that shows PhoneBridge volumes in Finder. It contains no MTP
/// code: every request goes to the PhoneBridge app's DeviceBroker over IPC.
@main
struct PhoneBridgeFinderExtension: UnaryFileSystemExtension {
    var fileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations {
        PhoneBridgeFileSystem.shared
    }
}
