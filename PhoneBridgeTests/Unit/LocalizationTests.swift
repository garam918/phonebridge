import Foundation
import Observation
import Synchronization
import Testing
@testable import PhoneBridge

@MainActor
@Suite("Localization (ko / en)")
struct LocalizationTests {
    @Test func defaultsToKorean() {
        let manager = LocalizationManager(defaults: freshDefaults())
        #expect(manager.language == .korean)
        #expect(manager.t("sidebar.devices") == "연결된 기기")
        #expect(manager.t("menu.go") == "이동")
    }

    @Test func switchesToEnglishAndPersists() {
        let defaults = freshDefaults()
        let manager = LocalizationManager(defaults: defaults)
        manager.setLanguage(.english)
        #expect(manager.t("sidebar.devices") == "Connected Devices")
        #expect(manager.t("action.retry") == "Retry")
        #expect(defaults.string(forKey: LocalizationManager.languageDefaultsKey) == "en")
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["en"])

        let relaunched = LocalizationManager(defaults: defaults)
        #expect(relaunched.language == .english)
        #expect(relaunched.t("sidebar.devices") == "Connected Devices")

        relaunched.setLanguage(.korean)
        #expect(relaunched.t("action.retry") == "다시 시도")
    }

    @Test func languageChangeNotifiesObservers() {
        let manager = LocalizationManager(defaults: freshDefaults())
        let changed = Mutex(false)
        withObservationTracking {
            _ = manager.t("sidebar.devices")
        } onChange: {
            changed.withLock { $0 = true }
        }
        manager.setLanguage(.english)
        #expect(changed.withLock { $0 }, "views reading t() must re-render without relaunch")
    }

    @Test func formatsArgumentsPerLanguage() {
        let manager = LocalizationManager(defaults: freshDefaults())
        #expect(manager.t("status.itemCount", 3) == "항목 3개")
        #expect(manager.t("status.selectionCount", 1, 5) == "5개 중 1개 선택됨")
        #expect(manager.message(for: .deviceBusy(owner: "ptpcamerad (pid 1)")).contains("ptpcamerad (pid 1)"))
        manager.setLanguage(.english)
        #expect(manager.t("status.itemCount", 3) == "3 items")
        #expect(manager.t("status.selectionCount", 1, 5) == "1 of 5 selected")
        #expect(manager.t("storage.usage", "1 GB", "2 GB") == "1 GB of 2 GB used")
    }

    @Test func connectionStatesAndErrorsAreLocalized() {
        let manager = LocalizationManager(defaults: freshDefaults())
        let states: [ConnectionState] = [
            .disconnected, .usbDetected, .waitingForMTP(.fileTransferModeRequired), .waitingForMTP(.ptpModeSelected),
            .waitingForMTP(.deviceLocked), .connecting, .connected, .reconnecting, .failed(.timeout),
            .unsupported(.appleDevice), .unsupported(.ptpCamera), .safelyDisconnected,
        ]
        let errors: [DeviceError] = [
            .deviceBusy(owner: nil), .accessDenied, .sessionOpenFailed(detail: nil), .noMTPInterface, .disconnected,
            .objectNotFound, .protocolError(code: 0, detail: nil), .usbError(code: 0, detail: nil), .timeout,
            .cancelled, .storageFull, .outOfMemory, .unknown(detail: nil),
            .insufficientLocalSpace(required: 10, available: 1), .insufficientDeviceSpace(required: 0, available: 0),
            .localPermissionDenied(path: "/x"), .localReadFailed(path: "/x", detail: nil), .localWriteFailed(path: "/x", detail: nil),
            .verificationFailed(expected: 1, actual: 0), .readOnlyStorage, .unsupportedOperation, .invalidName,
            .nameConflict(name: "a"), .invalidDestination, .folderNotEmpty, .crossFolderMoveUnsupported,
        ]
        for language in AppLanguage.allCases {
            manager.setLanguage(language)
            for state in states {
                let title = manager.stateTitle(state)
                #expect(!title.hasPrefix("state."), "\(language) \(state.name)")
            }
            for error in errors {
                #expect(!manager.message(for: error).hasPrefix("error."), "\(language) \(error.localizationKey)")
            }
        }
    }

    /// Keys built at runtime (not visible to the source scan script).
    @Test func dynamicKeysExistInBothLanguages() {
        let manager = LocalizationManager(defaults: freshDefaults())
        var keys = FileCategory.allCases.map(\.localizationKey)
        keys += [StorageKind.internalStorage, .removable, .unknown].map { "storage.kind.\($0.rawValue)" }
        keys += ["disconnected", "usbDetected", "connecting", "connected", "reconnecting", "failed"].map { "state.\($0)" }
        keys += [TransferKind.download, .upload, .copy, .move, .delete].map { "transfer.kind.\($0.rawValue)" }
        keys += ["conflictPrompt.message", "conflictPrompt.folderMessage",
                 "error.insufficientLocalSpace.detail", "error.insufficientDeviceSpace.detail"]
        for key in keys {
            for language in AppLanguage.allCases {
                #expect(manager.hasTranslation(key, for: language), "\(key) missing for \(language)")
            }
        }
    }

    /// Every compiled key must exist in both languages with a non-identical
    /// Korean value (catches untranslated copies).
    @Test func compiledCatalogsHaveTheSameKeys() throws {
        let korean = try compiledTable("ko")
        let english = try compiledTable("en")
        #expect(korean.count >= 280)
        #expect(Set(korean.keys) == Set(english.keys))
        let untranslated = korean.filter { key, value in
            value == english[key] && !Self.languageNeutralKeys.contains(key)
        }
        #expect(untranslated.isEmpty, "\(untranslated.keys.sorted())")
    }

    private static let languageNeutralKeys: Set<String> = ["details.usbID", "conflict.app.androidFileTransfer", "local.title", "settings.tab.finder"]

    private func compiledTable(_ language: String) throws -> [String: String] {
        let url = try #require(Bundle.main.url(forResource: "Localizable", withExtension: "strings",
                                               subdirectory: nil, localization: language))
        let dictionary = try #require(NSDictionary(contentsOf: url) as? [String: String])
        return dictionary
    }
}
