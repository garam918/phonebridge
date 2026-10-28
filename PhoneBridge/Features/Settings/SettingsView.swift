import SwiftUI

struct SettingsView: View {
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label(loc.t("settings.tab.general"), systemImage: "gearshape") }
            FinderSettingsView()
                .tabItem { Label(loc.t("settings.tab.finder"), systemImage: "externaldrive") }
            DiagnosticsSettingsView()
                .tabItem { Label(loc.t("settings.tab.diagnostics"), systemImage: "stethoscope") }
        }
        .frame(width: 560, height: 480)
    }
}

private struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationManager.self) private var loc
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Form {
            Section {
                Picker(loc.t("settings.language"), selection: Binding(
                    get: { loc.language },
                    set: { loc.setLanguage($0) }
                )) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.nativeName).tag(language)
                    }
                }
                Text(loc.t("settings.language.note"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle(loc.t("settings.foldersFirst"), isOn: Binding(
                    get: { settings.foldersFirst },
                    set: { model.setFoldersFirst($0) }
                ))
            }
            OpenOnConnectSection(setting: model.launchOnConnect)
        }
        .formStyle(.grouped)
    }
}

private struct DiagnosticsSettingsView: View {
    @Environment(LocalizationManager.self) private var loc
    @State private var usbDeviceCount: Int32?

    var body: some View {
        Form {
            LabeledContent(loc.t("settings.diagnostics.libmtp"), value: LibMTPBackend.libmtpVersion)
            LabeledContent(loc.t("settings.diagnostics.usbDevices")) {
                if let usbDeviceCount {
                    Text(usbDeviceCount >= 0 ? "\(usbDeviceCount)" : loc.t("settings.diagnostics.usbError", Int(usbDeviceCount)))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            Text(loc.t("settings.diagnostics.logHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .formStyle(.grouped)
        .task {
            // libusb enumeration touches the USB stack; keep it off the main actor.
            usbDeviceCount = await Task.detached { LibMTPBackend.visibleUSBDeviceCount() }.value
        }
    }
}

/// Settings › General: open PhoneBridge when a phone is plugged in (D73).
private struct OpenOnConnectSection: View {
    @Environment(LocalizationManager.self) private var loc
    let setting: LaunchOnConnectSetting

    var body: some View {
        Section {
            Toggle(loc.t("settings.openOnConnect"), isOn: Binding(
                get: { setting.isOn },
                set: { setting.setEnabled($0) }
            ))
            Text(loc.t("settings.openOnConnect.note"))
                .font(.caption)
                .foregroundStyle(.secondary)
            switch setting.state {
            case .needsApproval:
                Label(loc.t("settings.openOnConnect.needsApproval"), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button(loc.t("settings.openOnConnect.openSettings")) { setting.openLoginItemsSettings() }
            case .unavailable(let detail):
                Label(loc.t("settings.openOnConnect.failed", detail), systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
            case .on, .off:
                EmptyView()
            }
        }
        .onAppear { setting.refresh() }
    }
}

