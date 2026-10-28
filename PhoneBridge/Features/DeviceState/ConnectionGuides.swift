import SwiftUI

/// Numbered steps for switching Android's USB mode to "File transfer".
struct FileTransferGuide: View {
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        GuideBox(title: loc.t("guide.fileTransfer.title"),
                 steps: [
                     loc.t("guide.fileTransfer.step1"),
                     loc.t("guide.fileTransfer.step2"),
                     loc.t("guide.fileTransfer.step3"),
                     loc.t("guide.fileTransfer.step4"),
                 ],
                 footnote: loc.t("guide.fileTransfer.samsungNote"))
    }
}

/// The MTP session is open but the phone shows no storage. A locked screen
/// and a USB mode other than "File transfer" look the same (Samsung keeps its
/// MTP interface in every mode), so both are covered.
struct StorageAccessGuide: View {
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        GuideBox(title: loc.t("guide.locked.title"),
                 steps: [
                     loc.t("guide.locked.step1"),
                     loc.t("guide.locked.stepUSBMode"),
                     loc.t("guide.locked.step2"),
                 ],
                 footnote: loc.t("guide.locked.footnote"))
    }
}

/// Explains interface conflicts with other MTP clients. PhoneBridge never
/// terminates those processes itself.
struct AccessConflictGuide: View {
    @Environment(LocalizationManager.self) private var loc
    let owner: String?

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                Label(loc.t("conflict.title"), systemImage: "person.2.slash")
                    .font(.headline)
                Text(loc.t("conflict.description"))
                if let owner {
                    Text(loc.t("conflict.owner", owner))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                VStack(alignment: .leading, spacing: 3) {
                    bullet(loc.t("conflict.app.imageCapture"))
                    bullet(loc.t("conflict.app.androidFileTransfer"))
                    bullet(loc.t("conflict.app.thirdParty"))
                }
                .font(.callout)
                Text(loc.t("conflict.steps"))
                    .font(.callout)
                Text(loc.t("conflict.noAutoKill"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct GuideBox: View {
    let title: String
    let steps: [String]
    let footnote: String?

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold))
                            .frame(width: 18, height: 18)
                            .background(.tint.opacity(0.15), in: .circle)
                        Text(step).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let footnote {
                    Text(footnote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct EmptyStateView: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        if model.broker.devices.isEmpty {
            ScrollView {
                WelcomeContent()
            }
        } else {
            ContentUnavailableView(loc.t("empty.selectDevice"), systemImage: "sidebar.left",
                                   description: Text(loc.t("empty.selectDevice.description")))
        }
    }
}

/// "Connect a device" instructions, shown when no USB device is known.
struct WelcomeContent: View {
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "cable.connector")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(loc.t("empty.title"))
                .font(.title2.weight(.semibold))
            Text(loc.t("empty.description"))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            FileTransferGuide()
            TroubleshootingList()
        }
        .frame(maxWidth: 520)
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

/// Rounded container used for guides and checklists. Pure SwiftUI (unlike
/// GroupBox), so it also renders in offscreen snapshot tests.
struct Panel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8).strokeBorder(.separator)
            }
    }
}
