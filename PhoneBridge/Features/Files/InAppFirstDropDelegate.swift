import AppKit
import SwiftUI

/// Drop target of the Android and Mac panes and of folders in the Android pane.
///
/// A drag from PhoneBridge's own device list also carries a file promise for
/// Finder. SwiftUI's provider-based drops (`onDrop(of:perform:)`,
/// `dropDestination(for:)`) read every drag item on the main thread, which
/// resolves that promise synchronously, and the promise can only be filled by
/// downloading on the main actor: the app hung for good (2026-10-28, D77).
/// In-app drags are recognised by their text payload, read straight from the
/// drag pasteboard; item providers are requested only for file URLs from other
/// apps (Finder), whose promises are not ours.
struct InAppFirstDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    var isEnabled: () -> Bool = { true }
    let perform: (DropLoader.Contents) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        isEnabled() && info.hasItemsConforming(to: DropLoader.acceptedTypes)
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard isEnabled() else { return false }
        let payloads = DropLoader.inAppPayloads(NSPasteboard(name: .drag))
        if !payloads.isEmpty {
            perform(DropLoader.Contents(payloads: payloads))
            return true
        }
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        Task { perform(await DropLoader.load(providers)) }
        return true
    }
}

extension View {
    /// A folder in the Android pane accepts PhoneBridge items (moved into it)
    /// and Finder files (uploaded into it). Other items are no drop target.
    func deviceFolderDrop(_ item: FileItem, model: AppModel) -> some View {
        onDrop(of: DropLoader.acceptedTypes,
               delegate: InAppFirstDropDelegate(isTargeted: .constant(false),
                                                isEnabled: { item.isFolder && model.canWriteHere }) {
                   model.dropOnDevice($0, onto: item)
               })
    }
}
