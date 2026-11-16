import Foundation
import XCTest

@testable import FitnessExport

final class GarminAndLedgerTests: ItalianLocalizationTestCase {
    func testOAuth1SignatureMatchesOauthlib() {

        let exchangeURL = URL(string: "https://connectapi.garmin.com/oauth-service/oauth/exchange/user/2.0")!
        let withToken = OAuth1Signer(consumerKey: "ck", consumerSecret: "cs", token: "tk", tokenSecret: "ts")
        let header = withToken.authorizationHeader(
            method: "POST", url: exchangeURL, nonce: "n0nce", timestamp: "1700000000")
        XCTAssertTrue(header.contains(#"oauth_signature="2exxTnyQ9fHxi%2Fk%2FF6WGEcm4o5U%3D""#), header)
        XCTAssertTrue(header.contains(#"oauth_token="tk""#))

        let preauthURL = URL(
            string:
                "https://connectapi.garmin.com/oauth-service/oauth/preauthorized?ticket=ST-1&login-url=https://sso.garmin.com/sso/embed&accepts-mfa-tokens=true"
        )!
        let noToken = OAuth1Signer(consumerKey: "ck", consumerSecret: "cs")
        let header2 = noToken.authorizationHeader(
            method: "GET", url: preauthURL, nonce: "n0nce", timestamp: "1700000000")
        XCTAssertTrue(header2.contains(#"oauth_signature="jXkOqI7Ek7fRCTHZia0Xb6hVhCs%3D""#), header2)
        XCTAssertFalse(header2.contains("oauth_token="))
    }

    func testServiceTicketExtraction() {
        let found = GarminAuthenticator.serviceTicket(
            in: URL(string: "https://sso.garmin.com/sso/embed?ticket=ST-12-abc&x=1"))
        XCTAssertEqual(found?.ticket, "ST-12-abc")
        XCTAssertEqual(found?.serviceURL, "https://sso.garmin.com/sso/embed")
        XCTAssertNil(GarminAuthenticator.serviceTicket(in: URL(string: "https://sso.garmin.com/sso/signin?service=x")))

        let page =
            "<html><body>{serviceUrl: 'https://sso.garmin.com/sso/embed', serviceTicket: 'ST-0713019-nzNP4DpkkT5pcomYSg76-cas'}</body></html>"
        let fromPage = GarminAuthenticator.serviceTicket(inPageText: page)
        XCTAssertEqual(fromPage?.ticket, "ST-0713019-nzNP4DpkkT5pcomYSg76-cas")
        XCTAssertEqual(fromPage?.serviceURL, "https://sso.garmin.com/sso/embed")
        XCTAssertEqual(
            GarminAuthenticator.serviceTicket(
                inPageText: "<a href=\"https://sso.garmin.com/sso/embed?ticket=ST-9-x\">")?.ticket, "ST-9-x")
        XCTAssertNil(GarminAuthenticator.serviceTicket(inPageText: "<html>login</html>"))
    }

    func testFormEncodedAndSnippet() {
        let fields = GarminClient.parseFormEncoded("oauth_token=a%2Fb&oauth_token_secret=s&mfa_token=m")
        XCTAssertEqual(fields["oauth_token"], "a/b")
        XCTAssertEqual(fields["mfa_token"], "m")
        XCTAssertEqual(GarminClient.snippet(Data("<!DOCTYPE html><html>…".utf8)), "pagina HTML (non JSON)")
        XCTAssertEqual(GarminClient.snippet(Data(String(repeating: "x", count: 200).utf8)).count, 161)
    }

    func testUploadResponseMapping() throws {
        let success = #"{"detailedImportResult":{"successes":[{"internalId":123,"externalId":"a.fit"}],"failures":[]}}"#
        XCTAssertEqual(
            try GarminClient.parseUploadResponse(Data(success.utf8), status: 201), .uploaded(activityID: "123"))

        let duplicate =
            #"{"detailedImportResult":{"successes":[],"failures":[{"internalId":19875234567,"externalId":"a.fit","messages":[{"code":202,"content":"Duplicate Activity"}]}]}}"#
        XCTAssertEqual(
            try GarminClient.parseUploadResponse(Data(duplicate.utf8), status: 409),
            .duplicate(activityID: "19875234567", message: "Duplicate Activity"))

        XCTAssertEqual(try GarminClient.parseUploadResponse(Data(), status: 202), .uploaded(activityID: nil))

        let failure = #"{"detailedImportResult":{"failures":[{"messages":[{"content":"Invalid file"}]}]}}"#
        XCTAssertThrowsError(try GarminClient.parseUploadResponse(Data(failure.utf8), status: 200))
    }

    func testBearerRequestHeaders() {
        let request = GarminClient.makeRequest(
            path: "upload-service/upload", method: "POST", body: nil, contentType: nil, token: "t")
        XCTAssertEqual(request.url?.absoluteString, "https://connectapi.garmin.com/upload-service/upload")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), GarminClient.userAgent)
    }

    func testLedgerRecordsAndPersists() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let id = UUID()

        let ledger = UploadLedger(fileURL: url)
        try await ledger.record(workoutID: id, platform: .intervals, remoteID: "42")
        try await ledger.record(workoutID: id, platform: .garmin, remoteID: nil)

        let reloaded = await UploadLedger(fileURL: url).all()
        XCTAssertEqual(Set(reloaded[id]?.keys ?? [:].keys), [.intervals, .garmin])
        XCTAssertEqual(reloaded[id]?[.intervals]?.remoteID, "42")

        try await ledger.remove(workoutID: id, platform: .intervals)
        try await ledger.remove(workoutID: id, platform: .garmin)
        let cleared = await UploadLedger(fileURL: url).all()
        XCTAssertNil(cleared[id], "senza piattaforme la voce sparisce")
    }

    func testActivitySearchMatchesByStartTime() {
        let start = Date(timeIntervalSince1970: 1_773_298_500)
        let list =
            #"[{"activityId": 111, "startTimeGMT": "2026-03-12 05:55:00"}, {"activityId": 222, "startTimeGMT": "2026-03-12 06:55:40.0"}, {"activityId": 333, "startTimeGMT": "2026-03-13 06:55:00"}]"#
        XCTAssertEqual(GarminClient.activityID(startingAt: start, tolerance: 120, in: Data(list.utf8)), "222")
        XCTAssertNil(
            GarminClient.activityID(
                startingAt: start.addingTimeInterval(3_600 * 5), tolerance: 120, in: Data(list.utf8)))
        XCTAssertNil(GarminClient.activityID(startingAt: start, tolerance: 120, in: Data("not json".utf8)))
    }

    func testSearchMatchesTypeDateAndDistance() {
        let item = WorkoutListItem(
            id: UUID(), activityType: .running,
            startDate: Date(timeIntervalSince1970: 1_773_298_500), endDate: Date(timeIntervalSince1970: 1_773_301_440),
            duration: 2_940, distanceInMeters: 10_000, activeEnergyKilocalories: 640, hasHeartRateData: true,
            hasCadenceData: true
        )
        XCTAssertTrue(LibraryViewModel.matches(item, query: "corsa"))
        XCTAssertTrue(LibraryViewModel.matches(item, query: "10.00 km"))
        XCTAssertTrue(LibraryViewModel.matches(item, query: "marzo corsa"))
        XCTAssertFalse(LibraryViewModel.matches(item, query: "bici"))
    }
}
