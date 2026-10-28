import SwiftUI

/// Shown instead of the browser while an iPhone/iPad is not ready: trust and
/// unlock steps, reading the photo list, or a failed session (D75).
struct AppleDeviceStateView: View {
    let record: AppleDeviceRecord

    var body: some View {
        ScrollView {
            AppleDeviceStateContent(record: record)
        }
    }
}

struct AppleDeviceStateContent: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationManager.self) private var loc
    let record: AppleDeviceRecord

    var body: some View {
        VStack(spacing: 18) {
            header
            if record.state == .needsTrust || isFailed {
                GuideBox(title: loc.t("apple.guide.title"),
                         steps: [
                             loc.t("apple.guide.step1"),
                             loc.t("apple.guide.step2"),
                             loc.t("apple.guide.step3"),
                         ],
                         footnote: loc.t("apple.guide.footnote"))
            }
            if isFailed {
                Button(loc.t("action.retry")) { model.appleDevices.retry(record.id) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            if case .failed(let detail) = record.state {
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: 520)
        .padding(32)
        .frame(maxWidth: .infinity)
    }

    private var isFailed: Bool {
        if case .failed = record.state { return true }
        return false
    }

    private var header: some View {
        VStack(spacing: 10) {
            switch record.state {
            case .connecting, .loading:
                ProgressView().controlSize(.large)
            default:
                Image(systemName: isFailed ? "exclamationmark.triangle.fill" : (record.isTablet ? "ipad" : "iphone"))
                    .font(.system(size: 44))
                    .foregroundStyle(isFailed ? Color.red : Color.orange)
                    .symbolRenderingMode(.hierarchical)
            }
            Text(record.name)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(loc.appleStateTitle(record.state))
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(description)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var description: String {
        switch record.state {
        case .connecting: loc.t("apple.state.connecting.description")
        case .needsTrust: loc.t("apple.state.needsTrust.description")
        case .loading: loc.t("apple.state.loading.description")
        case .ready: ""
        case .failed: loc.t("apple.state.failed.description")
        }
    }
}
