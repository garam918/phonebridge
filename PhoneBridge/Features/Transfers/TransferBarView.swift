import SwiftUI

/// Bottom area: connection notices / item count on the left, transfer
/// summary on the right; expands into the transfer queue.
struct TransferBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        VStack(spacing: 0) {
            if model.isTransferPanelExpanded {
                TransferListView()
                    .frame(height: 230)
                Divider()
            }
            HStack(spacing: 12) {
                leftStatus
                Spacer(minLength: 12)
                TransferSummary()
                Button {
                    model.isTransferPanelExpanded.toggle()
                } label: {
                    Image(systemName: model.isTransferPanelExpanded ? "chevron.down" : "chevron.up")
                }
                .buttonStyle(.borderless)
                .help(model.isTransferPanelExpanded ? loc.t("transfer.hideQueue") : loc.t("transfer.showQueue"))
            }
            .font(.callout)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 28)
        }
        .background(.bar)
    }

    @ViewBuilder
    private var leftStatus: some View {
        if let name = model.previews.preparingName {
            HStack(spacing: 6) {
                ProgressView(value: model.previews.preparingFraction ?? 0)
                    .frame(width: 60)
                Text(loc.t("preview.preparing", name))
                Button(loc.t("action.cancel")) { model.previews.cancel() }
                    .buttonStyle(.link)
            }
        } else if let notice = model.notice {
            Label(noticeText(notice.kind), systemImage: noticeSymbol(notice.kind))
                .foregroundStyle(noticeColor(notice.kind))
        } else {
            Text(summary).foregroundStyle(.secondary)
        }
    }

    private var summary: String {
        let browser = model.browser
        guard model.detailContent == .browser, browser.phase == .loaded else { return "" }
        let count = browser.displayedItems.count
        if browser.selection.isEmpty {
            return loc.t("status.itemCount", count)
        }
        return loc.t("status.selectionCount", browser.selection.count, count)
    }

    private func noticeText(_ kind: AppNotice.Kind) -> String {
        switch kind {
        case .deviceConnected(let name): loc.t("notice.deviceConnected", name)
        case .deviceDisconnected(let name): loc.t("notice.deviceDisconnected", name)
        case .connectionFailed(let name): loc.t("notice.connectionFailed", name)
        case .finderRecovery(let count): loc.t("notice.finderRecovery", count)
        case .safelyDisconnected(let name): loc.t("notice.safelyDisconnected", name)
        case .disconnectBlocked: loc.t("notice.disconnectBlocked")
        case .transferCompleted(let title, let count): loc.t("notice.transferCompleted", itemsTitle(title, count))
        case .transferFailed(let title, let count): loc.t("notice.transferFailed", itemsTitle(title, count))
        case .diagnosticsExported: loc.t("notice.diagnosticsExported")
        }
    }

    private func itemsTitle(_ title: String, _ count: Int) -> String {
        count > 1 ? loc.t("transfer.titleMultiple", title, count - 1) : title
    }

    private func noticeSymbol(_ kind: AppNotice.Kind) -> String {
        switch kind {
        case .deviceConnected: "checkmark.circle.fill"
        case .deviceDisconnected: "cable.connector.slash"
        case .connectionFailed: "exclamationmark.triangle.fill"
        case .finderRecovery: "doc.badge.exclamationmark"
        case .safelyDisconnected: "eject.circle.fill"
        case .disconnectBlocked, .transferFailed: "exclamationmark.triangle.fill"
        case .transferCompleted: "checkmark.circle.fill"
        case .diagnosticsExported: "doc.text"
        }
    }

    private func noticeColor(_ kind: AppNotice.Kind) -> Color {
        switch kind {
        case .deviceConnected: .green
        case .deviceDisconnected: .secondary
        case .connectionFailed, .finderRecovery, .disconnectBlocked: .orange
        case .safelyDisconnected, .transferCompleted: .green
        case .transferFailed: .red
        case .diagnosticsExported: .secondary
        }
    }
}

/// "2 transfers · 12.3 MB/s · about 1 min left" with an overall bar.
private struct TransferSummary: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        let transfers = model.transfers
        let active = transfers.activeJobs
        HStack(spacing: 8) {
            if !active.isEmpty {
                ProgressView(value: transfers.overallFraction ?? 0)
                    .frame(width: 120)
                Text(activeText(count: active.count))
                    .monospacedDigit()
                Button {
                    transfers.cancelAll()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help(loc.t("transfer.cancelAll"))
            } else if !transfers.failedJobs.isEmpty {
                Label(loc.t("transfer.failedCount", transfers.failedJobs.count), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                Label(loc.t("transfer.idle"), systemImage: "arrow.up.arrow.down.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func activeText(count: Int) -> String {
        var parts = [loc.t("transfer.activeCount", count)]
        let transfers = model.transfers
        if transfers.currentSpeed > 0 {
            parts.append(loc.t("transfer.speed", loc.formatBytes(UInt64(transfers.currentSpeed))))
        }
        if let seconds = transfers.estimatedSecondsRemaining {
            parts.append(loc.t("transfer.remaining", loc.formatDuration(seconds)))
        }
        return parts.joined(separator: " · ")
    }
}

/// The queue: every job with its own progress, errors and actions.
struct TransferListView: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        let transfers = model.transfers
        VStack(spacing: 0) {
            HStack {
                Text(loc.t("transfer.title")).font(.headline)
                Spacer()
                Button(loc.t("transfer.clearFinished")) { transfers.clearFinished() }
                    .disabled(!transfers.jobs.contains { $0.state.isFinished })
                Button(loc.t("transfer.cancelAll")) { transfers.cancelAll() }
                    .disabled(transfers.activeJobs.isEmpty)
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            if transfers.jobs.isEmpty {
                ContentUnavailableView(loc.t("transfer.empty"), systemImage: "arrow.up.arrow.down",
                                       description: Text(loc.t("transfer.empty.description")))
            } else {
                List {
                    ForEach(transfers.jobs.reversed()) { job in
                        TransferRow(job: job)
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}

struct TransferRow: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationManager.self) private var loc
    let job: TransferJob

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(titleText).lineLimit(1)
                Text(job.isDragExport ? loc.t("transfer.kind.dragExport")
                                      : loc.t("transfer.kind.\(job.kind.rawValue)", job.destinationName))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                status
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var status: some View {
        switch job.state {
        case .queued:
            Text(loc.t("transfer.state.queued")).font(.caption).foregroundStyle(.secondary)
        case .running:
            if let fraction = job.fractionCompleted {
                ProgressView(value: fraction)
                    .accessibilityLabel(loc.t("a11y.transferProgress", titleText, Int((fraction * 100).rounded())))
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Text(runningDetail)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .completed:
            Text(completedDetail).font(.caption).foregroundStyle(.secondary)
        case .cancelled:
            Text(loc.t("transfer.state.cancelled")).font(.caption).foregroundStyle(.secondary)
        case .failed(let error):
            Text("\(loc.t("transfer.state.failed")) — \(loc.message(for: error))")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .help(error.technicalDetail ?? "")
            if let remedy = loc.remedy(for: error) {
                Text(remedy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if !job.warnings.isEmpty {
            Text(loc.t("transfer.leftovers", job.warnings.joined(separator: ", ")))
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !job.keptFolders.isEmpty {
            Text(loc.t("transfer.keptFolders", job.keptFolders.joined(separator: ", ")))
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var actions: some View {
        let transfers = model.transfers
        HStack(spacing: 4) {
            if !job.state.isFinished {
                Button { transfers.cancel(job) } label: { Image(systemName: "xmark.circle") }
                    .help(loc.t("action.cancel"))
            } else {
                if job.canRetry {
                    Button { transfers.retry(job) } label: { Image(systemName: "arrow.clockwise") }
                        .help(loc.t("action.retry"))
                }
                Button { transfers.remove(job) } label: { Image(systemName: "minus.circle") }
                    .help(loc.t("transfer.remove"))
            }
        }
        .buttonStyle(.borderless)
    }

    private var titleText: String {
        job.itemCount > 1 ? loc.t("transfer.titleMultiple", job.title, job.itemCount - 1) : job.title
    }

    private var runningDetail: String {
        var parts: [String] = []
        if job.kind == .delete {
            parts.append(loc.t("transfer.itemsProgress", job.finishedFiles, job.totalFiles))
        } else {
            if job.totalBytes > 0 {
                parts.append(loc.t("transfer.bytesProgress", loc.formatBytes(job.transferredBytes), loc.formatBytes(job.totalBytes)))
            }
            if job.totalFiles > 1 {
                parts.append(loc.t("transfer.filesProgress", job.finishedFiles, job.totalFiles))
            }
            if job.bytesPerSecond > 0 {
                parts.append(loc.t("transfer.speed", loc.formatBytes(UInt64(job.bytesPerSecond))))
            }
        }
        if let name = job.currentName { parts.append(name) }
        return parts.joined(separator: " · ")
    }

    private var completedDetail: String {
        var text = loc.t("transfer.state.completed")
        if job.skippedFiles > 0 { text += " · " + loc.t("transfer.skippedCount", job.skippedFiles) }
        return text
    }

    private var symbol: String {
        switch job.kind {
        case .download: "arrow.down.circle"
        case .upload: "arrow.up.circle"
        case .copy: "doc.on.doc"
        case .move: "arrow.right.circle"
        case .delete: "trash"
        }
    }

    private var tint: Color {
        switch job.state {
        case .failed: .red
        case .cancelled: .secondary
        case .completed: .green
        default: .accentColor
        }
    }
}
