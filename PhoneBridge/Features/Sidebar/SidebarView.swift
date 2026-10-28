import AppKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationManager.self) private var loc
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebarSelection) {
            Section(loc.t("sidebar.devices")) {
                if androidDevices.isEmpty {
                    Text(loc.t("sidebar.noDevices"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
                ForEach(androidDevices) { record in
                    DeviceRow(name: record.displayName,
                              status: loc.stateTitle(record.state),
                              state: record.state,
                              isDemo: false)
                        .tag(SidebarItem.device(record.id))
                        .contextMenu { DeviceMenu(record: record) }
                    if record.state.isMTPReady {
                        ForEach(record.storages) { storage in
                            StorageRow(storage: storage, finder: finderStatus(record.id, storage.id))
                                .tag(SidebarItem.storage(record.id, storage.id))
                                .contextMenu { FinderMountMenu(deviceID: record.id, storageID: storage.id) }
                        }
                    }
                }
            }

            if !model.appleDevices.records.isEmpty {
                Section(loc.t("sidebar.appleDevices")) {
                    ForEach(model.appleDevices.records) { record in
                        AppleDeviceRow(record: record)
                            .tag(SidebarItem.device(record.id))
                            .contextMenu {
                                if case .failed = record.state {
                                    Button(loc.t("action.retry")) { model.appleDevices.retry(record.id) }
                                }
                            }
                        if record.state == .ready, let storage = model.appleDevices.fileSystem(for: record.id)?.storage {
                            StorageRow(storage: storage, symbol: "photo.on.rectangle")
                                .tag(SidebarItem.storage(record.id, storage.id))
                        }
                    }
                }
            }

            if settings.showDemoDevice {
                Section(loc.t("sidebar.demoDevices")) {
                    DeviceRow(name: loc.t("demo.deviceName"),
                              status: loc.t("demo.status"),
                              state: .connected,
                              isDemo: true)
                        .tag(SidebarItem.device(.demo))
                    ForEach(model.demoStorages) { storage in
                        StorageRow(storage: storage, finder: finderStatus(.demo, storage.id))
                            .tag(SidebarItem.storage(.demo, storage.id))
                            .contextMenu { FinderMountMenu(deviceID: .demo, storageID: storage.id) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// The broker also sees an iPhone/iPad over USB (as unsupported); it is
    /// listed once, under iPhone·iPad, while Image Capture serves it.
    private var androidDevices: [DeviceRecord] {
        guard !model.appleDevices.records.isEmpty else { return model.broker.devices }
        return model.broker.devices.filter { $0.state != .unsupported(.appleDevice) }
    }

    private func finderStatus(_ deviceID: DeviceID, _ storageID: UInt32) -> StorageRow.FinderStatus {
        let finder = model.finder
        guard let volume = finder.volumes.first(where: { $0.address.deviceID == deviceID.rawValue && $0.address.storageID == storageID })
        else { return .none }
        if finder.problem(of: volume) != nil { return .problem }
        return finder.state(of: volume).mountURL != nil ? .mounted : .none
    }
}

/// Control-click menu of a device row.
private struct DeviceMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationManager.self) private var loc
    let record: DeviceRecord

    var body: some View {
        if record.state.isUSBPresent, record.state != .safelyDisconnected, !isUnsupported {
            Button(loc.t("action.safelyDisconnect")) { model.requestSafeDisconnect(record.id) }
        }
        if record.state.canRetry {
            Button(loc.t(record.state == .safelyDisconnected ? "action.reconnect" : "action.retry")) { model.broker.retry(record.id) }
        }
    }

    private var isUnsupported: Bool {
        if case .unsupported = record.state { return true }
        return false
    }
}

private struct DeviceRow: View {
    @Environment(LocalizationManager.self) private var loc
    let name: String
    let status: String
    let state: ConnectionState
    let isDemo: Bool

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(name).lineLimit(1)
                    if isDemo {
                        Text(loc.t("demo.badge"))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.18), in: .capsule)
                            .foregroundStyle(.orange)
                    }
                }
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: isDemo ? "testtube.2" : "smartphone")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            StatusIndicator(state: state)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AppleDeviceRow: View {
    @Environment(LocalizationManager.self) private var loc
    let record: AppleDeviceRecord

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(record.name).lineLimit(1)
                Text(loc.appleStateTitle(record.state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: record.isTablet ? "ipad" : "iphone")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            Group {
                switch record.state {
                case .connecting, .loading:
                    ProgressView().controlSize(.small)
                default:
                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityLabel(loc.t("a11y.statusIndicator", loc.appleStateTitle(record.state)))
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch record.state {
        case .ready: .green
        case .failed: .red
        default: .orange
        }
    }
}

/// Small trailing indicator: spinner while busy, colored dot otherwise.
struct StatusIndicator: View {
    @Environment(LocalizationManager.self) private var loc
    let state: ConnectionState

    var body: some View {
        Group {
            if state.isBusy {
                ProgressView().controlSize(.small)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
            }
        }
        // Color alone carries no meaning for VoiceOver.
        .accessibilityLabel(loc.t("a11y.statusIndicator", loc.stateTitle(state)))
    }

    private var color: Color {
        switch state {
        case .connected, .safelyDisconnected: .green
        case .failed: .red
        case .waitingForMTP, .unsupported: .orange
        default: .secondary
        }
    }
}

struct StorageRow: View {
    enum FinderStatus { case none, mounted, problem }

    @Environment(LocalizationManager.self) private var loc
    let storage: StorageInfo
    var finder: FinderStatus = .none
    var symbol: String?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(storage.name).lineLimit(1)
                if let free = storage.freeSpace {
                    Text(loc.t("storage.freeSpace", loc.formatBytes(free)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: symbol ?? (storage.kind == .removable ? "sdcard" : "internaldrive"))
        }
        .padding(.leading, 14)
        .accessibilityElement(children: .combine)
    }
}

/// "Mount in Finder" / "Unmount" for a storage row.
private struct FinderMountMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationManager.self) private var loc
    let deviceID: DeviceID
    let storageID: UInt32

    var body: some View {
        let finder = model.finder
        if finder.isAvailable, let volume = finder.volumes.first(where: { $0.address.deviceID == deviceID.rawValue && $0.address.storageID == storageID }) {
            switch finder.state(of: volume) {
            case .mounted(let url):
                Button(loc.t("finder.showInFinder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button(loc.t("finder.unmount")) { Task { await finder.unmount(volume) } }
            case .mounting, .unmounting:
                Text(loc.t("finder.state.mounting"))
            default:
                Button(loc.t("finder.mountInFinder")) { Task { await finder.mount(volume) } }
                    .disabled(!model.settings.finderIntegrationEnabled || !finder.mounter.canMountProgrammatically)
            }
        }
    }
}
