import Foundation
import XCTest

@testable import FitnessSyncKit

final class PayloadSizeBenchmark: XCTestCase {

    func testPrintOneHourOfRunningOnTheWire() throws {
        let start = Date(timeIntervalSince1970: 1_773_298_500)
        let sources = [SourceRecord(bundleID: "com.apple.health", name: "Apple Watch")]

        var lines: [String] = []
        var totalRaw = 0
        var totalCompressed = 0
        var totalJSON = 0

        for (name, generator) in Self.series {
            let records = (0..<3_600).map { index in
                QuantityRecord(
                    uuid: UUID(),
                    start: start.addingTimeInterval(Double(index)),
                    end: start.addingTimeInterval(Double(index)),
                    value: generator(index),
                    sourceIndex: 0
                )
            }
            let columnar = SyncPayloadCodec.encodeQuantities(records, sources: sources)
            let compressed = PayloadCompression.lzfse.compress(columnar)
            let json = try JSONEncoder().encode(
                records.map {
                    ["uuid": $0.uuid.uuidString, "start": "\($0.start)", "value": "\($0.value)"]
                }
            )

            totalRaw += columnar.count
            totalCompressed += compressed.count
            totalJSON += json.count
            lines.append(
                String(
                    format: "  %-24@ columnar %6d B (%.1f B/sample)  compressed %6d B  JSON %7d B",
                    name as NSString, columnar.count,
                    Double(columnar.count) / Double(records.count),
                    compressed.count, json.count
                )
            )
        }

        print("\nOne hour of running at 1 Hz, 6 series of 3,600 samples:")
        for line in lines { print(line) }
        print(
            String(
                format: "  TOTAL  columnar %d B · compressed %d B · JSON %d B → %.1f× smaller than JSON",
                totalRaw, totalCompressed, totalJSON,
                Double(totalJSON) / Double(totalCompressed)
            )
        )
        print(
            String(
                format: "  UUIDs alone occupy %d B (%.0f%% of compressed): the rest of each row uses %.1f B",
                3_600 * 6 * 16,
                Double(3_600 * 6 * 16) / Double(totalCompressed) * 100,
                Double(totalRaw - 3_600 * 6 * 16) / Double(3_600 * 6)
            )
        )

        XCTAssertLessThan(totalCompressed, totalJSON)
    }

    private static let series: [(String, @Sendable (Int) -> Double)] = [
        ("frequenza cardiaca", { Double(140 + ($0 / 60) % 40) }),
        ("cadenza (passi)", { Double(84 + $0 % 4) }),
        ("velocità m/s", { 3.3 + Double($0 % 7) * 0.05 }),
        ("potenza W", { Double(280 + $0 % 60) }),
        ("lunghezza falcata m", { 1.15 + Double($0 % 12) * 0.01 }),
        ("distanza m", { Double($0) * 3.3 }),
    ]
}
