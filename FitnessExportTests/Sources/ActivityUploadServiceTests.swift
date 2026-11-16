import Foundation
import XCTest

@testable import FitnessExport

@MainActor
final class ActivityUploadServiceTests: ItalianLocalizationTestCase {

    final class FakePlatform: @unchecked Sendable {
        var existing: Set<String> = []
        var calls: [String] = []

        var uploadOutcomes: [ActivityUploadService.Outcome] = [.uploaded(activityID: "new")]

        var client: ActivityUploadService.PlatformClient {
            ActivityUploadService.PlatformClient(
                upload: { _, _ in
                    self.calls.append("upload")
                    let outcome = self.uploadOutcomes.first ?? .uploaded(activityID: "new")
                    if self.uploadOutcomes.count > 1 { self.uploadOutcomes.removeFirst() }
                    return outcome
                },
                exists: { id in
                    self.calls.append("exists:\(id)")
                    return self.existing.contains(id)
                },
                delete: { id in
                    self.calls.append("delete:\(id)")
                    self.existing.remove(id)
                },
                find: { _, _ in
                    self.calls.append("find")
                    return self.existing.first
                }
            )
        }
    }

    private var ledgerURL: URL!
    private var repository: MockWorkoutRepository!
    private var workout: WorkoutListItem!

    override func setUp() async throws {
        ledgerURL = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString).json")
        repository = MockWorkoutRepository(scenario: .preview)
        let index = await repository.loadIndex()
        workout = try XCTUnwrap(index.items.first)
    }

    private func makeService() -> (ActivityUploadService, UploadLedger) {
        let ledger = UploadLedger(fileURL: ledgerURL)
        var service = ActivityUploadService(exportService: FITExportService(repository: repository), ledger: ledger)
        service.replaceRetryDelay = 0
        return (service, ledger)
    }

    private func runJob(_ service: ActivityUploadService, mode: ActivityUploadService.Mode, platform: FakePlatform)
        async -> UploadJob
    {
        let job = UploadJob(platform: .garmin, workouts: [workout])
        await service.run(job, workoutIDs: [workout.id], mode: mode, client: platform.client)
        return job
    }

    func testSkipsOnlyIfRemoteCopyStillExists() async throws {
        let (service, ledger) = makeService()
        try await ledger.record(workoutID: workout.id, platform: .garmin, remoteID: "42")
        let platform = FakePlatform()
        platform.existing = ["42"]

        let job = await runJob(service, mode: .skipUploaded, platform: platform)

        XCTAssertEqual(job.items[0].state, .skipped)
        XCTAssertEqual(platform.calls, ["exists:42"])
    }

    func testReuploadsWhenRemoteCopyWasDeletedFromSite() async throws {
        let (service, ledger) = makeService()
        try await ledger.record(workoutID: workout.id, platform: .garmin, remoteID: "42")
        let platform = FakePlatform()
        platform.existing = []

        let job = await runJob(service, mode: .skipUploaded, platform: platform)

        XCTAssertEqual(job.items[0].state, .uploaded(activityID: "new"))
        XCTAssertEqual(platform.calls, ["exists:42", "upload"])
        let record = await ledger.all()[workout.id]?[.garmin]
        XCTAssertEqual(record?.remoteID, "new")
    }

    func testReplaceRetriesWhileServerStillReportsDuplicate() async throws {
        let (service, ledger) = makeService()
        try await ledger.record(workoutID: workout.id, platform: .garmin, remoteID: "42")
        let platform = FakePlatform()
        platform.existing = ["42"]
        platform.uploadOutcomes = [
            .duplicate(activityID: "42", message: "Duplicate Activity"), .uploaded(activityID: "43"),
        ]

        let job = await runJob(service, mode: .replaceUploaded, platform: platform)

        XCTAssertEqual(job.items[0].state, .replaced(activityID: "43"))
        XCTAssertEqual(platform.calls, ["delete:42", "upload", "upload"])
        let record = await ledger.all()[workout.id]?[.garmin]
        XCTAssertEqual(record?.remoteID, "43")
    }

    func testReplaceDeletesUnknownDuplicateReportedByServer() async throws {
        let (service, _) = makeService()
        let platform = FakePlatform()
        platform.existing = ["77"]
        platform.uploadOutcomes = [
            .duplicate(activityID: "77", message: "Duplicate Activity"), .uploaded(activityID: "78"),
        ]

        let job = await runJob(service, mode: .replaceUploaded, platform: platform)

        XCTAssertEqual(job.items[0].state, .replaced(activityID: "78"))
        XCTAssertEqual(platform.calls, ["find", "delete:77", "upload", "upload"])
    }

    func testReplaceFailsLoudlyWhenDuplicatePersists() async throws {
        let (service, ledger) = makeService()
        try await ledger.record(workoutID: workout.id, platform: .garmin, remoteID: "42")
        let platform = FakePlatform()
        platform.existing = ["42"]
        platform.uploadOutcomes = [.duplicate(activityID: "42", message: "Duplicate Activity")]

        let job = await runJob(service, mode: .replaceUploaded, platform: platform)

        guard case .failed(let message) = job.items[0].state else {
            return XCTFail("atteso failed, avuto \(job.items[0].state)")
        }
        XCTAssertTrue(message.contains("duplicato"))
        XCTAssertEqual(platform.calls.filter { $0 == "upload" }.count, 1 + ActivityUploadService.replaceRetries)
    }
}
