import FitnessSyncKit
import FitnessUI
import SwiftUI

struct MenuBarView: View {
    @Bindable var host: SyncHost
    @Environment(\.openWindow) private var openWindow
    @State private var databasePath = ""
    @State private var showsLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: BrandMac.Spacing.m) {
            header

            if let failure = host.listenFailure {
                failureBanner(failure)
            }

            if host.status == .pairing, let payload = host.pairingPayload {
                pairingSection(payload)
            } else {
                if let progress = host.progress, !progress.isFinished {
                    progressSection(progress)
                }
                statsSection
                devicesSection
            }

            Divider()
            SettingsLink { Text(AppLanguage.text("Impostazioni")) }
            actions

            if showsLog, !host.log.isEmpty {
                logSection
            }
        }
        .padding(BrandMac.Spacing.l)
        .frame(width: 360)
        .task {
            databasePath = await host.databaseURL.path
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: BrandMac.Spacing.s) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.headline)
                if !host.advertisedHost.isEmpty {
                    Text("\(host.advertisedHost):\(String(host.port))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            if let lastSyncAt = host.lastSyncAt {
                Text(lastSyncAt, format: .relative(presentation: .numeric))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusTitle: String {
        switch host.status {
        case .idle: return AppLanguage.text("Non in ascolto")
        case .pairing: return AppLanguage.text("Associazione in corso")
        case .listening: return AppLanguage.text("In ascolto")
        case .syncing: return AppLanguage.text("Sincronizzazione")
        }
    }

    private var statusColor: Color {
        switch host.status {
        case .idle: return .secondary
        case .pairing: return BrandMac.warning
        case .listening: return BrandMac.good
        case .syncing: return BrandMac.signal
        }
    }

    private func failureBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: BrandMac.Spacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(BrandMac.signal)
            VStack(alignment: .leading, spacing: 2) {
                Text(AppLanguage.text("Il Mac non è in ascolto"))
                    .font(.callout.weight(.medium))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(BrandMac.Spacing.s)
        .background(BrandMac.signal.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private func pairingSection(_ payload: PairingPayload) -> some View {
        VStack(spacing: BrandMac.Spacing.s) {
            if let image = QRCode.nsImage(from: payload.qrString()) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 180, height: 180)
                    .accessibilityLabel(AppLanguage.text("Codice QR di associazione"))
            }
            Text(AppLanguage.text("Inquadralo con FitnessExport sull'iPhone."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(AppLanguage.text("Il codice vale per una sola associazione."))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private func progressSection(_ progress: SyncProgress) -> some View {
        VStack(alignment: .leading, spacing: BrandMac.Spacing.xs) {
            HStack {
                ProgressView().controlSize(.small)
                Text(progress.currentStream.isEmpty ? AppLanguage.text("Avvio…") : progress.currentStream)
                    .font(.callout)
                Spacer()
                Text("\(progress.upserted.formatted()) record")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let failure = progress.failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(BrandMac.warning)
            }
        }
        .padding(BrandMac.Spacing.s)
        .background(BrandMac.inkWash, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var statsSection: some View {
        if let stats = host.stats {
            VStack(alignment: .leading, spacing: BrandMac.Spacing.xs) {
                row(AppLanguage.text("Campioni"), stats.samples.formatted())
                row(AppLanguage.text("Allenamenti"), stats.workouts.formatted())
                row(AppLanguage.text("Punti GPS"), stats.routePoints.formatted())
                row(
                    AppLanguage.text("Archivio"),
                    ByteCountFormatter.string(
                        fromByteCount: Int64(stats.fileSizeBytes), countStyle: .file
                    )
                )
                if let earliest = stats.earliest, let latest = stats.latest {
                    row(
                        AppLanguage.text("Periodo"),
                        "\(earliest.formatted(.dateTime.month(.abbreviated).year())) → \(latest.formatted(.dateTime.month(.abbreviated).year()))"
                    )
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
        .font(.callout)
    }

    @ViewBuilder
    private var devicesSection: some View {
        if !host.devices.isEmpty {
            Divider()
            ForEach(host.devices) { device in
                HStack {
                    Image(systemName: "iphone")
                        .foregroundStyle(BrandMac.ink)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(device.name)
                            .font(.callout)
                        Text(
                            AppLanguage.format(
                                "associato %@",
                                device.pairedAt.formatted(date: .abbreviated, time: .omitted))
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(AppLanguage.text("Dimentica")) {
                        Task { await host.revoke(device) }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: BrandMac.Spacing.s) {
            if host.status == .pairing {
                Button(AppLanguage.text("Annulla associazione")) {
                    Task {
                        await host.stop()
                        await host.autostart()
                    }
                }
            } else {
                Button(
                    host.devices.isEmpty
                        ? AppLanguage.text("Associa iPhone…") : AppLanguage.text("Associa un altro iPhone…")
                ) {
                    Task { await host.startPairing() }
                }
                .buttonStyle(.borderedProminent)
                .tint(BrandMac.signal)
            }

            Button {
                openWindow(id: "training")
            } label: {
                Label(AppLanguage.text("Apri l'allenamento"), systemImage: "chart.line.uptrend.xyaxis")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            HStack(spacing: BrandMac.Spacing.m) {
                Button(AppLanguage.text("Mostra archivio")) {
                    Task {
                        let url = await host.databaseURL
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                Button(AppLanguage.text("Copia percorso")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(databasePath, forType: .string)
                }
                Spacer()
                Button(showsLog ? AppLanguage.text("Nascondi log") : "Log") {
                    showsLog.toggle()
                }
            }
            .buttonStyle(.link)
            .font(.caption)

            HStack {
                Button(AppLanguage.text("Risincronizza tutto…")) {
                    Task { await host.resetCursors() }
                }
                .font(.caption)
                .buttonStyle(.link)
                Spacer()
                Button(AppLanguage.text("Esci")) {
                    NSApplication.shared.terminate(nil)
                }
                .font(.caption)
                .buttonStyle(.link)
            }
        }
    }

    private var logSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(host.log.suffix(40).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(height: 140)
    }
}
