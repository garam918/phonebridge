import SwiftUI

/// Shown instead of the browser while a real device is not MTP-ready. Keeps
/// "USB connected" and "MTP access" visibly separate.
struct DeviceStateView: View {
    let record: DeviceRecord

    var body: some View {
        ScrollView {
            DeviceStateContent(record: record)
        }
    }
}

struct DeviceStateContent: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationManager.self) private var loc
    let record: DeviceRecord

    var body: some View {
        VStack(spacing: 18) {
            header
            ConnectionChecklist(state: record.state)
            guidance
            if record.state.canRetry {
                Button(loc.t(record.state == .safelyDisconnected ? "action.reconnect" : "action.retry")) { model.broker.retry(record.id) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            TechnicalDetails(record: record)
        }
        .frame(maxWidth: 520)
        .padding(32)
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        VStack(spacing: 10) {
            if record.state.isBusy {
                ProgressView().controlSize(.large)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 44))
                    .foregroundStyle(tint)
                    .symbolRenderingMode(.hierarchical)
            }
            Text(record.displayName)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(loc.stateTitle(record.state))
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(description)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var guidance: some View {
        switch record.state {
        case .waitingForMTP(.fileTransferModeRequired), .waitingForMTP(.ptpModeSelected):
            FileTransferGuide()
        case .waitingForMTP(.deviceLocked):
            StorageAccessGuide()
        case .failed(.deviceBusy(let owner)):
            AccessConflictGuide(owner: owner)
        case .failed(.sessionOpenFailed), .failed(.noMTPInterface):
            FileTransferGuide()
        default:
            EmptyView()
        }
    }

    private var description: String {
        switch record.state {
        case .failed(let error): loc.message(for: error)
        case .waitingForMTP(.fileTransferModeRequired): loc.t("state.waitingForMTP.fileTransfer.description")
        case .waitingForMTP(.ptpModeSelected): loc.t("state.waitingForMTP.ptp.description")
        case .waitingForMTP(.deviceLocked): loc.t("state.waitingForMTP.locked.description")
        case .unsupported(.appleDevice): loc.t("state.unsupported.apple.description")
        case .unsupported(.ptpCamera): loc.t("state.unsupported.camera.description")
        case .usbDetected: loc.t("state.usbDetected.description")
        case .connecting: loc.t("state.connecting.description")
        case .reconnecting: loc.t("state.reconnecting.description")
        case .disconnected: loc.t("state.disconnected.description")
        case .safelyDisconnected: loc.t("state.safelyDisconnected.description")
        case .connected: ""
        }
    }

    private var symbol: String {
        switch record.state {
        case .failed: "exclamationmark.triangle.fill"
        case .unsupported: "nosign"
        case .waitingForMTP: "cable.connector"
        case .disconnected: "cable.connector.slash"
        case .safelyDisconnected: "eject.circle"
        default: "smartphone"
        }
    }

    private var tint: Color {
        switch record.state {
        case .failed: .red
        case .unsupported, .waitingForMTP: .orange
        case .safelyDisconnected: .green
        default: .secondary
        }
    }
}

/// Two-step checklist: USB enumeration vs. MTP session.
private struct ConnectionChecklist: View {
    @Environment(LocalizationManager.self) private var loc
    let state: ConnectionState

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                row(title: loc.t("check.usb"), status: usbStatus)
                Divider()
                row(title: loc.t("check.mtp"), status: mtpStatus)
            }
        }
    }

    private enum Status { case ok, pending, waiting, failed, closed }

    private var usbStatus: Status {
        switch state {
        case .disconnected: .failed
        case .reconnecting: .pending
        default: .ok
        }
    }

    private var mtpStatus: Status {
        switch state {
        case .connected: .ok
        case .connecting, .usbDetected, .reconnecting: .pending
        case .waitingForMTP: .waiting
        case .failed, .unsupported, .disconnected: .failed
        case .safelyDisconnected: .closed
        }
    }

    private func row(title: String, status: Status) -> some View {
        HStack {
            Text(title)
            Spacer()
            switch status {
            case .ok:
                Label(loc.t("check.ok"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .pending:
                Label(loc.t("check.pending"), systemImage: "clock").foregroundStyle(.secondary)
            case .waiting:
                Label(loc.t("check.waiting"), systemImage: "hourglass").foregroundStyle(.orange)
            case .failed:
                Label(loc.t("check.failed"), systemImage: "xmark.circle.fill").foregroundStyle(.red)
            case .closed:
                Label(loc.t("check.closed"), systemImage: "eject.circle").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}

private struct TechnicalDetails: View {
    @Environment(LocalizationManager.self) private var loc
    let record: DeviceRecord

    var body: some View {
        DisclosureGroup(loc.t("details.title")) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow { Text(loc.t("details.usbID")); Text(record.usb.idPairDescription).textSelection(.enabled) }
                GridRow { Text(loc.t("details.usbName")); Text(record.usb.displayName) }
                GridRow { Text(loc.t("details.location")); Text("bus \(record.usb.busNumber) · address \(record.usb.address)") }
                GridRow {
                    Text(loc.t("details.interfaces"))
                    Text(interfaceSummary).textSelection(.enabled)
                }
                if case .failed(let error) = record.state, let detail = error.technicalDetail {
                    GridRow { Text(loc.t("details.error")); Text(detail).textSelection(.enabled) }
                }
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .padding(.top, 6)
        }
        .font(.callout)
    }

    private var interfaceSummary: String {
        guard !record.usb.interfaces.isEmpty else { return "—" }
        return record.usb.interfaces.map { interface in
            String(format: "#%d %02X/%02X/%02X", interface.number, interface.interfaceClass,
                   interface.interfaceSubClass, interface.interfaceProtocol)
                + (interface.name.map { " \($0)" } ?? "")
        }.joined(separator: "\n")
    }
}
