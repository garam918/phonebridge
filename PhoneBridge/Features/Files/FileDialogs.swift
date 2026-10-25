import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// New folder / rename sheet with live name validation.
struct NameEntrySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationManager.self) private var loc
    @Environment(\.dismiss) private var dismiss

    let dialog: FileDialog
    @State private var name = ""
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField(loc.t("dialog.name"), text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(submit)
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(loc.t("action.cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil || isWorking || name.isEmpty)
            }
        }
        .padding(20)
        .onAppear {
            switch dialog {
            case .rename(let item): name = item.name
            default: name = loc.t("dialog.newFolder.defaultName")
            }
        }
    }

    private var title: String {
        if case .rename(let item) = dialog { return loc.t("dialog.rename.title", item.name) }
        return loc.t("dialog.newFolder.title")
    }

    private var confirmTitle: String {
        if case .rename = dialog { return loc.t("action.rename") }
        return loc.t("action.create")
    }

    private var problem: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if case .rename(let item) = dialog, trimmed == item.name { return nil }
        if FileNameRules.validationError(for: trimmed) != nil { return loc.t("dialog.name.invalid") }
        let clash = model.browser.items.contains { existing in
            existing.name.caseInsensitiveCompare(trimmed) == .orderedSame && {
                if case .rename(let item) = dialog { return existing.id != item.id }
                return true
            }()
        }
        return clash ? loc.t("dialog.name.exists") : nil
    }

    private func submit() {
        guard problem == nil, !name.isEmpty, !isWorking else { return }
        isWorking = true
        Task {
            let ok: Bool
            switch dialog {
            case .rename(let item): ok = await model.rename(item, to: name)
            default: ok = await model.createFolder(named: name)
            }
            isWorking = false
            if ok { dismiss() }
        }
    }
}

/// Asks what to do with a name collision during a transfer.
struct ConflictSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationManager.self) private var loc
    let conflict: TransferConflict
    @State private var applyToAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(loc.t("conflictPrompt.title", conflict.name), systemImage: "doc.on.doc")
                .font(.headline)
            Text(loc.t(conflict.isFolder ? "conflictPrompt.folderMessage" : "conflictPrompt.message", conflict.destinationName))
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text(loc.t("conflictPrompt.existing")).foregroundStyle(.secondary)
                    Text(describe(size: conflict.existingSize, date: conflict.existingModified))
                }
                GridRow {
                    Text(loc.t("conflictPrompt.incoming")).foregroundStyle(.secondary)
                    Text(describe(size: conflict.incomingSize, date: conflict.incomingModified))
                }
            }
            .font(.callout)
            if !conflict.canReplace {
                Text(loc.t("conflictPrompt.replaceUnavailable"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle(loc.t("conflictPrompt.applyToAll"), isOn: $applyToAll)
            HStack {
                Button(loc.t("conflictPrompt.skip")) { answer(.skip) }
                Spacer()
                Button(loc.t("conflictPrompt.keepBoth")) { answer(.keepBoth) }
                    .keyboardShortcut(.defaultAction)
                Button(conflict.isFolder ? loc.t("conflictPrompt.merge") : loc.t("conflictPrompt.replace"), role: .destructive) {
                    answer(.replace)
                }
                .disabled(!conflict.canReplace)
            }
        }
        .padding(20)
        .frame(width: 440)
        .interactiveDismissDisabled()
    }

    private func describe(size: UInt64?, date: Date?) -> String {
        [size.map(loc.formatBytes), date.map(loc.formatDate)].compactMap { $0 }.joined(separator: " · ")
    }

    private func answer(_ action: ConflictAction) {
        model.transfers.answerConflict(ConflictDecision(action: action, applyToAll: applyToAll))
    }
}

/// Native open panels (user-selected files are granted to the sandbox).
@MainActor
enum Panels {
    static func chooseFolder(prompt: String, message: String, startingAt url: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = message
        panel.directoryURL = url
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseItemsToUpload(prompt: String, message: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = prompt
        panel.message = message
        return panel.runModal() == .OK ? panel.urls : []
    }
}

/// Sheets, dialogs, alerts and Quick Look shared by the main window.
struct FileDialogsModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationManager.self) private var loc

    func body(content: Content) -> some View {
        @Bindable var model = model
        @Bindable var previews = model.previews
        content
            .sheet(item: nameDialog) { (dialog: FileDialog) in
                NameEntrySheet(dialog: dialog)
            }
            .sheet(item: Binding(
                get: { model.transfers.pendingConflict },
                set: { _ in }
            )) { conflict in
                ConflictSheet(conflict: conflict)
            }
            .confirmationDialog(deleteTitle, isPresented: Binding(
                get: { if case .confirmDelete = model.activeDialog { true } else { false } },
                set: { if !$0 { model.activeDialog = nil } }
            ), titleVisibility: .visible) {
                Button(loc.t("action.delete"), role: .destructive) {
                    if case .confirmDelete(let items) = model.activeDialog { model.delete(items) }
                    model.activeDialog = nil
                }
                Button(loc.t("action.cancel"), role: .cancel) { model.activeDialog = nil }
            } message: {
                Text(loc.t("dialog.delete.message"))
            }
            .confirmationDialog(loc.t("dialog.disconnect.title"), isPresented: Binding(
                get: { if case .confirmDisconnect = model.activeDialog { true } else { false } },
                set: { if !$0 { model.activeDialog = nil } }
            ), titleVisibility: .visible) {
                Button(loc.t("dialog.disconnect.confirm"), role: .destructive) {
                    if case .confirmDisconnect(let id, _) = model.activeDialog {
                        Task { await model.safelyDisconnect(id) }
                    }
                    model.activeDialog = nil
                }
                Button(loc.t("action.cancel"), role: .cancel) { model.activeDialog = nil }
            } message: {
                if case .confirmDisconnect(_, let count) = model.activeDialog {
                    Text(loc.t("dialog.disconnect.message", count))
                }
            }
            .sheet(isPresented: $model.showOnboarding) {
                OnboardingView()
            }
            .sheet(isPresented: $model.showTroubleshooting) {
                TroubleshootingView()
            }
            .alert(loc.t("alert.operationFailed"), isPresented: Binding(
                get: { model.operationError != nil },
                set: { if !$0 { model.operationError = nil } }
            )) {
                Button(loc.t("action.ok")) { model.operationError = nil }
            } message: {
                Text(model.operationError.map(loc.message(for:)) ?? "")
            }
            .alert(loc.t("preview.failed"), isPresented: Binding(
                get: { model.previews.lastError != nil },
                set: { if !$0 { model.previews.dismissError() } }
            )) {
                Button(loc.t("action.ok")) { model.previews.dismissError() }
            } message: {
                Text(model.previews.lastError.map(loc.message(for:)) ?? "")
            }
            .quickLookPreview($previews.previewURL)
    }

    private var nameDialog: Binding<FileDialog?> {
        Binding(
            get: { () -> FileDialog? in
                switch model.activeDialog {
                case .newFolder, .rename: model.activeDialog
                default: nil
                }
            },
            set: { newValue in
                if newValue == nil { model.activeDialog = nil }
            }
        )
    }

    private var deleteTitle: String {
        guard case .confirmDelete(let items) = model.activeDialog else { return "" }
        return items.count == 1 ? loc.t("dialog.delete.titleSingle", items[0].name) : loc.t("dialog.delete.titleMultiple", items.count)
    }
}
