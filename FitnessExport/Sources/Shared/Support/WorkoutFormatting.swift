import FitnessUI
import Foundation

enum WorkoutFormatting {
    static func monthLabel(_ month: WorkoutMonthKey) -> String {
        month.startDate.formatted(
            .dateTime
                .month(.wide)
                .year()
                .locale(AppLanguage.locale)
        )
    }

    static func workoutDate(_ date: Date) -> String {
        date.formatted(
            .dateTime
                .day()
                .month(.abbreviated)
                .year()
                .hour()
                .minute()
                .locale(AppLanguage.locale)
        )
    }

    static func shortDate(_ date: Date) -> String {
        date.formatted(
            .dateTime
                .day()
                .month(.abbreviated)
                .locale(AppLanguage.locale)
        )
    }

    static func dateRange(start: Date, end: Date) -> String {
        "\(shortDate(start)) - \(shortDate(end))"
    }

    static func monthSelectionLabel(_ months: Set<WorkoutMonthKey>) -> String {
        let ordered = months.sorted(by: >)
        guard let first = ordered.first else { return AppLanguage.text("Nessun mese") }
        if ordered.count == 1 {
            return monthLabel(first)
        }
        if ordered.count == 2 {
            return ordered.map(monthLabel).joined(separator: " + ")
        }
        return AppLanguage.format(
            "%@ + %@ mesi", monthLabel(first), ordered.count - 1)
    }

    static func distance(_ meters: Double?) -> String? {
        guard let meters else { return nil }
        let kilometers = meters / 1_000

        return kilometers >= 100
            ? String(format: "%.1f km", locale: AppLanguage.locale, kilometers)
            : String(format: "%.2f km", locale: AppLanguage.locale, kilometers)
    }

    static func distanceCompact(_ meters: Double?) -> String? {
        guard let meters else { return nil }
        return String(format: "%.1f km", locale: AppLanguage.locale, meters / 1_000)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let remainingSeconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", locale: AppLanguage.locale, hours, minutes, remainingSeconds)
        }

        return String(format: "%02d:%02d", locale: AppLanguage.locale, minutes, remainingSeconds)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let remainingSeconds = totalSeconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", locale: AppLanguage.locale, hours, minutes, remainingSeconds)
            : String(format: "%d:%02d", locale: AppLanguage.locale, minutes, remainingSeconds)
    }

    static func lapDistance(_ meters: Double) -> String {
        meters < 1_000
            ? String(format: "%.0f m", locale: AppLanguage.locale, meters)
            : String(format: "%.2f km", locale: AppLanguage.locale, meters / 1_000)
    }

    static func pace(distanceInMeters: Double?, duration: TimeInterval) -> String? {
        guard let distanceInMeters, distanceInMeters > 0 else { return nil }
        return pace(secondsPerKilometer: duration / (distanceInMeters / 1_000))
    }

    static func pace(secondsPerKilometer: Double?) -> String? {
        guard let secondsPerKilometer, secondsPerKilometer.isFinite, secondsPerKilometer > 0 else { return nil }
        let totalSeconds = Int(secondsPerKilometer.rounded())
        return String(format: "%d:%02d/km", locale: AppLanguage.locale, totalSeconds / 60, totalSeconds % 60)
    }

    static func paceShort(secondsPerKilometer: Double?) -> String {
        guard let secondsPerKilometer, secondsPerKilometer.isFinite, secondsPerKilometer > 0 else { return "–" }
        let totalSeconds = Int(secondsPerKilometer.rounded())
        return String(format: "%d:%02d", locale: AppLanguage.locale, totalSeconds / 60, totalSeconds % 60)
    }

    static func axisNumber(_ value: Double) -> String {
        value.rounded() == value
            ? String(format: "%.0f", locale: AppLanguage.locale, value)
            : String(format: "%.1f", locale: AppLanguage.locale, value)
    }

    static func heartRate(_ bpm: Double?) -> String? {
        guard let bpm else { return nil }
        return String(format: "%.0f bpm", locale: AppLanguage.locale, bpm)
    }

    static func cadence(_ spm: Double?) -> String? {
        guard let spm else { return nil }
        return String(format: "%.0f spm", locale: AppLanguage.locale, spm)
    }

    static func kilocalories(_ kcals: Double?) -> String? {
        guard let kcals else { return nil }
        return String(format: "%.0f kcal", locale: AppLanguage.locale, kcals)
    }
}
