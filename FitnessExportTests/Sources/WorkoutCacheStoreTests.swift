import Foundation
import XCTest

@testable import FitnessExport

final class WorkoutCacheStoreTests: XCTestCase {
    func testSaveAndLoadIndexRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let store = WorkoutCacheStore(baseDirectoryURL: directory)

        let snapshot = WorkoutIndexSnapshot(
            updatedAt: Date(timeIntervalSince1970: 1_738_281_600),
            items: [
                WorkoutListItem(
                    id: UUID(),
                    activityType: .running,
                    startDate: Date(timeIntervalSince1970: 1_738_281_600),
                    endDate: Date(timeIntervalSince1970: 1_738_283_400),
                    duration: 1_800,
                    distanceInMeters: 5_000,
                    activeEnergyKilocalories: 320,
                    hasHeartRateData: true,
                    hasCadenceData: false
                )
            ]
        )

        try await store.saveIndex(snapshot)
        let loaded = await store.loadIndex()

        XCTAssertEqual(loaded, snapshot)
    }

    func testCorruptedIndexGetsInvalidated() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        let fileURL = directory.appendingPathComponent("workout-index.json")
        try Data("not-json".utf8).write(to: fileURL)

        let store = WorkoutCacheStore(baseDirectoryURL: directory)
        let loaded = await store.loadIndex()

        XCTAssertEqual(loaded, .empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }
}
