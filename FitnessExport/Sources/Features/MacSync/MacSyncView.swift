import FitnessSyncKit
import FitnessUI
import SwiftUI

struct MacSyncView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var client: HealthSyncClient
    @State private var isScannerPresented = false
    @State private var pairingError: String?

    var body: some View {
        NavigationStack {
            Form {
                if client.hosts.isEmpty {
                    emptySection
                } else {
                    hostsSection
                    syncSection
                }
                privacySection
            }
            .navigationTitle("Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLanguage.text("Fine")) { dismiss() }
                }
            }
            .sheet(isPresented: $isScannerPresented) {
                scanner
            }
            .alert(
                AppLanguage.text("Associazione non riuscita"),
                isPresented: .init(
                    get: { pairingError != nil },
                    set: { if !$0 { pairingError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { pairingError = nil }
            } message: {
                Text(pairingError ?? "")
            }
        }
        .tint(Brand.ink)
    }

    private var emptySection: some View {
        Section {
            VStack(alignment: .leading, spacing: Brand.Spacing.m) {
                Label {
                    Text(AppLanguage.text("Apri FitnessExport sul Mac e scegli “Associa iPhone”."))
                } icon: {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .foregroundStyle(Brand.ink)
                }
                .font(.callout)

                Button {
                    isScannerPresented = true
                } label: {
                    Label(AppLanguage.text("Inquadra il codice"), systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.signal)
                .accessibilityIdentifier("macsync.pair.button")
            }
            .padding(.vertical, Brand.Spacing.xs)
        } header: {
            Text(AppLanguage.text("Nessun Mac associato"))
        } footer: {
            Text(
                AppLanguage.text(
                    "L'associazione avviene una sola volta: il codice contiene una chiave usa-e-getta, e da lì in poi i due dispositivi si riconoscono da soli."
                )
            )
        }
    }

    private var hostsSection: some View {
        Section {
            ForEach(client.hosts) { host in
                HStack {
                    Image(systemName: "desktopcomputer")
                        .foregroundStyle(Brand.ink)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(host.name)
                        Text("\(host.host):\(String(host.port))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(AppLanguage.text("Dimentica"), role: .destructive) {
                        client.forget(host)
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }
            Button {
                isScannerPresented = true
            } label: {
                Label(AppLanguage.text("Associa un altro Mac"), systemImage: "qrcode.viewfinder")
            }
        } header: {
            Text(AppLanguage.text("Mac associati"))
        }
    }

    private var syncSection: some View {
        Section {
            if let progress = client.progress {
                VStack(alignment: .leading, spacing: Brand.Spacing.xs) {
                    HStack {
                        Text(progress.streamTitle.isEmpty ? AppLanguage.text("Avvio…") : progress.streamTitle)
                            .font(.callout)
                        Spacer()
                        Text("\(progress.recordsSent.formatted())")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if progress.streamsTotal > 0 {
                        ProgressView(
                            value: Double(progress.streamsDone),
                            total: Double(progress.streamsTotal)
                        )
                        .tint(Brand.signal)
                    }
                }
                .padding(.vertical, Brand.Spacing.xs)
            } else {
                Button {
                    Task { await client.sync() }
                } label: {
                    Label(AppLanguage.text("Sincronizza adesso"), systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.signal)
                .disabled(client.isSyncing)
                .accessibilityIdentifier("macsync.sync.button")
            }

            if let summary = client.lastSummary, let lastSyncAt = client.lastSyncAt {
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        "\(summary.upserted.formatted()) record · \(byteText(summary.bytesSent)) · \(durationText(summary.duration))"
                    )
                    .font(.footnote)
                    Text(lastSyncAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = client.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Brand.bad)
            }
        } header: {
            Text(AppLanguage.text("Sincronizzazione"))
        } footer: {
            Text(
                AppLanguage.text(
                    "Il Mac chiede solo ciò che gli manca. La prima volta può volerci qualche minuto: è l'unica che legge tutta la storia."
                )
            )
        }
    }

    private var privacySection: some View {
        Section {
            Label {
                Text(
                    AppLanguage.text(
                        "Il trasferimento è cifrato end-to-end e va solo verso i Mac che hai associato. Nessun server, nessun account."
                    )
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "lock.shield")
                    .foregroundStyle(Brand.ink)
            }
        }
    }

    private var scanner: some View {
        NavigationStack {
            QRScannerView(
                onScan: { value in
                    isScannerPresented = false
                    Task {
                        do {
                            try await client.pair(withQRString: value)

                            try? await Task.sleep(for: .milliseconds(800))
                            await client.sync()
                        } catch let failure as SyncFailure {
                            pairingError = failure.message
                        } catch {
                            pairingError = error.localizedDescription
                        }
                    }
                },
                onCancel: { isScannerPresented = false }
            )
            .ignoresSafeArea()
            .navigationTitle(AppLanguage.text("Inquadra il Mac"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLanguage.text("Annulla")) { isScannerPresented = false }
                }
            }
        }
    }

    private func byteText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func durationText(_ duration: TimeInterval) -> String {
        duration < 60
            ? "\(Int(duration.rounded()))s"
            : "\(Int(duration / 60))m \(Int(duration.truncatingRemainder(dividingBy: 60)))s"
    }
}

#Preview {
    MacSyncView(client: HealthSyncClient())
}
