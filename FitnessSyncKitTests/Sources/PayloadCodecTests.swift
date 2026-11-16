import Foundation
import XCTest

@testable import FitnessSyncKit

final class PayloadCodecTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_773_298_500)

    private func makeQuantities(_ count: Int) -> [QuantityRecord] {
        (0..<count).map { index in
            QuantityRecord(
                uuid: UUID(),
                start: start.addingTimeInterval(Double(index)),
                end: start.addingTimeInterval(Double(index)),
                value: Double(140 + index % 40),
                sourceIndex: 0
            )
        }
    }

    func testQuantityRoundTripPreservesEveryField() throws {
        let records = makeQuantities(500)
        let sources = [SourceRecord(bundleID: "com.apple.health", name: "Apple Watch")]

        let encoded = SyncPayloadCodec.encodeQuantities(records, sources: sources)
        let decoded = try SyncPayloadCodec.decodeQuantities(encoded)

        XCTAssertEqual(decoded.sources, sources)
        XCTAssertEqual(decoded.records.count, records.count)
        for (original, roundTripped) in zip(records, decoded.records) {
            XCTAssertEqual(original.uuid, roundTripped.uuid)
            XCTAssertEqual(original.value, roundTripped.value)
            XCTAssertEqual(original.sourceIndex, roundTripped.sourceIndex)
            XCTAssertEqual(
                original.start.timeIntervalSince1970,
                roundTripped.start.timeIntervalSince1970,
                accuracy: 0.001
            )
            XCTAssertEqual(
                original.end.timeIntervalSince1970,
                roundTripped.end.timeIntervalSince1970,
                accuracy: 0.001
            )
        }
    }

    func testQuantityPayloadStaysUnderTwentyFiveBytesPerSample() {
        let records = makeQuantities(10_000)
        let sources = [SourceRecord(bundleID: "com.apple.health", name: "Apple Watch")]

        let encoded = SyncPayloadCodec.encodeQuantities(records, sources: sources)
        let compressed = PayloadCompression.lzfse.compress(encoded)

        XCTAssertLessThan(encoded.count, records.count * 25)
        XCTAssertLessThan(compressed.count, encoded.count)
    }

    func testCategoryRoundTrip() throws {
        let records = (0..<20).map { index in
            CategoryRecord(
                uuid: UUID(),
                start: start.addingTimeInterval(Double(index) * 3_600),
                end: start.addingTimeInterval(Double(index) * 3_600 + 1_800),
                value: index % 5,
                sourceIndex: 0
            )
        }
        let sources = [SourceRecord(bundleID: "com.apple.health", name: "iPhone")]

        let decoded = try SyncPayloadCodec.decodeCategories(
            SyncPayloadCodec.encodeCategories(records, sources: sources)
        )

        XCTAssertEqual(decoded.records.map(\.uuid), records.map(\.uuid))
        XCTAssertEqual(decoded.records.map(\.value), records.map(\.value))
    }

    func testRouteRoundTripKeepsCoordinatesBitForBit() throws {
        let points = (0..<300).map { index in
            RoutePointRecord(
                timestamp: start.addingTimeInterval(Double(index)),
                latitude: 0.0000123 + Double(index) * 0.000_01,
                longitude: 0.000_002 + Double(index) * 0.000_01,
                altitude: 120.5 + Double(index % 10),
                horizontalAccuracy: 4.5,
                verticalAccuracy: 3,
                speed: 3.4,
                course: 187.25
            )
        }
        let route = RouteRecord(workoutUUID: UUID(), points: points)

        let decoded = try SyncPayloadCodec.decodeRoutes(SyncPayloadCodec.encodeRoutes([route]))

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].workoutUUID, route.workoutUUID)

        XCTAssertEqual(decoded[0].points.map(\.latitude), points.map(\.latitude))
        XCTAssertEqual(decoded[0].points.map(\.longitude), points.map(\.longitude))
        XCTAssertEqual(decoded[0].points.map(\.altitude), points.map(\.altitude))
    }

    func testDeletionsRoundTrip() throws {
        let uuids = (0..<40).map { _ in UUID() }
        XCTAssertEqual(
            try SyncPayloadCodec.decodeDeletions(SyncPayloadCodec.encodeDeletions(uuids)), uuids
        )
    }

    func testDecodeRejectsAForeignPayload() {
        XCTAssertThrowsError(try SyncPayloadCodec.decodeQuantities(Data("non un batch".utf8)))
    }

    func testCompressionRoundTrip() throws {
        let records = makeQuantities(2_000)
        let raw = SyncPayloadCodec.encodeQuantities(
            records, sources: [SourceRecord(bundleID: "a", name: "b")]
        )
        let compressed = PayloadCompression.lzfse.compress(raw)
        let restored = try PayloadCompression.lzfse.decompress(
            compressed, expectedByteCount: raw.count
        )
        XCTAssertEqual(restored, raw)
    }
}
