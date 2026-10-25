import AppKit
import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let item = model.browser.selectedItem {
                    FileInfoSection(item: item)
                } else if model.browser.selection.count > 1 {
                    Text(loc.t("inspector.multipleSelection", model.browser.selection.count))
                        .foregroundStyle(.secondary)
                } else if let storage = model.browser.storage {
                    StorageInfoSection(storage: storage)
                }
                DeviceInfoSection()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct FileInfoSection: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationManager.self) private var loc
    let item: FileItem
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer()
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 200, maxHeight: 160)
                        .clipShape(.rect(cornerRadius: 6))
                } else {
                    FileIcon(item: item, size: 56)
                }
                Spacer()
            }
            .task(id: item.id) {
                thumbnail = nil
                guard let fileSystem = model.browser.fileSystem else { return }
                thumbnail = await model.previews.thumbnail(for: item, in: fileSystem)
            }
            Text(item.name)
                .font(.headline)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .textSelection(.enabled)
            HStack {
                if model.canPreview(item) {
                    Button(loc.t("action.preview")) { Task { await model.previewSelection() } }
                }
                Button(loc.t("action.download")) {
                    FileActions.download([item], model: model, loc: loc, choosingDestination: false)
                }
            }
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            InfoGrid(rows: [
                (loc.t("column.kind"), loc.t(item.category.localizationKey)),
                (loc.t("column.size"), sizeText),
                (loc.t("column.modified"), item.modified.map(loc.formatDate) ?? "—"),
                (loc.t("inspector.location"), model.browser.locationDescription(of: item)),
                (loc.t("inspector.objectID"), String(format: "0x%08X", item.id.objectID)),
                (loc.t("inspector.storageID"), String(format: "0x%08X", item.id.storageID)),
            ])
            if model.browser.isShowingMock {
                Label(loc.t("demo.inspectorNote"), systemImage: "testtube.2")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var sizeText: String {
        guard !item.isFolder, let size = item.size else { return "—" }
        return loc.t("inspector.sizeWithBytes", loc.formatBytes(size), loc.formatCount(Int(clamping: size)))
    }
}

private struct StorageInfoSection: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationManager.self) private var loc
    let storage: StorageInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(storage.name, systemImage: storage.kind == .removable ? "sdcard" : "internaldrive")
                .font(.headline)
            if let capacity = storage.capacity, let used = storage.usedSpace, capacity > 0 {
                Gauge(value: Double(used), in: 0...Double(capacity)) {
                    EmptyView()
                }
                .gaugeStyle(.linearCapacity)
                Text(loc.t("storage.usage", loc.formatBytes(used), loc.formatBytes(capacity)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            InfoGrid(rows: [
                (loc.t("storage.free"), storage.freeSpace.map(loc.formatBytes) ?? "—"),
                (loc.t("storage.type"), loc.t("storage.kind.\(storage.kind.rawValue)")),
                (loc.t("storage.access"), storage.isReadOnly ? loc.t("storage.readOnly") : loc.t("storage.readWrite")),
                (loc.t("inspector.storageID"), String(format: "0x%08X", storage.id)),
            ])
            if let capabilities = model.browser.fileSystem?.capabilities {
                InfoGrid(rows: [
                    (loc.t("capability.rename"), capabilities.canRename ? loc.t("capability.supported") : loc.t("capability.unsupported")),
                    (loc.t("capability.move"), capabilities.canMoveNatively ? loc.t("capability.native") : loc.t("capability.fallback")),
                    (loc.t("capability.copy"), capabilities.canCopyNatively ? loc.t("capability.native") : loc.t("capability.fallback")),
                ])
            }
        }
    }
}

private struct DeviceInfoSection: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        if let info = deviceInfo {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                Text(loc.t("inspector.device")).font(.headline)
                InfoGrid(rows: [
                    (loc.t("device.manufacturer"), info.manufacturer ?? "—"),
                    (loc.t("device.model"), info.model ?? "—"),
                    (loc.t("device.serial"), info.serialNumber ?? "—"),
                    (loc.t("device.version"), info.deviceVersion ?? "—"),
                    (loc.t("device.battery"), info.batteryLevel.map { "\($0)%" } ?? "—"),
                ])
            }
        }
    }

    private var deviceInfo: MTPDeviceInfo? {
        if model.isDemoSelected { return model.demoDevice.deviceInfo }
        return model.selectedRecord?.info
    }
}

private struct InfoGrid: View {
    let rows: [(String, String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.0)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(row.1)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.callout)
    }
}
