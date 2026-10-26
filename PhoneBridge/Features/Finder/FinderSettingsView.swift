import AppKit
import SwiftUI

/// Settings › Finder: integration switch, auto-mount, Finder writes
/// (experimental), extension and server status, manual mount / unmount per
/// storage, and unsaved Finder files.
struct FinderSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationManager.self) private var loc
    @Environment(AppSettings.self) private var settings
    @State private var confirmWrites = false

    var body: some View {
        let finder = model.finder
        if !finder.isAvailable {
            Form {
                Section {
                    Label(loc.t("finder.unavailableOS", ProcessInfo.processInfo.operatingSystemVersionString),
                          systemImage: "info.circle")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
        } else {
            settingsForm(finder)
        }
    }

    @ViewBuilder
    private func settingsForm(_ finder: FinderIntegrationManager) -> some View {
        Form {
            Section {
                Toggle(loc.t("finder.enable"), isOn: Binding(
                    get: { settings.finderIntegrationEnabled },
                    set: { value in Task { await finder.setEnabled(value) } }
                ))
                Toggle(loc.t("finder.autoMount"), isOn: Binding(
                    get: { settings.finderAutoMount },
                    set: { value in Task { await finder.setAutoMount(value) } }
                ))
                .disabled(!settings.finderIntegrationEnabled)
            }

            Section(loc.t("finder.writes.section")) {
                Toggle(isOn: Binding(
                    get: { settings.finderWritesEnabled },
                    set: { value in
                        if value {
                            confirmWrites = true
                        } else {
                            Task { await finder.setWritesEnabled(false) }
                        }
                    }
                )) {
                    HStack(spacing: 6) {
                        Text(loc.t("finder.writes.enable"))
                        Text(loc.t("finder.writes.experimental"))
                            .font(.caption)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                .disabled(!settings.finderIntegrationEnabled)
                Text(loc.t(settings.finderWritesEnabled ? "finder.writes.onNote" : "finder.writes.offNote"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.finderWritesEnabled {
                    Label(loc.t("finder.writes.realDevicesOnNote"), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text(loc.t("finder.writes.remount"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(loc.t("finder.status")) {
                LabeledContent(loc.t("finder.extension")) {
                    HStack {
                        Text(extensionText(finder.extensionStatus))
                            .foregroundStyle(finder.extensionStatus == .enabled ? Color.green : Color.orange)
                        Button {
                            Task { await finder.refreshExtensionStatus() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                if finder.extensionStatus != .enabled {
                    Text(loc.t("finder.extension.howToEnable"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if finder.mounter.canMountProgrammatically {
                        Button(loc.t("finder.openSystemSettings")) { finder.mounter.openExtensionSettings() }
                    }
                }
                LabeledContent(loc.t("finder.server")) {
                    Text(serverText(finder.serverStatus))
                        .foregroundStyle(serverColor(finder.serverStatus))
                        .textSelection(.enabled)
                }
                if !finder.mounter.canMountProgrammatically {
                    Text(loc.t("finder.manualMountNote"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(loc.t("finder.volumes")) {
                if finder.volumes.isEmpty {
                    Text(loc.t("finder.noVolumes")).foregroundStyle(.secondary)
                }
                ForEach(finder.volumes) { volume in
                    VolumeRow(volume: volume)
                }
            }

            if !finder.recovery.files.isEmpty {
                Section(loc.t("finder.recovery.title")) {
                    Text(loc.t("finder.recovery.explain"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(finder.recovery.files) { file in
                        RecoveryRow(file: file)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .alert(loc.t("finder.writes.realDevicesConfirmTitle"), isPresented: $confirmWrites) {
            Button(loc.t("finder.writes.confirmEnable")) { Task { await finder.setWritesEnabled(true) } }
            Button(loc.t("action.cancel"), role: .cancel) {}
        } message: {
            Text(loc.t("finder.writes.realDevicesConfirmMessage"))
        }
        .task {
            await finder.refreshExtensionStatus()
            await finder.refreshVolumes()
            finder.scanRecovery()
        }
    }

    private func extensionText(_ status: FinderExtensionStatus) -> String {
        switch status {
        case .unknown: loc.t("finder.extension.unknown")
        case .notFound: loc.t("finder.extension.notFound")
        case .disabled: loc.t("finder.extension.disabled")
        case .enabled: loc.t("finder.extension.enabled")
        case .unavailable(let message): loc.t("finder.extension.unavailable", message)
        }
    }

    private func serverText(_ status: FinderServerStatus) -> String {
        switch status {
        case .stopped: loc.t("finder.server.stopped")
        case .running: loc.t("finder.server.running")
        case .failed(let message) where message == "app-group-unavailable": loc.t("finder.server.noAppGroup")
        case .failed(let message): loc.t("finder.server.failed", message)
        }
    }

    private func serverColor(_ status: FinderServerStatus) -> Color {
        switch status {
        case .running: .green
        case .failed: .red
        case .stopped: .secondary
        }
    }
}

private struct VolumeRow: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationManager.self) private var loc
    let volume: MTPFileRepository.Volume

    var body: some View {
        let finder = model.finder
        let state = finder.state(of: volume)
        HStack {
            Image(systemName: volume.isDemo ? "testtube.2" : "externaldrive.connected.to.line.below")
            VStack(alignment: .leading, spacing: 2) {
                Text(volume.displayName)
                Text(stateText(state))
                    .font(.caption)
                    .foregroundStyle(stateColor(state))
                    .textSelection(.enabled)
                if let problem = finder.problem(of: volume) {
                    FinderProblemView(problem: problem)
                }
                if state.mountURL != nil {
                    Text(loc.t(finder.acceptsWrites(volume) ? "finder.volume.writable" : "finder.volume.readOnly"))
                        .font(.caption)
                        .foregroundStyle(finder.acceptsWrites(volume) ? Color.orange : Color.secondary)
                }
            }
            Spacer()
            switch state {
            case .mounted(let url):
                Button(loc.t("finder.showInFinder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button(loc.t("finder.unmount")) { Task { await finder.unmount(volume) } }
            case .mounting, .unmounting:
                ProgressView().controlSize(.small)
            default:
                Button(loc.t("finder.mount")) { Task { await finder.mount(volume) } }
                    .disabled(!model.settings.finderIntegrationEnabled || !finder.mounter.canMountProgrammatically)
            }
        }
    }

    private func stateText(_ state: VolumeMountState) -> String {
        switch state {
        case .unmounted: loc.t("finder.state.unmounted")
        case .mounting: loc.t("finder.state.mounting")
        case .mounted(let url): loc.t("finder.state.mounted", url.path)
        case .unmounting: loc.t("finder.state.unmounting")
        case .failed(let message) where message == "disabled": loc.t("finder.state.disabled")
        // The problem view explains failures; system error text stays out of the title.
        case .failed: loc.t("finder.state.unmounted")
        }
    }

    private func stateColor(_ state: VolumeMountState) -> Color {
        switch state {
        case .mounted: .green
        case .failed: .red
        default: .secondary
        }
    }
}

/// One unsaved Finder write: save it to the Mac or discard it.
private struct RecoveryRow: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationManager.self) private var loc
    let file: RecoverableFile
    @State private var confirmDiscard = false
    @State private var saveError: String?

    var body: some View {
        let name = file.fileName ?? loc.t("finder.recovery.unnamed")
        HStack(alignment: .top) {
            Image(systemName: "doc.badge.exclamationmark")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(location)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(file.uploadFailed ? Color.orange : Color.secondary)
                if let saveError {
                    Text(loc.t("finder.recovery.saveFailed", saveError))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            Button(loc.t("finder.recovery.save")) { save(name: name) }
            Button(loc.t("finder.recovery.discard"), role: .destructive) { confirmDiscard = true }
                .disabled(file.inUse)
        }
        .confirmationDialog(loc.t("finder.recovery.discardConfirm", name), isPresented: $confirmDiscard) {
            Button(loc.t("finder.recovery.discard"), role: .destructive) { model.finder.recovery.discard(file) }
        }
    }

    private var location: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: file.size), countStyle: .file)
        let folder = ([file.volumeName].compactMap { $0 } + file.folderPath).joined(separator: " › ")
        return folder.isEmpty ? size : "\(folder) · \(size)"
    }

    private var status: String {
        if file.inUse { return loc.t("finder.recovery.inUse") }
        guard file.uploadFailed else { return loc.t("finder.recovery.interrupted") }
        let reason = file.lastError.map { $0.hasPrefix("error.") ? loc.t($0) : $0 } ?? ""
        return loc.t("finder.recovery.failed", reason)
    }

    private func save(name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.finder.recovery.save(file, to: url)
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }
}

/// A Finder mount problem in plain words, with the action that fixes it.
struct FinderProblemView: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationManager.self) private var loc
    let problem: FinderProblem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            if problem == .extensionDisabled, model.finder.mounter.canMountProgrammatically {
                Button(loc.t("finder.openSystemSettings")) { model.finder.mounter.openExtensionSettings() }
                    .controlSize(.small)
            }
        }
    }

    private var text: String {
        switch problem {
        case .extensionDisabled: loc.t("finder.problem.extensionDisabled")
        case .serverUnavailable: loc.t("finder.problem.serverUnavailable")
        case .filesOpen: loc.t("finder.problem.busy")
        case .other(let detail): loc.t("finder.problem.generic", detail)
        }
    }
}
