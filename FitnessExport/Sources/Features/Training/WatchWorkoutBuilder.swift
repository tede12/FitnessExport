import FitnessSyncKit
import FitnessUI
import Foundation
import WorkoutKit

enum WatchWorkoutBuilder {

    enum BuildError: LocalizedError {
        case notARunningSession
        case authorizationDenied
        case schedulingFailed(String)

        var errorDescription: String? {
            switch self {
            case .notARunningSession:
                return AppLanguage.text(
                    "Al Watch mandiamo solo le corse: per forza e arrampicata non c'è un obiettivo da controllare.")
            case .authorizationDenied:
                return AppLanguage.text(
                    "Serve il permesso di programmare allenamenti. Lo trovi in Impostazioni ▸ Allenamento.")
            case .schedulingFailed(let reason):
                return AppLanguage.format("Il Watch non ha accettato l'allenamento: %@", reason)
            }
        }
    }

    static func canSend(_ item: PlanItem) -> Bool {
        ["long", "easy", "intervals", "tempo"].contains(item.slot)
    }

    @discardableResult
    static func send(_ item: PlanItem) async throws -> Date {
        guard canSend(item) else { throw BuildError.notARunningSession }

        let authorization = await WorkoutScheduler.shared.requestAuthorization()
        guard authorization == .authorized else { throw BuildError.authorizationDenied }

        let date = scheduleDate(for: item)
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: date
        )
        let plan = WorkoutPlan(.custom(makeWorkout(for: item)))
        await WorkoutScheduler.shared.schedule(plan, at: components)
        return date
    }

    static func scheduleDate(for item: PlanItem, now: Date = Date()) -> Date {
        let calendar = Calendar.current
        let day = item.date ?? now
        let preferredHour = item.slot == "long" ? 9 : 18
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = preferredHour
        components.minute = 0
        let planned = calendar.date(from: components) ?? now

        guard planned <= now else { return planned }

        let soon = now.addingTimeInterval(3_600)
        var rounded = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: soon)
        rounded.minute = ((rounded.minute ?? 0) / 5) * 5
        return calendar.date(from: rounded) ?? soon
    }

    static func makeWorkout(for item: PlanItem) -> CustomWorkout {
        let alert = heartRateAlert(from: item.target)

        let warmup = WorkoutStep(goal: .time(10, .minutes))
        let cooldown = WorkoutStep(goal: .time(5, .minutes))

        var main = WorkoutStep(goal: mainGoal(for: item))
        if let alert { main.alert = alert }

        return CustomWorkout(
            activity: .running,
            location: .outdoor,
            displayName: displayName(for: item),
            warmup: warmup,
            blocks: [IntervalBlock(steps: [IntervalStep(.work, step: main)], iterations: 1)],
            cooldown: cooldown
        )
    }

    static func mainGoal(for item: PlanItem) -> WorkoutGoal {
        if let km = kilometres(from: item.title), km > 0 {
            return .distance(km, .kilometers)
        }
        if let minutes = minutes(from: item.title) ?? minutes(from: item.target), minutes > 0 {
            return .time(minutes, .minutes)
        }
        return .time(item.slot == "long" ? 60 : 35, .minutes)
    }

    static func displayName(for item: PlanItem) -> String {
        let trimmed = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 40 else { return trimmed }
        return String(trimmed.prefix(39)) + "…"
    }

    static func heartRateAlert(from target: String?) -> (any WorkoutAlert)? {
        PlanItem.heartRateRange(in: target).map { .heartRate($0) }
    }

    static func kilometres(from text: String) -> Double? {
        let lowered = text.lowercased().replacingOccurrences(of: ",", with: ".")
        let tokens = lowered.components(separatedBy: CharacterSet(charactersIn: " ·"))
        for (index, token) in tokens.enumerated() {
            if token == "km", index > 0, let value = Double(tokens[index - 1]) {
                return value
            }
            if token.hasSuffix("km"), let value = Double(token.dropLast(2)) {
                return value
            }
        }
        return nil
    }

    static func minutes(from text: String?) -> Double? {
        guard let text else { return nil }
        let lowered = text.lowercased()
        let tokens = lowered.components(separatedBy: CharacterSet(charactersIn: " ·"))
        for (index, token) in tokens.enumerated() {
            if ["min", "minuti", "'", "′"].contains(token), index > 0,
                let value = Double(tokens[index - 1])
            {
                return value
            }
            if token.hasSuffix("′") || token.hasSuffix("'"), let value = Double(token.dropLast()) {
                return value
            }
        }
        return nil
    }
}
