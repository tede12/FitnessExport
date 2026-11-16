import FitnessUI
import Foundation
import OSLog

struct GarminClient: Sendable {
    struct Consumer: Codable, Equatable, Sendable {
        let consumerKey: String
        let consumerSecret: String

        enum CodingKeys: String, CodingKey {
            case consumerKey = "consumer_key"
            case consumerSecret = "consumer_secret"
        }
    }

    struct OAuth1Token: Equatable, Sendable {
        let token: String
        let secret: String
        let mfaToken: String?
    }

    struct Profile: Equatable, Sendable {
        let displayName: String
    }

    enum UploadOutcome: Equatable, Sendable {
        case uploaded(activityID: String?)

        case duplicate(activityID: String?, message: String)
    }

    enum ClientError: LocalizedError, Equatable {
        case notLoggedIn
        case unauthorized
        case httpStatus(Int, String)
        case invalidResponse(String)

        var errorDescription: String? {
            switch self {
            case .notLoggedIn:
                return AppLanguage.text("Accedi a Garmin Connect dalle impostazioni.")
            case .unauthorized:
                return AppLanguage.text(
                    "La sessione Garmin è scaduta o non valida: rifai l'accesso dalle impostazioni.")
            case .httpStatus(let code, let body):
                return AppLanguage.format(
                    "Garmin Connect ha risposto %@%@", code,
                    body.isEmpty ? "" : ": \(body)")
            case .invalidResponse(let detail):
                return AppLanguage.format(
                    "Risposta non valida da Garmin Connect%@", detail.isEmpty ? "." : ": \(detail)")
            }
        }
    }

    static let apiBaseURL = URL(string: "https://connectapi.garmin.com")!

    static let consumerURL = URL(string: "https://thegarth.s3.amazonaws.com/oauth_consumer.json")!
    static let userAgent = "com.garmin.android.apps.connectmobile"
    static let logger = Logger(subsystem: "org.fitnessexport.FitnessExport", category: "garmin.api")

    var session: URLSession = .shared

    func fetchConsumer() async throws -> Consumer {
        let cacheKey = "garmin.oauthConsumer"
        if let data = UserDefaults.standard.data(forKey: cacheKey),
            let cached = try? JSONDecoder().decode(Consumer.self, from: data)
        {
            return cached
        }
        let (data, response) = try await session.data(from: Self.consumerURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
            let consumer = try? JSONDecoder().decode(Consumer.self, from: data)
        else {
            throw ClientError.invalidResponse(AppLanguage.text("chiavi OAuth non disponibili"))
        }
        UserDefaults.standard.set(data, forKey: cacheKey)
        return consumer
    }

    func preauthorize(ticket: String, serviceURL: String, consumer: Consumer) async throws -> OAuth1Token {
        var components = URLComponents(
            url: Self.apiBaseURL.appendingPathComponent("oauth-service/oauth/preauthorized"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "ticket", value: ticket),
            URLQueryItem(name: "login-url", value: serviceURL),
            URLQueryItem(name: "accepts-mfa-tokens", value: "true"),
        ]
        let url = components.url!
        let signer = OAuth1Signer(consumerKey: consumer.consumerKey, consumerSecret: consumer.consumerSecret)
        var request = URLRequest(url: url)
        request.setValue(signer.authorizationHeader(method: "GET", url: url), forHTTPHeaderField: "Authorization")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, http) = try await send(request)
        let fields = Self.parseFormEncoded(String(data: data, encoding: .utf8) ?? "")
        guard let token = fields["oauth_token"], let secret = fields["oauth_token_secret"] else {
            Self.logger.error("OAuth preauthorization failed: HTTP \(http.statusCode)")
            throw ClientError.invalidResponse(AppLanguage.text("token OAuth1 mancante"))
        }
        return OAuth1Token(token: token, secret: secret, mfaToken: fields["mfa_token"])
    }

    func exchangeOAuth2(oauth1: OAuth1Token, consumer: Consumer) async throws -> (
        accessToken: String, refreshToken: String?, expiresIn: TimeInterval
    ) {
        let url = Self.apiBaseURL.appendingPathComponent("oauth-service/oauth/exchange/user/2.0")
        var body: [String: String] = [:]
        if let mfaToken = oauth1.mfaToken {
            body["mfa_token"] = mfaToken
        }
        let signer = OAuth1Signer(
            consumerKey: consumer.consumerKey, consumerSecret: consumer.consumerSecret, token: oauth1.token,
            tokenSecret: oauth1.secret)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            signer.authorizationHeader(method: "POST", url: url, bodyParameters: body),
            forHTTPHeaderField: "Authorization")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            body.map { "\(OAuth1Signer.encode($0.key))=\(OAuth1Signer.encode($0.value))" }.joined(separator: "&").utf8)

        let (data, _) = try await send(request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accessToken = object["access_token"] as? String, !accessToken.isEmpty
        else {
            throw ClientError.invalidResponse(AppLanguage.text("token OAuth2 mancante"))
        }
        return (accessToken, object["refresh_token"] as? String, (object["expires_in"] as? Double) ?? 3_600)
    }

    func fetchProfile(session gsession: GarminSession) async throws -> Profile {
        let request = Self.makeRequest(
            path: "userprofile-service/socialProfile", method: "GET", body: nil, contentType: nil,
            token: gsession.accessToken)
        let (data, _) = try await send(request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.invalidResponse("profilo")
        }
        let name =
            (object["displayName"] as? String) ?? (object["fullName"] as? String) ?? (object["userName"] as? String)
            ?? "?"
        return Profile(displayName: name)
    }

    func upload(fileURL: URL, session gsession: GarminSession) async throws -> UploadOutcome {
        let boundary = "FitnessExport-\(UUID().uuidString)"
        let body = IntervalsClient.multipartBody(
            boundary: boundary,
            fields: [],
            file: (
                field: "file", name: fileURL.lastPathComponent, mimeType: "application/octet-stream",
                data: try Data(contentsOf: fileURL)
            )
        )
        let request = Self.makeRequest(
            path: "upload-service/upload",
            method: "POST",
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)",
            token: gsession.accessToken
        )
        let (data, http) = try await send(request, acceptedStatuses: [200, 201, 202, 409])
        return try Self.parseUploadResponse(data, status: http.statusCode)
    }

    static func parseUploadResponse(_ data: Data, status: Int) throws -> UploadOutcome {
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let result = (object["detailedImportResult"] as? [String: Any]) ?? object
        let successes = result["successes"] as? [[String: Any]] ?? []
        let failures = result["failures"] as? [[String: Any]] ?? []

        if let first = successes.first {
            let id = first["internalId"].map { "\($0)" }
            return .uploaded(activityID: id)
        }

        let messages = failures.flatMap { ($0["messages"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["content"] as? String }
        let joined = messages.joined(separator: "; ")
        if status == 409 || joined.localizedCaseInsensitiveContains("duplicate") {
            let existingID = failures.first?["internalId"].map { "\($0)" }
            return .duplicate(
                activityID: existingID, message: joined.isEmpty ? AppLanguage.text("Attività già presente") : joined)
        }
        if !failures.isEmpty {
            throw ClientError.httpStatus(status, joined)
        }
        if (200..<300).contains(status) {

            return .uploaded(activityID: nil)
        }
        throw ClientError.httpStatus(status, snippet(data))
    }

    func exists(activityID: String, session gsession: GarminSession) async throws -> Bool {
        let request = Self.makeRequest(
            path: "activity-service/activity/\(activityID)", method: "GET", body: nil, contentType: nil,
            token: gsession.accessToken)
        let (_, http) = try await send(request, acceptedStatuses: Set(200..<300).union([404]))
        return http.statusCode != 404
    }

    func delete(activityID: String, session gsession: GarminSession) async throws {
        let request = Self.makeRequest(
            path: "activity-service/activity/\(activityID)", method: "DELETE", body: nil, contentType: nil,
            token: gsession.accessToken)
        _ = try await send(request, acceptedStatuses: [200, 202, 204, 404])
    }

    func findActivityID(startDate: Date, tolerance: TimeInterval = 120, session gsession: GarminSession) async throws
        -> String?
    {
        let request = Self.makeRequest(
            path: "activitylist-service/activities/search/activities", method: "GET", body: nil, contentType: nil,
            token: gsession.accessToken)
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        components.queryItems = [
            URLQueryItem(name: "startDate", value: formatter.string(from: startDate.addingTimeInterval(-86_400))),
            URLQueryItem(name: "endDate", value: formatter.string(from: startDate.addingTimeInterval(86_400))),
            URLQueryItem(name: "start", value: "0"),
            URLQueryItem(name: "limit", value: "50"),
        ]
        var searchRequest = request
        searchRequest.url = components.url
        let (data, _) = try await send(searchRequest)
        return Self.activityID(startingAt: startDate, tolerance: tolerance, in: data)
    }

    static func activityID(startingAt startDate: Date, tolerance: TimeInterval, in data: Data) -> String? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return list.first { activity in
            guard let text = activity["startTimeGMT"] as? String,
                let start = formatter.date(from: text.replacingOccurrences(of: ".0", with: ""))
            else { return false }
            return abs(start.timeIntervalSince(startDate)) <= tolerance
        }.flatMap { $0["activityId"] }.map { "\($0)" }
    }

    static func makeRequest(path: String, method: String, body: Data?, contentType: String?, token: String)
        -> URLRequest
    {
        var request = URLRequest(url: apiBaseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = body
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func send(_ request: URLRequest, acceptedStatuses: Set<Int> = Set(200..<300)) async throws -> (
        Data, HTTPURLResponse
    ) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse("") }
        Self.logger.info(
            "\(request.httpMethod ?? "GET", privacy: .private) \(request.url?.path ?? "", privacy: .private) → \(http.statusCode)"
        )
        if acceptedStatuses.contains(http.statusCode) {
            return (data, http)
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ClientError.unauthorized
        }
        throw ClientError.httpStatus(http.statusCode, Self.snippet(data))
    }

    static func snippet(_ data: Data, limit: Int = 160) -> String {
        guard var text = String(data: data, encoding: .utf8) else { return "" }
        if text.localizedCaseInsensitiveContains("<html") || text.hasPrefix("<!") {
            return AppLanguage.text("pagina HTML (non JSON)")
        }
        text = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    static func parseFormEncoded(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            result[parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
        }
        return result
    }
}
