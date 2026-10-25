import AppKit
import CryptoKit
import Foundation
import OSLog
import UniformTypeIdentifiers

/// Help › Export Diagnostics: one text file the user can attach to a support
/// request. It holds versions, settings, connected devices (models and USB
/// ids, the serial number only as a short hash), Finder and transfer state, and
/// this launch's PhoneBridge log. No file or folder names: the log writes them
/// as private values, which macOS shows as "<private>".
@MainActor
enum DiagnosticsReport {
    /// Log lines of this launch kept in the report (newest).
    nonisolated static let logLineLimit = 3_000

    static func summary(model: AppModel, now: Date = Date(),
                        extensionStatusURL: URL? = ExtensionStatus.defaultURL()) -> String {
        var lines: [String] = []
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        lines.append("PhoneBridge diagnostics")
        lines.append("created: \(ISO8601DateFormatter().string(from: now))")
        lines.append("app: \(version) (\(build)) \(bundle.bundleIdentifier ?? "?")")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("mac: \(sysctlString("hw.model") ?? "?"), \(sysctlString("machdep.cpu.brand_string") ?? "?"), memory \(ProcessInfo.processInfo.physicalMemory >> 30) GiB")
        lines.append("libmtp: \(LibMTPBackend.libmtpVersion)")
        lines.append("")

        let settings = model.settings
        lines.append("[settings]")
        lines.append("language: \(model.localization.language.rawValue)")
        lines.append("finder integration: \(settings.finderIntegrationEnabled), auto mount: \(settings.finderAutoMount), writes: \(settings.finderWritesEnabled)")
        lines.append("demo device shown: \(settings.showDemoDevice), dual pane: \(settings.dualPane)")
        lines.append("")

        lines.append("[devices]")
        if model.broker.devices.isEmpty { lines.append("none") }
        for record in model.broker.devices {
            let usb = record.usb
            lines.append(String(format: "- id #%@ usb %04x:%04x", shortHash(record.id.rawValue), usb.vendorID, usb.productID)
                         + " state \(record.state.name) generation \(record.generation)")
            lines.append("  model: \(record.info?.manufacturer ?? "?") \(record.info?.model ?? "?"), version \(record.info?.deviceVersion ?? "?")")
            lines.append("  storages: \(record.storages.count), capabilities: 0x\(String(record.capabilities.rawValue, radix: 16))")
        }
        lines.append("")

        let finder = model.finder
        lines.append("[finder]")
        lines.append("extension: \(describe(finder.extensionStatus)), server: \(describe(finder.serverStatus))")
        for (id, state) in finder.states.sorted(by: { $0.key < $1.key }) {
            lines.append("- volume #\(shortHash(id)): \(describe(state))")
        }
        for (id, problem) in finder.problems.sorted(by: { $0.key < $1.key }) {
            lines.append("- problem #\(shortHash(id)): \(describe(problem))")
        }
        lines.append("")

        lines.append("[finder extension]")
        if let status = ExtensionStatus.read(from: extensionStatusURL) {
            let formatter = ISO8601DateFormatter()
            lines.append("version: \(status.version), updated \(formatter.string(from: status.updated)), mounted volumes \(status.mountedVolumes)")
            for event in status.events.suffix(50) {
                lines.append("- \(formatter.string(from: event.date)) [\(event.processID)] \(event.kind)\(event.detail.isEmpty ? "" : ": " + event.detail)")
            }
        } else {
            lines.append("no status file (extension not used yet, or no App Group)")
        }
        lines.append("")

        lines.append("[transfers]")
        let jobs = model.transfers.jobs
        lines.append("jobs: \(jobs.count), active: \(model.transfers.activeJobs.count)")
        for job in jobs {
            var line = "- \(job.kind.rawValue)\(job.isDragExport ? " (drag)" : ""): \(job.itemCount) item(s), files \(job.finishedFiles)/\(job.totalFiles), bytes \(job.transferredBytes)/\(job.totalBytes)"
            switch job.state {
            case .failed(let error): line += ", failed \(error.localizationKey)"
            default: line += ", \(String(describing: job.state))"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// This launch's PhoneBridge log entries (private values redacted by macOS).
    nonisolated static func logLines(subsystem: String = Log.subsystem, limit: Int = logLineLimit) -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return ["(log not available)"] }
        let predicate = NSPredicate(format: "subsystem == %@", subsystem)
        guard let entries = try? store.getEntries(matching: predicate) else { return ["(log not available)"] }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines: [String] = []
        for case let entry as OSLogEntryLog in entries {
            lines.append("\(formatter.string(from: entry.date)) [\(entry.category)] \(level(entry.level)) \(entry.composedMessage)")
        }
        return Array(lines.suffix(limit))
    }

    static func report(model: AppModel) async -> String {
        let log = await Task.detached(priority: .userInitiated) { logLines() }.value
        return summary(model: model) + "\n\n[log, this launch]\n" + log.joined(separator: "\n") + "\n"
    }

    /// Asks where to save, then writes the report.
    static func export(model: AppModel) {
        let loc = model.localization
        let panel = NSSavePanel()
        panel.title = loc.t("diagnostics.export.title")
        panel.message = loc.t("diagnostics.export.message")
        panel.allowedContentTypes = [.plainText]
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))
        panel.nameFieldStringValue = "PhoneBridge-\(loc.t("diagnostics.fileName"))-\(stamp).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let text = await report(model: model)
            do {
                try Data(text.utf8).write(to: url, options: .atomic)
                model.post(.diagnosticsExported)
            } catch {
                model.operationError = TransferManager.mapLocal(error, url: url, writing: true)
            }
        }
    }

    // MARK: - Helpers

    nonisolated static func shortHash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func describe(_ value: Any) -> String {
        // Mount URLs and failure texts may hold a device's personal name.
        let text = String(describing: value)
        if let open = text.firstIndex(of: "(") { return String(text[..<open]) }
        return text
    }

    nonisolated private static func level(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        default: "-"
        }
    }
}
