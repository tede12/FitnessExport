import Foundation
import XCTest

@testable import FitnessExport

final class IntervalsClientTests: ItalianLocalizationTestCase {
    private let credentials = IntervalsCredentials(athleteID: "i12345", apiKey: "secret-key")

    func testAuthorizationHeaderIsBasicWithAPIKeyUser() {

        XCTAssertEqual(IntervalsClient.authorizationHeader(apiKey: "secret-key"), "Basic QVBJX0tFWTpzZWNyZXQta2V5")
    }

    func testUploadRequestIsMultipartWithFileAndFields() throws {
        let request = try IntervalsClient.makeUploadRequest(
            fileData: Data([0x0E, 0x20]),
            fileName: "run.fit",
            name: "Corsa",
            externalID: "abc",
            credentials: credentials,
            boundary: "B"
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://intervals.icu/api/v1/athlete/i12345/activities")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "multipart/form-data; boundary=B")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            IntervalsClient.authorizationHeader(apiKey: "secret-key"))

        let body = try XCTUnwrap(request.httpBody)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"name\"\r\n\r\nCorsa\r\n"))
        XCTAssertTrue(text.contains("name=\"external_id\"\r\n\r\nabc\r\n"))
        XCTAssertTrue(
            text.contains("name=\"file\"; filename=\"run.fit\"\r\nContent-Type: application/octet-stream\r\n\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n--B--\r\n"))
        XCTAssertNotNil(body.range(of: Data([0x0E, 0x20])))
    }

    func testRequestWithoutCredentialsFails() {
        XCTAssertThrowsError(
            try IntervalsClient.makeRequest(
                path: "athlete/x", credentials: IntervalsCredentials(athleteID: "", apiKey: ""))
        ) { error in
            XCTAssertEqual(error as? IntervalsClient.ClientError, .notConfigured)
        }
    }

    func testUploadOutcomesFromHTTPStatus() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).fit")
        try Data([0x0E]).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let client = IntervalsClient(session: StubURLProtocol.makeSession())

        StubURLProtocol.response = (
            201,
            #"{"icu_athlete_id": "i12345", "id": "u1", "activities": [{"icu_athlete_id": "i12345", "id": "i987"}]}"#
        )
        let uploaded = try await client.upload(fileURL: fileURL, name: nil, externalID: nil, credentials: credentials)
        XCTAssertEqual(uploaded, .uploaded(activityID: "i987"))

        StubURLProtocol.response = (200, #"{"id": 987, "name": "Corsa"}"#)
        let legacy = try await client.upload(fileURL: fileURL, name: nil, externalID: nil, credentials: credentials)
        XCTAssertEqual(legacy, .uploaded(activityID: "987"))

        StubURLProtocol.response = (200, #"{"icu_athlete_id": "i12345", "id": "u2", "activities": [{"id": "i555"}]}"#)
        let allDuplicates = try await client.upload(
            fileURL: fileURL, name: nil, externalID: nil, credentials: credentials)
        XCTAssertEqual(allDuplicates, .duplicate(activityID: "i555", message: "Attività già presente (file identico)"))

        StubURLProtocol.response = (422, #"{"error": "duplicate of activity i99887766"}"#)
        let duplicate = try await client.upload(fileURL: fileURL, name: nil, externalID: nil, credentials: credentials)
        XCTAssertEqual(duplicate, .duplicate(activityID: "i99887766", message: "duplicate of activity i99887766"))

        StubURLProtocol.response = (401, "")
        do {
            _ = try await client.upload(fileURL: fileURL, name: nil, externalID: nil, credentials: credentials)
            XCTFail("atteso errore unauthorized")
        } catch {
            XCTAssertEqual(error as? IntervalsClient.ClientError, .unauthorized)
        }

        StubURLProtocol.response = (500, #"{"error": "boom"}"#)
        do {
            _ = try await client.upload(fileURL: fileURL, name: nil, externalID: nil, credentials: credentials)
            XCTFail("atteso errore http")
        } catch {
            XCTAssertEqual(error as? IntervalsClient.ClientError, .httpStatus(500, "boom"))
        }
    }

    func testDeleteRequestAndNotFoundIsTolerated() async throws {
        let client = IntervalsClient(session: StubURLProtocol.makeSession())
        StubURLProtocol.response = (200, #"{"icu_athlete_id": "i12345", "id": "i987"}"#)
        try await client.delete(activityID: "i987", credentials: credentials)

        StubURLProtocol.response = (404, #"{"error": "not found"}"#)
        try await client.delete(activityID: "i987", credentials: credentials)

        StubURLProtocol.response = (500, #"{"error": "boom"}"#)
        do {
            try await client.delete(activityID: "i987", credentials: credentials)
            XCTFail("atteso errore http")
        } catch {
            XCTAssertEqual(error as? IntervalsClient.ClientError, .httpStatus(500, "boom"))
        }
    }

    func testSearchRequestCoversTheDayAndMatchesExternalID() throws {
        let start = Date(timeIntervalSince1970: 1_773_298_500)
        let request = try IntervalsClient.makeSearchRequest(around: start, credentials: credentials)
        let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/api/v1/athlete/i12345/activities")
        XCTAssertEqual(components.queryItems?.first { $0.name == "oldest" }?.value, "2026-03-11")
        XCTAssertEqual(components.queryItems?.first { $0.name == "newest" }?.value, "2026-03-14")

        let list =
            #"[{"id": "i1", "external_id": "other"}, {"id": "i2", "external_id": "ABCDEF12-0000-0000-0000-000000000000"}]"#
        XCTAssertEqual(
            IntervalsClient.activityID(matchingExternalID: "abcdef12-0000-0000-0000-000000000000", in: Data(list.utf8)),
            "i2")
        XCTAssertNil(IntervalsClient.activityID(matchingExternalID: "missing", in: Data(list.utf8)))
    }

    func testCredentialsStoreRoundTrip() throws {
        let suite = "FitnessExportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = IntervalsCredentialsStore(service: suite, defaultsSuite: suite)
        do {
            try store.save(credentials)
        } catch let error as IntervalsCredentialsStore.KeychainError where error.status == errSecMissingEntitlement {
            throw XCTSkip("Keychain non disponibile senza firma del codice (build con CODE_SIGNING_ALLOWED=NO)")
        }
        XCTAssertEqual(store.load(), credentials)
        try store.clear()
        XCTAssertEqual(store.load(), IntervalsCredentials(athleteID: "", apiKey: ""))
    }
}

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var response: (status: Int, body: String) = (200, "")

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body) = Self.response
        let http = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
