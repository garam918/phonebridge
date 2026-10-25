import Foundation
import Observation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case korean = "ko"
    case english = "en"

    static let `default`: AppLanguage = .korean

    var id: String { rawValue }
    var locale: Locale { Locale(identifier: rawValue == "ko" ? "ko_KR" : "en_US") }
    /// Each language is always shown in its own script in the picker.
    var nativeName: String {
        switch self {
        case .korean: "한국어"
        case .english: "English"
        }
    }
}

/// Runtime language switching without relaunch.
///
/// SwiftUI's own lookup follows the process language, which can only change on
/// relaunch. Every app string therefore goes through `t(_:)`, which reads the
/// `.lproj` bundle of the selected language. Views read `language`/`bundle`
/// through Observation, so changing the language re-renders them in place.
@MainActor
@Observable
final class LocalizationManager {
    static let languageDefaultsKey = "app.language"

    private(set) var language: AppLanguage
    private(set) var bundle: Bundle
    var locale: Locale { language.locale }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let resourceBundle: Bundle

    init(defaults: UserDefaults = .standard, resourceBundle: Bundle = .main) {
        self.defaults = defaults
        self.resourceBundle = resourceBundle
        let stored = defaults.string(forKey: Self.languageDefaultsKey).flatMap(AppLanguage.init(rawValue:))
        let initial = stored ?? .default
        language = initial
        bundle = Self.lprojBundle(for: initial, in: resourceBundle)
    }

    func setLanguage(_ newValue: AppLanguage) {
        guard newValue != language else { return }
        language = newValue
        bundle = Self.lprojBundle(for: newValue, in: resourceBundle)
        defaults.set(newValue.rawValue, forKey: Self.languageDefaultsKey)
        // System-provided menu items (Edit, Window, Quit, ...) come from AppKit
        // and follow AppleLanguages, which only takes effect on next launch.
        defaults.set([newValue.rawValue], forKey: "AppleLanguages")
        Log.localization.info("language → \(newValue.rawValue, privacy: .public)")
    }

    /// Localized string for `key` in the selected language. Missing keys fall
    /// back to the key itself so they are easy to spot.
    func t(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    /// Localized format string with `String(format:)` arguments (%@, %d, %lld).
    func t(_ key: String, _ arguments: any CVarArg...) -> String {
        String(format: t(key), locale: locale, arguments: arguments)
    }

    func hasTranslation(_ key: String, for language: AppLanguage) -> Bool {
        let lproj = Self.lprojBundle(for: language, in: resourceBundle)
        let sentinel = "\u{1}missing\u{1}"
        return lproj.localizedString(forKey: key, value: sentinel, table: "Localizable") != sentinel
    }

    // MARK: - Domain helpers

    func message(for error: DeviceError) -> String {
        switch error {
        case .deviceBusy(let owner?):
            t("error.deviceBusy.withOwner", owner)
        case .insufficientLocalSpace(let required, let available) where required > 0:
            t("error.insufficientLocalSpace.detail", formatBytes(required), formatBytes(available))
        case .insufficientDeviceSpace(let required, let available) where required > 0:
            t("error.insufficientDeviceSpace.detail", formatBytes(required), formatBytes(available))
        case .localPermissionDenied(let path), .localReadFailed(let path, _), .localWriteFailed(let path, _):
            t(error.localizationKey, path)
        case .nameConflict(let name):
            t(error.localizationKey, name)
        default:
            t(error.localizationKey)
        }
    }

    /// What the user can do about an error, when there is something to do.
    func remedy(for error: DeviceError) -> String? {
        switch error {
        case .insufficientDeviceSpace, .storageFull: t("remedy.insufficientDeviceSpace")
        case .insufficientLocalSpace: t("remedy.insufficientLocalSpace")
        case .disconnected, .noMTPInterface: t("remedy.disconnected")
        case .usbError, .timeout, .protocolError: t("remedy.usb")
        case .localPermissionDenied, .localWriteFailed, .localReadFailed: t("remedy.localPermission")
        case .readOnlyStorage: t("remedy.readOnly")
        case .deviceBusy: t("remedy.deviceBusy")
        case .accessDenied, .sessionOpenFailed: t("remedy.locked")
        default: nil
        }
    }

    func stateTitle(_ state: ConnectionState) -> String {
        switch state {
        case .waitingForMTP(let reason):
            switch reason {
            case .fileTransferModeRequired: t("state.waitingForMTP.fileTransfer")
            case .ptpModeSelected: t("state.waitingForMTP.ptp")
            case .deviceLocked: t("state.waitingForMTP.locked")
            }
        case .unsupported(let reason):
            switch reason {
            case .appleDevice: t("state.unsupported.apple")
            case .ptpCamera: t("state.unsupported.camera")
            }
        default:
            t("state.\(state.name)")
        }
    }

    func formatBytes(_ value: UInt64) -> String {
        Int64(clamping: value).formatted(.byteCount(style: .file).locale(locale))
    }

    func formatDate(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    }

    func formatDuration(_ seconds: Double) -> String {
        let clamped = max(1, min(seconds, 360_000))
        return Duration.seconds(Int64(clamped.rounded()))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2).locale(locale))
    }

    func formatCount(_ value: Int) -> String {
        value.formatted(.number.locale(locale))
    }

    private static func lprojBundle(for language: AppLanguage, in bundle: Bundle) -> Bundle {
        guard let path = bundle.path(forResource: language.rawValue, ofType: "lproj"),
              let lproj = Bundle(path: path) else {
            Log.localization.error("missing \(language.rawValue, privacy: .public).lproj; falling back to main bundle")
            return bundle
        }
        return lproj
    }
}
