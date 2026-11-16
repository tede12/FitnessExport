import FitnessSyncKit
import Foundation
import XCTest

@testable import FitnessExportMac

final class HealthDatabaseTests: XCTestCase {
    private var directory: URL!
    private var database: HealthDatabase!

    private let start = Date(timeIntervalSince1970: 1_773_298_500)
    private let source = SourceRecord(bundleID: "com.apple.health", name: "Apple Watch")

    override func setUp() async throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        database = try HealthDatabase(url: directory.appendingPathComponent("test.sqlite"))
    }

    override func tearDown() async throws {
        database = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testArchiveFilesAreOwnerOnly() async throws {
        let manager = FileManager.default
        let url = directory.appendingPathComponent("test.sqlite")
        let archive = try manager.attributesOfItem(atPath: url.path)
        XCTAssertEqual((archive[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let folder = try manager.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((folder[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        for suffix in ["-wal", "-shm"] where manager.fileExists(atPath: url.path + suffix) {
            let attributes = try manager.attributesOfItem(atPath: url.path + suffix)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    private func quantity(_ uuid: UUID, value: Double, offset: TimeInterval = 0) -> QuantityRecord {
        QuantityRecord(
            uuid: uuid,
            start: start.addingTimeInterval(offset),
            end: start.addingTimeInterval(offset),
            value: value,
            sourceIndex: 0
        )
    }

    func testSendingTheSameSampleTwiceKeepsOneRow() async throws {
        let uuid = UUID()
        let stream = SyncStream.quantity("heart_rate")

        _ = try await database.applyQuantities(
            [quantity(uuid, value: 142)], sources: [source], metricKey: "heart_rate",
            stream: stream, anchor: Data([1])
        )
        _ = try await database.applyQuantities(
            [quantity(uuid, value: 142)], sources: [source], metricKey: "heart_rate",
            stream: stream, anchor: Data([2])
        )

        let stats = try await database.stats()
        XCTAssertEqual(stats.samples, 1)
    }

    func testResendingAnUpdatedSampleOverwritesTheValue() async throws {
        let uuid = UUID()
        let stream = SyncStream.quantity("heart_rate")

        _ = try await database.applyQuantities(
            [quantity(uuid, value: 142)], sources: [source], metricKey: "heart_rate",
            stream: stream, anchor: nil
        )
        _ = try await database.applyQuantities(
            [quantity(uuid, value: 150)], sources: [source], metricKey: "heart_rate",
            stream: stream, anchor: nil
        )

        let stats = try await database.stats()
        XCTAssertEqual(stats.samples, 1, "una correzione aggiorna la riga, non ne aggiunge una")
    }

    func testCursorAdvancesWithTheBatchThatWroteTheData() async throws {
        let stream = SyncStream.quantity("heart_rate")
        let before = try await database.cursor(for: stream)
        XCTAssertNil(before)

        _ = try await database.applyQuantities(
            [quantity(UUID(), value: 140)], sources: [source], metricKey: "heart_rate",
            stream: stream, anchor: Data([0xAB, 0xCD])
        )

        let after = try await database.cursor(for: stream)
        XCTAssertEqual(after, Data([0xAB, 0xCD]))
    }

    func testAFailedBatchLeavesNeitherRowsNorCursor() async throws {
        let stream = SyncStream.quantity("heart_rate")
        _ = try await database.applyQuantities(
            [quantity(UUID(), value: 140)], sources: [source], metricKey: "heart_rate",
            stream: stream, anchor: Data([1])
        )

        await assertThrowsErrorAsync(
            try await database.applyQuantities(
                [
                    self.quantity(UUID(), value: 141),
                    QuantityRecord(
                        uuid: UUID(), start: self.start, end: self.start, value: 1, sourceIndex: 99
                    ),
                ],
                sources: [self.source], metricKey: "heart_rate", stream: stream,
                anchor: Data([2])
            )
        )

        let stats = try await database.stats()
        XCTAssertEqual(stats.samples, 1)
        let cursor = try await database.cursor(for: stream)
        XCTAssertEqual(cursor, Data([1]))
    }

    func testResetCursorsKeepsTheData() async throws {
        let stream = SyncStream.quantity("heart_rate")
        _ = try await database.applyQuantities(
            [quantity(UUID(), value: 140)], sources: [source], metricKey: "heart_rate",
            stream: stream, anchor: Data([1])
        )

        try await database.resetCursors()

        let cursor = try await database.cursor(for: stream)
        XCTAssertNil(cursor)
        let stats = try await database.stats()
        XCTAssertEqual(stats.samples, 1, "risincronizzare non deve cancellare quello che c'è già")
    }

    func testDeletionRemovesTheSample() async throws {
        let uuid = UUID()
        let stream = SyncStream.quantity("heart_rate")
        _ = try await database.applyQuantities(
            [quantity(uuid, value: 140)], sources: [source], metricKey: "heart_rate",
            stream: stream, anchor: nil
        )

        let removed = try await database.applyDeletions([uuid], stream: stream, anchor: Data([3]))

        XCTAssertEqual(removed, 1)
        let stats = try await database.stats()
        XCTAssertEqual(stats.samples, 0)
    }

    func testWorkoutStoresChildrenAndSurvivesACorrection() async throws {
        let uuid = UUID()
        let workout = makeWorkout(uuid: uuid, lapCount: 4)

        _ = try await database.applyWorkouts([workout], anchor: Data([1]))

        _ = try await database.applyWorkouts([makeWorkout(uuid: uuid, lapCount: 2)], anchor: Data([2]))

        let stats = try await database.stats()
        XCTAssertEqual(stats.workouts, 1)
        let cursor = try await database.cursor(for: .workouts)
        XCTAssertEqual(cursor, Data([2]))
    }

    func testHeartRateKeepsEverySourceWhileDistanceKeepsOne() async throws {
        let workoutUUID = UUID()
        _ = try await database.applyWorkouts(
            [makeWorkout(uuid: workoutUUID, lapCount: 1)], anchor: Data([1])
        )

        let watch = source
        let airPods = SourceRecord(
            bundleID: "com.apple.heartratecoordinatord", name: "Dispositivo Bluetooth"
        )
        let iPhone = SourceRecord(bundleID: "com.apple.health.iphone", name: "iPhone")
        func sample(_ offset: TimeInterval, _ value: Double, from index: Int) -> QuantityRecord {
            QuantityRecord(
                uuid: UUID(), start: start.addingTimeInterval(offset),
                end: start.addingTimeInterval(offset), value: value, sourceIndex: index
            )
        }

        _ = try await database.applyQuantities(
            [
                sample(60, 140, from: 0), sample(120, 142, from: 0), sample(180, 144, from: 0),
                sample(240, 150, from: 1), sample(300, 152, from: 1), sample(360, 154, from: 1),
            ],
            sources: [watch, airPods], metricKey: "heart_rate",
            stream: .quantity("heart_rate"), anchor: Data([1])
        )
        _ = try await database.applyQuantities(
            [
                sample(60, 100, from: 0), sample(120, 100, from: 0), sample(180, 100, from: 0),
                sample(60, 400, from: 1),
            ],
            sources: [watch, iPhone], metricKey: "distance_walking_running",
            stream: .quantity("distance_walking_running"), anchor: Data([1])
        )

        let metrics = try await database.rows(
            "SELECT metric, samples, total, average FROM v_workout_metric"
        )
        let heartRate = try XCTUnwrap(metrics.first { $0["metric"] == .text("heart_rate") })
        XCTAssertEqual(heartRate["samples"]?.double, 6, "la FC tiene sia il Watch sia le AirPods")
        XCTAssertEqual(heartRate["average"]?.double, 147)

        let distance = try XCTUnwrap(
            metrics.first { $0["metric"] == .text("distance_walking_running") }
        )
        XCTAssertEqual(distance["total"]?.double, 300, "la distanza non somma Watch e iPhone")
    }

    func testRoutePointsAreReplacedNotAccumulated() async throws {
        let workoutUUID = UUID()
        _ = try await database.applyWorkouts([makeWorkout(uuid: workoutUUID, lapCount: 1)], anchor: nil)

        let points = (0..<10).map { index in
            RoutePointRecord(
                timestamp: start.addingTimeInterval(Double(index)),
                latitude: 0.0, longitude: 0.0, altitude: 120,
                horizontalAccuracy: 5, verticalAccuracy: 3, speed: 3.3, course: 90
            )
        }
        let route = RouteRecord(workoutUUID: workoutUUID, points: points)

        _ = try await database.applyRoutes([route], anchor: Data([1]))
        _ = try await database.applyRoutes([route], anchor: Data([2]))

        let stats = try await database.stats()
        XCTAssertEqual(stats.routePoints, 10, "rispedire un percorso lo sostituisce")
    }

    private func makeWorkout(uuid: UUID, lapCount: Int) -> WorkoutRecord {
        WorkoutRecord(
            uuid: uuid, activityType: 37, start: start, end: start.addingTimeInterval(3_600),
            duration: 3_600, totalDistance: 12_000, totalEnergy: 750, totalSwimmingStrokes: nil,
            totalFlights: nil, sourceName: "Allenamento", sourceBundleID: "com.apple.workout",
            sourceVersion: "11.6", productType: "Watch7,5", deviceName: "Apple Watch",
            deviceModel: "Watch", deviceHardware: "Watch7,5", deviceSoftware: "11.6",
            timeZone: "Europe/Rome", isIndoor: false, elevationAscended: 120,
            elevationDescended: 118, weatherTemperature: 18, weatherHumidity: 60,
            poolLength: nil, planName: "8×400", metadata: ["chiave": "valore"],
            events: [
                WorkoutEventRecord(
                    type: 1, start: start.addingTimeInterval(600),
                    end: start.addingTimeInterval(620), metadata: [:]
                )
            ],
            activities: (0..<lapCount).map { index in
                WorkoutActivityRecord(
                    uuid: UUID(),
                    start: start.addingTimeInterval(Double(index) * 300),
                    end: start.addingTimeInterval(Double(index + 1) * 300),
                    activityType: 37, locationType: 1,
                    metadata: ["HKWorkoutActivityName": "Ripetuta \(index + 1)"],
                    statistics: []
                )
            },
            statistics: [
                WorkoutStatisticRecord(
                    metricKey: "heart_rate", sum: nil, average: 168, minimum: 120, maximum: 182
                )
            ],
            plannedSteps: [
                PlannedStepRecord(
                    index: 0, role: "warmup", name: nil, goalKind: "distance", goalValue: 2_000,
                    alert: nil
                )
            ],
            hasRoute: true
        )
    }
}

func assertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("era attesa un'eccezione", file: file, line: line)
    } catch {

    }
}
