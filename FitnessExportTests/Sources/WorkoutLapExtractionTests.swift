import HealthKit
import WorkoutKit
import XCTest

@testable import FitnessExport

final class WorkoutLapExtractionTests: XCTestCase {
    private typealias Step = WorkoutLapExtraction.Step
    private typealias KeyPath = WorkoutLapExtraction.StepKeyPath

    private let start = Date(timeIntervalSince1970: 1_773_298_500)

    func testKeyPathParsing() {
        XCTAssertEqual(KeyPath("1.7.1"), KeyPath(section: 1, iteration: 7, step: 1))
        XCTAssertEqual(KeyPath("1.0.14"), KeyPath(section: 1, iteration: 0, step: 14))
        XCTAssertNil(KeyPath("1.0"))
        XCTAssertNil(KeyPath("a.b.c"))
        XCTAssertNil(KeyPath("-1.0.0"))
    }

    func testRealExportWithRepeatedBlockIsLabelledExactly() {
        var steps = [
            Step(
                interval: DateInterval(start: start, duration: 1_500),
                keyPath: KeyPath(section: 0, iteration: 0, step: 0), speed: 2.5)
        ]
        var offset: TimeInterval = 1_500
        for iteration in 0..<8 {
            for step in 0..<2 {
                steps.append(
                    Step(
                        interval: DateInterval(start: start.addingTimeInterval(offset), duration: 30),
                        keyPath: KeyPath(section: 1, iteration: iteration, step: step), speed: step == 0 ? 3.5 : 1.8))
                offset += 30
            }
        }
        steps.append(
            Step(
                interval: DateInterval(start: start.addingTimeInterval(offset), duration: 174),
                keyPath: KeyPath(section: 2, iteration: 0, step: 0), speed: 2.6))

        let plan = makePlan(
            warmup: .time(25, .minutes), work: .time(30, .seconds), recovery: .time(30, .seconds), iterations: 8,
            cooldown: .open)
        let laps = WorkoutLapExtraction.laps(for: steps, plan: plan)

        XCTAssertEqual(laps.count, 18)
        XCTAssertEqual(
            laps.map(\.intensity),
            [.warmup] + Array(repeating: [LapIntensity.active, .recovery], count: 8).flatMap { $0 } + [.cooldown])
        XCTAssertEqual(laps[0].goal, .time(1_500))
        XCTAssertEqual(laps[1].goal, .time(30))
        XCTAssertEqual(laps[17].goal, .open)
        XCTAssertEqual(laps[17].interval.end, start.addingTimeInterval(1_500 + 480 + 174))
    }

    func testRealExportWithHandBuiltBlockIsLabelledExactly() {
        var steps = [
            Step(
                interval: DateInterval(start: start, duration: 1_200),
                keyPath: KeyPath(section: 0, iteration: 0, step: 0), speed: 2.6)
        ]
        var offset: TimeInterval = 1_200
        for index in 0..<15 {
            let duration: TimeInterval = index.isMultiple(of: 2) ? 60 : 70
            steps.append(
                Step(
                    interval: DateInterval(start: start.addingTimeInterval(offset), duration: duration),
                    keyPath: KeyPath(section: 1, iteration: 0, step: index), speed: index.isMultiple(of: 2) ? 3.1 : 2.2)
            )
            offset += duration
        }
        steps.append(
            Step(
                interval: DateInterval(start: start.addingTimeInterval(offset), duration: 131),
                keyPath: KeyPath(section: 2, iteration: 0, step: 0), speed: 2.4))

        var blockSteps: [IntervalStep] = []
        for index in 0..<15 {
            blockSteps.append(
                index.isMultiple(of: 2)
                    ? IntervalStep(.work, goal: .time(60, .seconds))
                    : IntervalStep(.recovery, goal: .time(70, .seconds)))
        }
        let plan = CustomWorkout(
            activity: .running,
            location: .outdoor,
            warmup: WorkoutStep(goal: .time(20, .minutes)),
            blocks: [IntervalBlock(steps: blockSteps, iterations: 1)],
            cooldown: WorkoutStep(goal: .open)
        )

        let labels = WorkoutLapExtraction.labels(for: steps, plan: plan)
        let expected: [LapIntensity] =
            [.warmup] + (0..<15).map { $0.isMultiple(of: 2) ? .active : .recovery } + [.cooldown]
        XCTAssertEqual(labels.map(\.intensity), expected)
    }

    func testKeyPathOutsideThePlanFallsBackToPositionalOrder() {

        let steps = [
            Step(
                interval: DateInterval(start: start, duration: 300), keyPath: KeyPath(section: 0, iteration: 0, step: 0)
            ),
            Step(
                interval: DateInterval(start: start.addingTimeInterval(300), duration: 95),
                keyPath: KeyPath(section: 1, iteration: 0, step: 0)),
            Step(
                interval: DateInterval(start: start.addingTimeInterval(395), duration: 90),
                keyPath: KeyPath(section: 1, iteration: 0, step: 1)),
            Step(
                interval: DateInterval(start: start.addingTimeInterval(485), duration: 96),
                keyPath: KeyPath(section: 1, iteration: 0, step: 2)),
            Step(
                interval: DateInterval(start: start.addingTimeInterval(581), duration: 90),
                keyPath: KeyPath(section: 1, iteration: 0, step: 3)),
        ]
        let labels = WorkoutLapExtraction.labels(for: steps, plan: makePlan())
        XCTAssertEqual(labels.map(\.intensity), [.warmup, .active, .recovery, .active, .recovery])
    }

    func testPositionalLabelsFollowThePlan() {
        let steps = makeSteps(durations: [300, 95, 90, 96, 90, 94, 90, 240])
        let laps = WorkoutLapExtraction.laps(for: steps, plan: makePlan())

        XCTAssertEqual(
            laps.map(\.intensity), [.warmup, .active, .recovery, .active, .recovery, .active, .recovery, .cooldown])
        XCTAssertEqual(
            laps.map(\.goal),
            [.time(300), .distance(400), .time(90), .distance(400), .time(90), .distance(400), .time(90), .open])
        XCTAssertEqual(laps[1].interval, DateInterval(start: start.addingTimeInterval(300), duration: 95))
    }

    func testWorkoutEndedEarlyLabelsOnlyTheRecordedSteps() {

        let labels = WorkoutLapExtraction.labels(for: makeSteps(durations: [300, 95, 90, 35]), plan: makePlan())
        XCTAssertEqual(labels.map(\.intensity), [.warmup, .active, .recovery, .active])
    }

    func testTimeStepWithUnexpectedDurationDisablesPositionalLabels() {

        let labels = WorkoutLapExtraction.labels(
            for: makeSteps(durations: [95, 90, 96, 90, 94, 90, 240]), plan: makePlan())
        XCTAssertEqual(labels.map(\.intensity), Array(repeating: .active, count: 7))
    }

    func testTimeStepToleratesSmallOvershoot() {
        let labels = WorkoutLapExtraction.labels(for: makeSteps(durations: [302, 95, 91, 30]), plan: makePlan())
        XCTAssertEqual(labels.map(\.intensity), [.warmup, .active, .recovery, .active])
    }

    func testMoreActivitiesThanPlannedStepsDisablesPositionalLabels() {
        let labels = WorkoutLapExtraction.labels(
            for: makeSteps(durations: Array(repeating: 60, count: 9)), plan: makePlan())
        XCTAssertEqual(labels.map(\.intensity), Array(repeating: .active, count: 9))
    }

    func testWithoutPlanPaceSeparatesWorkFromRecovery() {

        var steps = [
            Step(
                interval: DateInterval(start: start, duration: 600),
                keyPath: KeyPath(section: 0, iteration: 0, step: 0), speed: 3.0)
        ]
        var offset: TimeInterval = 600
        for iteration in 0..<4 {
            steps.append(
                Step(
                    interval: DateInterval(start: start.addingTimeInterval(offset), duration: 96),
                    keyPath: KeyPath(section: 1, iteration: iteration, step: 0), speed: 4.17))
            offset += 96
            steps.append(
                Step(
                    interval: DateInterval(start: start.addingTimeInterval(offset), duration: 120),
                    keyPath: KeyPath(section: 1, iteration: iteration, step: 1), speed: 2.78))
            offset += 120
        }
        steps.append(
            Step(
                interval: DateInterval(start: start.addingTimeInterval(offset), duration: 300),
                keyPath: KeyPath(section: 2, iteration: 0, step: 0), speed: 2.9))

        let labels = WorkoutLapExtraction.labels(for: steps, plan: nil)
        XCTAssertEqual(
            labels.map(\.intensity),
            [.warmup, .active, .recovery, .active, .recovery, .active, .recovery, .active, .recovery, .cooldown])
        XCTAssertTrue(labels.allSatisfy { $0.goal == nil })
    }

    func testWithoutPlanUniformPaceStaysActive() {

        let steps = (0..<5).map { index in
            Step(
                interval: DateInterval(start: start.addingTimeInterval(Double(index) * 240), duration: 240),
                keyPath: KeyPath(section: 0, iteration: index, step: 0), speed: 4.1 + Double(index % 2) * 0.1)
        }
        XCTAssertEqual(
            WorkoutLapExtraction.labels(for: steps, plan: nil).map(\.intensity), Array(repeating: .active, count: 5))
    }

    func testWithoutPlanStandingRecoveryCountsAsRecovery() {
        let steps = [
            Step(
                interval: DateInterval(start: start, duration: 60), keyPath: KeyPath(section: 0, iteration: 0, step: 0),
                speed: 4.0),
            Step(
                interval: DateInterval(start: start.addingTimeInterval(60), duration: 60),
                keyPath: KeyPath(section: 0, iteration: 0, step: 1), speed: 0),
            Step(
                interval: DateInterval(start: start.addingTimeInterval(120), duration: 60),
                keyPath: KeyPath(section: 0, iteration: 1, step: 0), speed: 4.1),
            Step(
                interval: DateInterval(start: start.addingTimeInterval(180), duration: 60),
                keyPath: KeyPath(section: 0, iteration: 1, step: 1), speed: 0),
        ]
        XCTAssertEqual(
            WorkoutLapExtraction.labels(for: steps, plan: nil).map(\.intensity),
            [.active, .recovery, .active, .recovery])
    }

    func testWithoutPlanTwoSingleStepSectionsAreNotWarmupAndCooldown() {
        let steps = [
            Step(
                interval: DateInterval(start: start, duration: 600),
                keyPath: KeyPath(section: 0, iteration: 0, step: 0), speed: 3.0),
            Step(
                interval: DateInterval(start: start.addingTimeInterval(600), duration: 600),
                keyPath: KeyPath(section: 1, iteration: 0, step: 0), speed: 3.5),
        ]
        XCTAssertEqual(WorkoutLapExtraction.labels(for: steps, plan: nil).map(\.intensity), [.active, .active])
    }

    func testWithoutKeyPathsOnlyTransitionsAreLabelled() {
        let steps = [
            Step(interval: DateInterval(start: start, duration: 600)),
            Step(interval: DateInterval(start: start.addingTimeInterval(600), duration: 60), isTransition: true),
            Step(interval: DateInterval(start: start.addingTimeInterval(660), duration: 1_200)),
        ]
        XCTAssertEqual(WorkoutLapExtraction.labels(for: steps, plan: nil).map(\.intensity), [.active, .rest, .active])
    }

    func testRecoveryThresholdRequiresAClearGap() {
        XCTAssertEqual(WorkoutLapExtraction.recoveryThreshold([4.0, 2.0, 4.1, 2.1]), 3.05)
        XCTAssertNil(WorkoutLapExtraction.recoveryThreshold([4.0, 4.1, 3.9]))
        XCTAssertNil(WorkoutLapExtraction.recoveryThreshold([4.0]))
        XCTAssertNil(WorkoutLapExtraction.recoveryThreshold([0, 0]))
    }

    func testStepIsBuiltFromActivityMetadata() throws {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .running
        let activity = HKWorkoutActivity(
            workoutConfiguration: configuration,
            start: start,
            end: start.addingTimeInterval(60),
            metadata: [WorkoutLapExtraction.stepKeyPathMetadataKey: "1.3.0"]
        )
        let step = try XCTUnwrap(Step(activity: activity))
        XCTAssertEqual(step.keyPath, KeyPath(section: 1, iteration: 3, step: 0))
        XCTAssertEqual(step.interval, DateInterval(start: start, duration: 60))
        XCTAssertFalse(step.isTransition)

        let open = HKWorkoutActivity(workoutConfiguration: configuration, start: start, end: nil, metadata: nil)
        XCTAssertNil(Step(activity: open), "un'attività ancora aperta non è un lap")
    }

    func testSingleActivityMeansNoLaps() {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .running
        let activity = HKWorkoutActivity(
            workoutConfiguration: configuration, start: start, end: start.addingTimeInterval(1_800), metadata: nil)
        XCTAssertTrue(
            WorkoutLapExtraction.laps(activities: [activity], plan: nil, events: []).isEmpty,
            "un allenamento libero ha una sola attività che copre tutto: nessun lap")
    }

    func testManualSegmentsSkipAutomaticSplits() {
        let events = [
            makeSegment(
                offset: 0, duration: 300,
                metadata: ["_HKPrivateMetadataSplitMeasuringSystem": "1", "_HKPrivateMetadataIsPartialSplit": "0"]),
            makeSegment(
                offset: 0, duration: 480,
                metadata: ["_HKPrivateMetadataSplitMeasuringSystem": "2", "_HKPrivateMetadataIsPartialSplit": "0"]),
            makeSegment(offset: 120, duration: 200, metadata: nil),
            makeSegment(offset: 0, duration: 120, metadata: nil),
            HKWorkoutEvent(
                type: .pause, dateInterval: DateInterval(start: start.addingTimeInterval(50), duration: 0),
                metadata: nil),
        ]
        let laps = WorkoutLapExtraction.laps(activities: [], plan: nil, events: events)
        XCTAssertEqual(
            laps.map(\.interval),
            [
                DateInterval(start: start, duration: 120),
                DateInterval(start: start.addingTimeInterval(120), duration: 200),
            ])
        XCTAssertEqual(laps.map(\.intensity), [.active, .active])
    }

    func testOverlappingSegmentsAreDiscarded() {

        let events = [
            makeSegment(offset: 0, duration: 300, metadata: nil), makeSegment(offset: 0, duration: 480, metadata: nil),
        ]
        XCTAssertTrue(WorkoutLapExtraction.manualSegments(from: events).isEmpty)
    }

    func testLapEventsTakePrecedenceOverSegments() {
        let events = [
            HKWorkoutEvent(type: .lap, dateInterval: DateInterval(start: start, duration: 100), metadata: nil),
            makeSegment(offset: 0, duration: 250, metadata: nil),
        ]
        let laps = WorkoutLapExtraction.laps(activities: [], plan: nil, events: events)
        XCTAssertEqual(laps.map(\.interval), [DateInterval(start: start, duration: 100)])
    }

    private func makePlan(
        warmup: WorkoutGoal = .time(5, .minutes),
        work: WorkoutGoal = .distance(400, .meters),
        recovery: WorkoutGoal = .time(90, .seconds),
        iterations: Int = 3,
        cooldown: WorkoutGoal = .open
    ) -> CustomWorkout {
        CustomWorkout(
            activity: .running,
            location: .outdoor,
            warmup: WorkoutStep(goal: warmup),
            blocks: [
                IntervalBlock(
                    steps: [IntervalStep(.work, goal: work), IntervalStep(.recovery, goal: recovery)],
                    iterations: iterations)
            ],
            cooldown: WorkoutStep(goal: cooldown)
        )
    }

    private func makeSteps(durations: [TimeInterval]) -> [Step] {
        var offset: TimeInterval = 0
        return durations.map { duration in
            defer { offset += duration }
            return Step(interval: DateInterval(start: start.addingTimeInterval(offset), duration: duration))
        }
    }

    private func makeSegment(offset: TimeInterval, duration: TimeInterval, metadata: [String: Any]?) -> HKWorkoutEvent {
        HKWorkoutEvent(
            type: .segment, dateInterval: DateInterval(start: start.addingTimeInterval(offset), duration: duration),
            metadata: metadata)
    }
}
