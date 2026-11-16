import FitnessUI
import Foundation

struct IntervalsClient: Sendable {
    struct Athlete: Decodable, Equatable, Sendable {
        let id: String
        let name: String?
    }

    enum UploadOutcome: Equatable, Sendable {
        case uploaded(activityID: String?)

        case duplicate(activityID: String?, message: String)
    }

    enum ClientError: LocalizedError, Equatable {
        case notConfigured
        case unauthorized
        case httpStatus(Int, String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return AppLanguage.text("Configura ID atleta e API key nelle impostazioni.")
            case .unauthorized:
                return AppLanguage.text("Intervals.icu ha rifiutato le credenziali: controlla ID atleta e API key.")
            case .httpStatus(let code, let body):
                return AppLanguage.format(
                    "Intervals.icu ha risposto %@%@", code,
                    body.isEmpty ? "" : ": \(body)")
            case .invalidResponse:
                return AppLanguage.text("Risposta non valida da Intervals.icu.")
            }
        }
    }

    static let baseURL = URL(string: "https://intervals.icu/api/v1")!

    var session: URLSession = .shared

    func verify(credentials: IntervalsCredentials) async throws -> Athlete {
        let request = try Self.makeRequest(path: "athlete/\(credentials.athleteID)", credentials: credentials)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)
        guard let athlete = try? JSONDecoder().decode(Athlete.self, from: data) else {
            throw ClientError.invalidResponse
        }
        return athlete
    }

    func upload(fileURL: URL, name: String?, externalID: String?, credentials: IntervalsCredentials) async throws
        -> UploadOutcome
    {
        let fileData = try Data(contentsOf: fileURL)
        let request = try Self.makeUploadRequest(
            fileData: fileData,
            fileName: fileURL.lastPathComponent,
            name: name,
            externalID: externalID,
            credentials: credentials
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        return try Self.uploadOutcome(status: http.statusCode, data: data)
    }

    static func uploadOutcome(status: Int, data: Data) throws -> UploadOutcome {
        let body = String(data: data, encoding: .utf8) ?? ""
        switch status {
        case 200 where hasActivityList(data):
            return .duplicate(
                activityID: activityID(from: data), message: AppLanguage.text("Attività già presente (file identico)"))
        case 200..<300:
            return .uploaded(activityID: activityID(from: data))
        case 401, 403:
            throw ClientError.unauthorized
        case 422 where body.localizedCaseInsensitiveContains("duplicate"):
            let message = errorMessage(from: data) ?? body
            return .duplicate(activityID: activityID(inMessage: message), message: message)
        default:
            throw ClientError.httpStatus(status, errorMessage(from: data) ?? body)
        }
    }

    func exists(activityID: String, credentials: IntervalsCredentials) async throws -> Bool {
        let request = try Self.makeRequest(path: "activity/\(activityID)", credentials: credentials)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard http.statusCode != 404 else { return false }
        try Self.validate(response, data: data)
        return true
    }

    func delete(activityID: String, credentials: IntervalsCredentials) async throws {
        var request = try Self.makeRequest(path: "activity/\(activityID)", credentials: credentials)
        request.httpMethod = "DELETE"
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard http.statusCode != 404 else { return }
        try Self.validate(response, data: data)
    }

    func findActivityID(externalID: String, around date: Date, credentials: IntervalsCredentials) async throws
        -> String?
    {
        let request = try Self.makeSearchRequest(around: date, credentials: credentials)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)
        return Self.activityID(matchingExternalID: externalID, in: data)
    }

    static func makeSearchRequest(around date: Date, credentials: IntervalsCredentials) throws -> URLRequest {
        var request = try makeRequest(path: "athlete/\(credentials.athleteID)/activities", credentials: credentials)
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        components.queryItems = [
            URLQueryItem(name: "oldest", value: formatter.string(from: date.addingTimeInterval(-86_400))),
            URLQueryItem(name: "newest", value: formatter.string(from: date.addingTimeInterval(2 * 86_400))),
            URLQueryItem(name: "fields", value: "id,external_id,start_date"),
        ]
        request.url = components.url
        return request
    }

    static func activityID(matchingExternalID externalID: String, in data: Data) -> String? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return list.first { ($0["external_id"] as? String)?.caseInsensitiveCompare(externalID) == .orderedSame }
            .flatMap { $0["id"] }.map { "\($0)" }
    }

    static func authorizationHeader(apiKey: String) -> String {
        "Basic " + Data("API_KEY:\(apiKey)".utf8).base64EncodedString()
    }

    static func makeRequest(path: String, credentials: IntervalsCredentials) throws -> URLRequest {
        guard credentials.isConfigured else { throw ClientError.notConfigured }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.setValue(authorizationHeader(apiKey: credentials.apiKey), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func makeUploadRequest(
        fileData: Data,
        fileName: String,
        name: String?,
        externalID: String?,
        credentials: IntervalsCredentials,
        boundary: String = "FitnessExport-\(UUID().uuidString)"
    ) throws -> URLRequest {
        var request = try makeRequest(path: "athlete/\(credentials.athleteID)/activities", credentials: credentials)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(
            boundary: boundary,
            fields: [("name", name), ("external_id", externalID)].compactMap { key, value in value.map { (key, $0) } },
            file: (field: "file", name: fileName, mimeType: "application/octet-stream", data: fileData)
        )
        return request
    }

    static func multipartBody(
        boundary: String,
        fields: [(String, String)],
        file: (field: String, name: String, mimeType: String, data: Data)
    ) -> Data {
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }

        for (key, value) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(file.field)\"; filename=\"\(file.name)\"\r\n")
        append("Content-Type: \(file.mimeType)\r\n\r\n")
        body.append(file.data)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403: throw ClientError.unauthorized
        default: throw ClientError.httpStatus(http.statusCode, errorMessage(from: data) ?? "")
        }
    }

    static func activityID(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let activities = object["activities"] as? [[String: Any]], let id = activities.first?["id"] {
            return "\(id)"
        }
        if let activity = object["activity"] as? [String: Any], let id = activity["id"] { return "\(id)" }
        if let id = object["id"] { return "\(id)" }
        return nil
    }

    private static func hasActivityList(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["activities"] is [[String: Any]]
    }

    static func activityID(inMessage message: String) -> String? {
        message.range(of: #"\bi[0-9]{5,}\b"#, options: .regularExpression).map { String(message[$0]) }
    }

    static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (object["error"] as? String) ?? (object["message"] as? String)
    }
}
