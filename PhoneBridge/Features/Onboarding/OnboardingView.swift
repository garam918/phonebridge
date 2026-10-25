import SwiftUI

/// First-run guide (Help › Getting Started opens it again): the four things a
/// new user needs, without a manual.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(loc.t("onboarding.title"))
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(loc.t("onboarding.subtitle"))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 14) {
                OnboardingStep(number: 1, symbol: "cable.connector", title: loc.t("onboarding.step1.title"),
                               text: loc.t("onboarding.step1.text"))
                OnboardingStep(number: 2, symbol: "hand.tap", title: loc.t("onboarding.step2.title"),
                               text: loc.t("onboarding.step2.text"))
                OnboardingStep(number: 3, symbol: "rectangle.split.2x1", title: loc.t("onboarding.step3.title"),
                               text: loc.t("onboarding.step3.text"))
                OnboardingStep(number: 4, symbol: "externaldrive", title: loc.t("onboarding.step4.title"),
                               text: loc.t(model.finder.isAvailable ? "onboarding.step4.text" : "onboarding.step4.unavailable"))
            }
            Button(loc.t("onboarding.start")) { model.completeOnboarding() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 520)
    }
}

private struct OnboardingStep: View {
    let number: Int
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(number). \(title)").font(.headline)
                Text(text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Help › Connection Troubleshooting: everything that commonly keeps a device
/// from showing up, with the file-transfer guide.
struct TroubleshootingView: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TroubleshootingList()
            FileTransferGuide()
            HStack {
                Button(loc.t("menu.help.exportDiagnostics")) { DiagnosticsReport.export(model: model) }
                    .help(loc.t("diagnostics.export.message"))
                Spacer()
                Button(loc.t("action.ok")) { model.showTroubleshooting = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

/// "Don't see your device?" checklist (welcome screen and Help).
struct TroubleshootingList: View {
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                Label(loc.t("troubleshoot.title"), systemImage: "questionmark.circle")
                    .font(.headline)
                ForEach(["troubleshoot.cable", "troubleshoot.port", "troubleshoot.unlock", "troubleshoot.otherApps"], id: \.self) { key in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(loc.t(key)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
