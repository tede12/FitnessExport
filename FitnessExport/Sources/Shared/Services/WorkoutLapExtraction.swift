import Foundation
import HealthKit
import WorkoutKit

/// Planned steps are workout activities; automatic kilometre/mile segments overlap.
enum WorkoutLapExtraction {

    static let autoSplitMetadataKeys = ["_HKPrivateMetadataSplitMeasuringSystem", "_HKPrivateMetadataIsPartialSplit"]

    static let stepKeyPathMetadataKey = "WOIntervalStepKeyPath"

    static let timeGoalTolerance: TimeInterval = 3

    static let paceGapRatio = 1.2

    struct StepKeyPath: Equatable {
        let section: Int
        let iteration: Int
        let step: Int

        init(section: Int, iteration: Int, step: Int) {
            self.section = section
            self.iteration = iteration
            self.step = step
        }

        init?(_ value: String) {
            let parts = value.split(separator: ".").map { Int($0) }
            guard parts.count == 3, let section = parts[0], let iteration = parts[1], let step = parts[2],
                section >= 0, iteration >= 0, step >= 0
            else { return nil }
            self.init(section: section, iteration: iteration, step: step)
        }
    }

    struct Step: Equatable {
        let interval: DateInterval

        let duration: TimeInterval
        let keyPath: StepKeyPath?

        let speed: Double?
        let isTransition: Bool

        init(
            interval: DateInterval, duration: TimeInterval? = nil, keyPath: StepKeyPath? = nil, speed: Double? = nil,
            isTransition: Bool = false
        ) {
            self.interval = interval
            self.duration = duration ?? interval.duration
            self.keyPath = keyPath
            self.speed = speed
            self.isTransition = isTransition
        }

        init?(activity: HKWorkoutActivity) {
            guard let end = activity.endDate, end > activity.startDate else { return nil }
            let activityType = activity.workoutConfiguration.activityType
            let meters = HKObjectType.quantityType(forIdentifier: activityType.distanceTypeIdentifier)
                .flatMap { activity.statistics(for: $0)?.sumQuantity()?.doubleValue(for: .meter()) }
            self.init(
                interval: DateInterval(start: activity.startDate, end: end),
                duration: activity.duration,
                keyPath: (activity.metadata?[WorkoutLapExtraction.stepKeyPathMetadataKey] as? String).flatMap(
                    StepKeyPath.init),
                speed: meters.flatMap { activity.duration > 0 ? $0 / activity.duration : nil },
                isTransition: activityType == .transition
            )
        }
    }

    struct Label: Equatable {
        let intensity: LapIntensity
        var name: String? = nil
        var goal: LapGoal? = nil
    }

    static func laps(activities: [HKWorkoutActivity], plan: CustomWorkout?, events: [HKWorkoutEvent]) -> [WorkoutLap] {
        let steps = activities.compactMap(Step.init(activity:)).sorted { $0.interval.start < $1.interval.start }
        if steps.count >= 2 {
            return laps(for: steps, plan: plan)
        }

        let lapEvents = events.filter { $0.type == .lap && $0.dateInterval.duration > 0 }
        if !lapEvents.isEmpty {
            return lapEvents.map { WorkoutLap(interval: $0.dateInterval) }
        }
        return manualSegments(from: events).map { WorkoutLap(interval: $0) }
    }

    static func laps(for steps: [Step], plan: CustomWorkout?) -> [WorkoutLap] {
        zip(steps, labels(for: steps, plan: plan)).map { step, label in
            WorkoutLap(interval: step.interval, intensity: label.intensity, name: label.name, goal: label.goal)
        }
    }

    static func labels(for steps: [Step], plan: CustomWorkout?) -> [Label] {
        if let plan {
            if let exact = plannedLabels(for: steps, plan: plan) { return exact }
            if let positional = positionalLabels(for: steps, plan: plan) { return positional }
        }
        return inferredLabels(for: steps)
    }

    enum PlanSection: Equatable {
        case warmup(WorkoutStep)
        case block(IntervalBlock)
        case cooldown(WorkoutStep)
    }

    static func sections(of plan: CustomWorkout) -> [PlanSection] {
        var sections: [PlanSection] = []
        if let warmup = plan.warmup { sections.append(.warmup(warmup)) }
        sections += plan.blocks.map(PlanSection.block)
        if let cooldown = plan.cooldown { sections.append(.cooldown(cooldown)) }
        return sections
    }

    static func plannedLabels(for steps: [Step], plan: CustomWorkout) -> [Label]? {
        let sections = sections(of: plan)
        var labels: [Label] = []
        for step in steps {
            guard let keyPath = step.keyPath, keyPath.section < sections.count else { return nil }
            switch sections[keyPath.section] {
            case .warmup(let workoutStep):
                labels.append(label(.warmup, for: workoutStep))
            case .cooldown(let workoutStep):
                labels.append(label(.cooldown, for: workoutStep))
            case .block(let block):
                guard keyPath.step < block.steps.count else { return nil }
                let intervalStep = block.steps[keyPath.step]
                labels.append(label(intervalStep.purpose == .work ? .active : .recovery, for: intervalStep.step))
            }
        }
        return labels
    }

    static func plannedLabels(_ plan: CustomWorkout) -> [Label] {
        sections(of: plan).flatMap { section -> [Label] in
            switch section {
            case .warmup(let step): return [label(.warmup, for: step)]
            case .cooldown(let step): return [label(.cooldown, for: step)]
            case .block(let block):
                return (0..<max(block.iterations, 1)).flatMap { _ in
                    block.steps.map { label($0.purpose == .work ? .active : .recovery, for: $0.step) }
                }
            }
        }
    }

    static func positionalLabels(for steps: [Step], plan: CustomWorkout) -> [Label]? {
        let planned = plannedLabels(plan)
        guard steps.count <= planned.count else { return nil }
        for (index, step) in steps.enumerated() where index < steps.count - 1 {
            guard matches(step, goal: planned[index].goal) else { return nil }
        }
        return Array(planned.prefix(steps.count))
    }

    static func matches(_ step: Step, goal: LapGoal?) -> Bool {
        guard case .time(let expected)? = goal else { return true }
        return abs(step.duration - expected) <= timeGoalTolerance
            || abs(step.interval.duration - expected) <= timeGoalTolerance
    }

    private static func label(_ intensity: LapIntensity, for step: WorkoutStep) -> Label {
        var name: String?
        if #available(iOS 18.0, *) {
            name = step.displayName?.trimmingCharacters(in: .whitespaces)
        }
        return Label(intensity: intensity, name: name?.isEmpty == false ? name : nil, goal: lapGoal(step.goal))
    }

    static func lapGoal(_ goal: WorkoutGoal) -> LapGoal {
        switch goal {
        case .open:
            return .open
        case .time(let value, let unit):
            return .time(Measurement(value: value, unit: unit).converted(to: .seconds).value)
        case .distance(let value, let unit):
            return .distance(Measurement(value: value, unit: unit).converted(to: .meters).value)
        default:
            return .open
        }
    }

    static func inferredLabels(for steps: [Step]) -> [Label] {
        var labels = steps.map { Label(intensity: $0.isTransition ? .rest : .active) }
        let keyPaths = steps.compactMap(\.keyPath)
        guard keyPaths.count == steps.count, !steps.isEmpty else { return labels }

        let sections = Array(Set(keyPaths.map(\.section))).sorted()
        let multiStepSections = sections.filter { section in keyPaths.filter { $0.section == section }.count >= 2 }

        for section in multiStepSections {
            let indices = steps.indices.filter { keyPaths[$0].section == section }
            let speeds = indices.compactMap { steps[$0].speed }
            guard speeds.count == indices.count, let threshold = recoveryThreshold(speeds) else { continue }
            for index in indices where steps[index].speed! < threshold {
                labels[index] = Label(intensity: .recovery)
            }
        }

        if let firstMulti = multiStepSections.first, let first = sections.first, first < firstMulti,
            let index = steps.indices.first(where: { keyPaths[$0].section == first }),
            keyPaths.filter({ $0.section == first }).count == 1
        {
            labels[index] = Label(intensity: .warmup)
        }
        if let lastMulti = multiStepSections.last, let last = sections.last, last > lastMulti,
            let index = steps.indices.last(where: { keyPaths[$0].section == last }),
            keyPaths.filter({ $0.section == last }).count == 1
        {
            labels[index] = Label(intensity: .cooldown)
        }
        return labels
    }

    static func recoveryThreshold(_ speeds: [Double]) -> Double? {
        let sorted = speeds.sorted()
        guard sorted.count >= 2 else { return nil }
        var best: (ratio: Double, threshold: Double) = (1, 0)
        for (slow, fast) in zip(sorted, sorted.dropFirst()) where fast > 0 {
            let ratio = slow > 0 ? fast / slow : .infinity
            if ratio > best.ratio { best = (ratio, (slow + fast) / 2) }
        }
        return best.ratio >= paceGapRatio ? best.threshold : nil
    }

    static func manualSegments(from events: [HKWorkoutEvent]) -> [DateInterval] {
        let segments =
            events
            .filter { $0.type == .segment && $0.dateInterval.duration > 0 }
            .filter { event in !autoSplitMetadataKeys.contains { event.metadata?[$0] != nil } }
            .map(\.dateInterval)
            .sorted { $0.start < $1.start }

        var previousEnd = Date.distantPast
        for segment in segments {
            guard segment.start.timeIntervalSince(previousEnd) >= -1 else { return [] }
            previousEnd = segment.end
        }
        return segments
    }
}
