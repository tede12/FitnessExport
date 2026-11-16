import FitnessUI
import Foundation
import OSLog
import WebKit

@MainActor
final class GarminAuthenticator {

    nonisolated static let embedURL = "https://sso.garmin.com/sso/embed"
    nonisolated static let loginURL: URL = {
        var components = URLComponents(string: "https://sso.garmin.com/sso/signin")!
        components.queryItems = [
            URLQueryItem(name: "id", value: "gauth-widget"),
            URLQueryItem(name: "embedWidget", value: "true"),
            URLQueryItem(name: "gauthHost", value: embedURL),
            URLQueryItem(name: "service", value: embedURL),
            URLQueryItem(name: "source", value: embedURL),
            URLQueryItem(name: "redirectAfterAccountLoginUrl", value: embedURL),
            URLQueryItem(name: "redirectAfterAccountCreationUrl", value: embedURL),
            URLQueryItem(name: "clientId", value: "GarminConnect"),
            URLQueryItem(name: "locale", value: AppLanguage.code == "it" ? "it_IT" : "en_US"),
            URLQueryItem(name: "generateExtraServiceTicket", value: "true"),
            URLQueryItem(name: "generateTwoExtraServiceTickets", value: "true"),
        ]
        return components.url!
    }()
    nonisolated static let logger = Logger(subsystem: "org.fitnessexport.FitnessExport", category: "garmin")

    private let store: GarminSessionStore
    private let client: GarminClient

    init(store: GarminSessionStore = GarminSessionStore(), client: GarminClient = GarminClient()) {
        self.store = store
        self.client = client
    }

    nonisolated static func serviceTicket(in url: URL?) -> (ticket: String, serviceURL: String)? {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let ticket = components.queryItems?.first(where: { $0.name == "ticket" })?.value, !ticket.isEmpty
        else { return nil }
        components.query = nil
        components.fragment = nil
        return (ticket, components.string ?? url.absoluteString)
    }

    nonisolated static func serviceTicket(inPageText text: String) -> (ticket: String, serviceURL: String)? {
        func firstMatch(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text)
            else { return nil }
            return String(text[range])
        }
        guard
            let ticket = firstMatch(#"serviceTicket['"]?\s*[:=]\s*['"](ST-[A-Za-z0-9._-]+)['"]"#)
                ?? firstMatch(#"[?&]ticket=(ST-[A-Za-z0-9._-]+)"#)
        else { return nil }
        let serviceURL = firstMatch(#"serviceUrl['"]?\s*[:=]\s*['"]([^'"]+)['"]"#) ?? embedURL
        return (ticket, serviceURL)
    }

    var storedSession: GarminSession? {
        store.load()
    }

    func establishSession(ticket: String, serviceURL: String) async throws -> GarminSession {
        Self.logger.info("Service ticket received")
        let consumer = try await client.fetchConsumer()
        let oauth1 = try await client.preauthorize(ticket: ticket, serviceURL: serviceURL, consumer: consumer)
        let oauth2 = try await client.exchangeOAuth2(oauth1: oauth1, consumer: consumer)

        var session = GarminSession(
            oauthToken: oauth1.token,
            oauthTokenSecret: oauth1.secret,
            accessToken: oauth2.accessToken,
            refreshToken: oauth2.refreshToken,
            expiresAt: Date().addingTimeInterval(oauth2.expiresIn),
            displayName: nil
        )
        do {
            session.displayName = try await client.fetchProfile(session: session).displayName
        } catch {
            Self.logger.error("Profile read failed: \(error.localizedDescription, privacy: .private)")
        }
        try store.save(session)
        return session
    }

    func validSession() async throws -> GarminSession {
        guard let stored = store.load() else { throw GarminClient.ClientError.notLoggedIn }
        guard stored.isExpired else { return stored }
        return try await refreshSession(stored)
    }

    func refreshSession(_ stored: GarminSession) async throws -> GarminSession {
        do {
            let consumer = try await client.fetchConsumer()
            let oauth2 = try await client.exchangeOAuth2(
                oauth1: GarminClient.OAuth1Token(
                    token: stored.oauthToken, secret: stored.oauthTokenSecret, mfaToken: nil),
                consumer: consumer
            )
            var refreshed = stored
            refreshed.accessToken = oauth2.accessToken
            refreshed.refreshToken = oauth2.refreshToken
            refreshed.expiresAt = Date().addingTimeInterval(oauth2.expiresIn)
            try store.save(refreshed)
            return refreshed
        } catch GarminClient.ClientError.unauthorized {

            try? store.delete()
            throw GarminClient.ClientError.notLoggedIn
        }
    }

    func logout() async {
        try? store.delete()
        let dataStore = WKWebsiteDataStore.default()
        let cookies = await dataStore.httpCookieStore.allCookies()
        for cookie in cookies where cookie.domain.hasSuffix("garmin.com") {
            await dataStore.httpCookieStore.deleteCookie(cookie)
        }
    }
}
