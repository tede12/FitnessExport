import Foundation
import XCTest

@testable import FitnessSyncKit

final class ColumnarCodecTests: XCTestCase {

    func testVarintRoundTripAcrossBoundaries() throws {
        let values: [UInt64] = [0, 1, 127, 128, 16_383, 16_384, 1 << 32, UInt64.max]
        var writer = ByteWriter()
        for value in values { writer.writeVarint(value) }

        var reader = ByteReader(writer.data)
        for expected in values {
            XCTAssertEqual(try reader.readVarint(), expected)
        }
        XCTAssertTrue(reader.isAtEnd)
    }

    func testZigzagKeepsSmallNegativesSmall() throws {
        var writer = ByteWriter()
        writer.writeZigzag(-1)
        XCTAssertEqual(writer.bytes.count, 1, "−1 deve costare un solo byte")

        var reader = ByteReader(writer.data)
        XCTAssertEqual(try reader.readZigzag(), -1)
    }

    func testReaderRejectsTruncatedInput() {
        var writer = ByteWriter()
        writer.writeDouble(3.14)
        let truncated = writer.data.prefix(4)

        var reader = ByteReader(Data(truncated))
        XCTAssertThrowsError(try reader.readDouble()) { error in
            XCTAssertEqual(error as? ColumnarError, .truncated)
        }
    }

    func testTimestampsRoundTripToTheMillisecond() throws {
        let start = Date(timeIntervalSince1970: 1_773_298_500)
        let dates = (0..<600).map { start.addingTimeInterval(Double($0)) }

        var writer = ByteWriter()
        ColumnarCodec.writeTimestamps(dates, into: &writer)
        var reader = ByteReader(writer.data)
        let decoded = try ColumnarCodec.readTimestamps(count: dates.count, from: &reader)

        XCTAssertEqual(decoded.count, dates.count)
        for (original, roundTripped) in zip(dates, decoded) {
            XCTAssertEqual(
                original.timeIntervalSince1970, roundTripped.timeIntervalSince1970, accuracy: 0.001
            )
        }
    }

    func testTimestampsAtOneHertzCostAboutTwoBytesEach() {
        let start = Date(timeIntervalSince1970: 1_773_298_500)
        let dates = (0..<3_600).map { start.addingTimeInterval(Double($0)) }

        var writer = ByteWriter()
        ColumnarCodec.writeTimestamps(dates, into: &writer)

        XCTAssertLessThan(writer.bytes.count, dates.count * 3)
        XCTAssertGreaterThan(dates.count * 8, writer.bytes.count * 2)
    }

    func testScaledDoublesRoundTripExactly() throws {
        let values: [Double] = [142, 143.5, 141.25, 180, 0, -12.125]

        var writer = ByteWriter()
        ColumnarCodec.writeDoubles(values, into: &writer)
        var reader = ByteReader(writer.data)
        let decoded = try ColumnarCodec.readDoubles(count: values.count, from: &reader)

        XCTAssertEqual(decoded, values)
    }

    func testHeartRateSeriesCompressesToAboutOneBytePerSample() {
        var value = 142.0
        var values: [Double] = []
        for i in 0..<3_600 {
            value += (i % 7 == 0) ? 1 : -1
            values.append(max(120, min(185, value)))
        }

        var writer = ByteWriter()
        ColumnarCodec.writeDoubles(values, into: &writer)

        XCTAssertLessThan(writer.bytes.count, values.count * 2)
    }

    func testIrrationalValuesFallBackToRawBitsWithoutLoss() throws {
        let values: [Double] = [Double.pi, 0.123456789123456, -0.30000000000000004]

        var writer = ByteWriter()
        ColumnarCodec.writeDoubles(values, into: &writer)
        XCTAssertEqual(writer.bytes.first, 0, "deve scegliere la modalità a bit grezzi")

        var reader = ByteReader(writer.data)
        XCTAssertEqual(try ColumnarCodec.readDoubles(count: values.count, from: &reader), values)
    }

    func testNonFiniteValuesNeverPickAScale() {
        XCTAssertNil(ColumnarCodec.exactScale(for: [1, Double.nan]))
        XCTAssertNil(ColumnarCodec.exactScale(for: [Double.infinity]))
        XCTAssertEqual(ColumnarCodec.exactScale(for: [1, 2, 3]), 1)
        XCTAssertEqual(ColumnarCodec.exactScale(for: [1.5, 2.25]), 100)
    }

    func testUUIDsRoundTrip() throws {
        let uuids = (0..<50).map { _ in UUID() }

        var writer = ByteWriter()
        ColumnarCodec.writeUUIDs(uuids, into: &writer)
        XCTAssertEqual(writer.bytes.count, uuids.count * 16)

        var reader = ByteReader(writer.data)
        XCTAssertEqual(try ColumnarCodec.readUUIDs(count: uuids.count, from: &reader), uuids)
    }
}
