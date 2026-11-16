import FitnessUI
import SwiftUI

struct SettingsView: View {
    @AppStorage(AppLanguage.preferenceKey) private var language = "system"
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = SettingsViewModel()
    @State private var isMacSyncPresented = false
    @State private var syncClient = HealthSyncClient()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    BrandMark()
                        .padding(.vertical, 4)
                }

                LanguageSettingsSection()
                PersonalSetupSection()
                intervalsSection
                garminSection
                macSection
                privacySection
            }
            .navigationTitle(AppLanguage.text("Impostazioni"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLanguage.text("Fine")) {
                        if viewModel.canSave { viewModel.save() }
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $isMacSyncPresented) {
                MacSyncView(client: syncClient)
            }
            .sheet(isPresented: $viewModel.isGarminLoginPresented) {
                GarminLoginView { ticket, serviceURL in
                    await viewModel.completeGarminLogin(ticket: ticket, serviceURL: serviceURL)
                }
            }
        }
        .environment(\.locale, AppLanguage.locale(for: language))
        .tint(Brand.ink)
    }

    private var macSection: some View {
        Section {
            Button {
                isMacSyncPresented = true
            } label: {
                HStack {
                    Label(AppLanguage.text("Sincronizza con il Mac"), systemImage: "laptopcomputer.and.iphone")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .tint(.primary)
            .accessibilityIdentifier("settings.macSync")
        } header: {
            Text("Mac")
        } footer: {
            Text(
                AppLanguage.text(
                    "Invia allenamenti e dati di Salute all'archivio locale sul Mac, per analizzarli con i tuoi strumenti."
                ))
        }
    }

    private var privacySection: some View {
        Section {
            Label {
                Text(
                    AppLanguage.text(
                        "I dati restano sul telefono: l'indice e i dettagli sono in una cache locale, le credenziali nel Keychain."
                    )
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "lock.shield")
                    .foregroundStyle(Brand.ink)
            }
        } header: {
            Text(AppLanguage.text("Privacy"))
        }
    }

    private var intervalsSection: some View {
        Group {
            Section {
                TextField(AppLanguage.text("ID atleta (es. i12345)"), text: $viewModel.athleteID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("settings.athleteID")
                SecureField("API key", text: $viewModel.apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("settings.apiKey")
            } header: {
                Text("Intervals.icu")
            } footer: {
                Link(
                    AppLanguage.text("Dove trovo ID e API key"),
                    destination: URL(string: "https://intervals.icu/settings")!)
            }

            Section {

                let canVerify = viewModel.canSave && viewModel.verification != .verifying
                Button {
                    Task { await viewModel.verify() }
                } label: {
                    HStack {
                        Label(
                            AppLanguage.text("Verifica connessione"), systemImage: "antenna.radiowaves.left.and.right"
                        )
                        .foregroundStyle(canVerify ? Brand.ink : Color(.tertiaryLabel))
                        Spacer()
                        StatusIcon(state: viewModel.verification)
                    }
                }
                .disabled(!canVerify)

                Button {
                    viewModel.save()
                } label: {
                    Label(AppLanguage.text("Salva credenziali"), systemImage: "key.fill")
                        .foregroundStyle(viewModel.canSave ? Brand.ink : Color(.tertiaryLabel))
                }
                .disabled(!viewModel.canSave)
                .accessibilityIdentifier("settings.save")

                if viewModel.hasStoredCredentials {
                    Button(role: .destructive) {
                        viewModel.clear()
                    } label: {
                        Label(AppLanguage.text("Rimuovi credenziali"), systemImage: "trash")
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    StatusText(state: viewModel.verification)
                    if let message = viewModel.saveMessage {
                        Text(message)
                    }
                }
            }
        }
    }

    private var garminSection: some View {
        Section {
            if let session = viewModel.garminSession {
                HStack {
                    Label(
                        session.displayName ?? AppLanguage.text("Account Garmin"),
                        systemImage: "person.crop.circle.badge.checkmark")
                    Spacer()
                    Text(AppLanguage.text("connesso"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.good)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Brand.goodWash, in: Capsule())
                }

                Button {
                    Task { await viewModel.verifyGarmin() }
                } label: {
                    HStack {
                        Text(AppLanguage.text("Verifica connessione"))
                        Spacer()
                        StatusIcon(state: viewModel.garminStatus)
                    }
                }
                .disabled(viewModel.garminStatus == .verifying)

                StatusText(state: viewModel.garminStatus)

                Button(AppLanguage.text("Esci da Garmin Connect"), role: .destructive) {
                    Task { await viewModel.logoutGarmin() }
                }
            } else {
                Button {
                    viewModel.isGarminLoginPresented = true
                } label: {
                    Label(AppLanguage.text("Accedi a Garmin Connect"), systemImage: "person.badge.key")
                }
                .accessibilityIdentifier("settings.garminLogin")

                StatusText(state: viewModel.garminStatus)
            }
        } header: {
            Text("Garmin Connect")
        } footer: {
            Text(AppLanguage.text("Login sul sito Garmin; la password non viene salvata."))
        }
    }
}

private struct StatusIcon: View {
    let state: SettingsViewModel.VerificationState

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .verifying:
            ProgressView()
        case .verified:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.good)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(Brand.bad)
        }
    }
}

private struct StatusText: View {
    let state: SettingsViewModel.VerificationState

    var body: some View {
        switch state {
        case .verified(let name):
            Text(AppLanguage.format("Connesso come %@", name))
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(Brand.bad)
        default:
            EmptyView()
        }
    }
}
