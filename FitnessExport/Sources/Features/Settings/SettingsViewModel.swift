import FitnessUI
import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    enum VerificationState: Equatable {
        case idle
        case verifying
        case verified(String)
        case failed(String)
    }

    @Published var athleteID: String
    @Published var apiKey: String
    @Published private(set) var verification: VerificationState = .idle
    @Published private(set) var saveMessage: String?

    @Published private(set) var hasStoredCredentials: Bool

    @Published private(set) var garminSession: GarminSession?
    @Published private(set) var garminStatus: VerificationState = .idle
    @Published var isGarminLoginPresented = false

    private let store: IntervalsCredentialsStore
    private let client: IntervalsClient
    private let garmin: GarminAuthenticator
    private let garminClient: GarminClient

    init(
        store: IntervalsCredentialsStore = IntervalsCredentialsStore(),
        client: IntervalsClient = IntervalsClient(),
        garmin: GarminAuthenticator = GarminAuthenticator(),
        garminClient: GarminClient = GarminClient()
    ) {
        self.store = store
        self.client = client
        self.garmin = garmin
        self.garminClient = garminClient
        let credentials = store.load()
        athleteID = credentials.athleteID
        apiKey = credentials.apiKey
        hasStoredCredentials = credentials.isConfigured
        garminSession = garmin.storedSession
    }

    var credentials: IntervalsCredentials {
        IntervalsCredentials(
            athleteID: athleteID.trimmingCharacters(in: .whitespaces),
            apiKey: apiKey.trimmingCharacters(in: .whitespaces))
    }

    var canSave: Bool {
        credentials.isConfigured
    }

    func save() {
        do {
            try store.save(credentials)
            hasStoredCredentials = true
            saveMessage = AppLanguage.text("Credenziali salvate nel Keychain.")
        } catch {
            saveMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func clear() {
        do {
            try store.clear()
            athleteID = ""
            apiKey = ""
            hasStoredCredentials = false
            verification = .idle
            saveMessage = AppLanguage.text("Credenziali rimosse.")
        } catch {
            saveMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func verify() async {
        guard canSave else { return }
        verification = .verifying
        do {
            let athlete = try await client.verify(credentials: credentials)
            verification = .verified(athlete.name ?? athlete.id)
        } catch {
            verification = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func completeGarminLogin(ticket: String, serviceURL: String) async {
        garminStatus = .verifying
        do {
            let session = try await garmin.establishSession(ticket: ticket, serviceURL: serviceURL)
            garminSession = session
            garminStatus = .verified(session.displayName ?? AppLanguage.text("account Garmin"))
        } catch {
            garminStatus = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func verifyGarmin() async {
        garminStatus = .verifying
        do {
            let session = try await garmin.validSession()
            let profile = try await garminClient.fetchProfile(session: session)
            garminSession = session
            garminStatus = .verified(profile.displayName)
        } catch {
            garminStatus = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func logoutGarmin() async {
        await garmin.logout()
        garminSession = nil
        garminStatus = .idle
    }
}
