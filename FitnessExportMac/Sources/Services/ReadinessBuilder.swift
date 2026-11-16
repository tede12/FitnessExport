import FitnessSyncKit
import Foundation

/// Scores recovery against personal baselines and renormalizes available input weights.
enum ReadinessBuilder {

    struct Day: Equatable {
        var hrv: Double?
        var resting: Double?

        var sleep: Double?

        var nap: Double?
        var load: Double = 0
    }

    static let baselineDays = 60
    static let minimumBaseline = 14
    static let historyDays = 60
    static let weights: [String: Double] = ["hrv": 0.35, "resting": 0.20, "sleep": 0.25, "load": 0.20]

    static func build(from database: HealthDatabase, now: Date = Date()) async throws -> Readiness? {
        let maximum = try await database.rows(WeekZonesBuilder.maxHeartRateSQL).first?["bpm"]?
            .double
        async let recovery = database.rows(recoverySQL)
        async let nights = database.rows(nightsSQL)
        async let load = database.rows(loadSQL(maximum: maximum))

        var days: [String: Day] = [:]
        for row in try await recovery {
            guard let key = row["day"]?.string else { continue }
            days[key, default: Day()].hrv = row["hrv"]?.double
            days[key, default: Day()].resting = row["rhr"]?.double
        }
        for row in try await nights {
            guard let key = row["wake_day"]?.string else { continue }
            days[key, default: Day()].sleep = row["hours"]?.double
            days[key, default: Day()].nap = row["nap_hours"]?.double
        }
        for row in try await load {
            guard let key = row["day"]?.string else { continue }
            days[key, default: Day()].load = row["load"]?.double ?? 0
        }
        let rests = (try? await RestDetector.build(from: database)) ?? [:]
        return make(days: days, rests: rests, now: now)
    }

    private static let span = baselineDays + historyDays + 1

    static let recoverySQL = """
        SELECT date(start_local) AS day,
               AVG(CASE WHEN metric='hrv_sdnn' THEN value END) AS hrv,
               AVG(CASE WHEN metric='resting_heart_rate' THEN value END) AS rhr
        FROM v_sample
        WHERE metric IN ('hrv_sdnn','resting_heart_rate')
          AND start_epoch > CAST(strftime('%s','now','-\(span) days') AS INTEGER)
        GROUP BY day
        """

    static let nightsSQL = """
        SELECT date(start_local, '-12 hours', '+1 day') AS wake_day,
               SUM(duration_s)/3600.0 AS hours,
               SUM(CASE WHEN CAST(strftime('%H', start_local) AS INT) BETWEEN 12 AND 17
                        THEN duration_s END)/3600.0 AS nap_hours
        FROM v_category
        WHERE metric = 'sleep_analysis' AND value IN (1,3,4,5)
          AND start_epoch > CAST(strftime('%s','now','-\(span) days') AS INTEGER)
        GROUP BY wake_day
        """

    static func loadSQL(maximum: Double?) -> String {
        let divisor = maximum.map { String($0) } ?? "NULL"
        return """
            SELECT date(w.start_ms/1000, 'unixepoch', 'localtime') AS day,
                   SUM(w.duration_s/60.0 * COALESCE((
                       SELECT (AVG(s.value) / \(divisor)) * (AVG(s.value) / \(divisor)) * 2.2
                       FROM sample s
                       WHERE s.metric_id = (SELECT id FROM metric WHERE key = 'heart_rate')
                         AND s.start_ms >= w.start_ms AND s.start_ms < w.end_ms
                   ), 1.0)) AS load
            FROM workout w
            WHERE w.start_ms > CAST(strftime('%s','now','-\(span) days') AS INTEGER) * 1000
            GROUP BY day
            """
    }

    static func make(
        days: [String: Day], rests: [String: [RestEpisode]] = [:], now: Date
    ) -> Readiness? {
        let calendar = WeekZonesBuilder.isoCalendar
        let today = calendar.startOfDay(for: now)
        let history: [(String, [ReadinessComponent])] = (0..<historyDays).reversed().compactMap {
            back in
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else {
                return nil
            }
            return (key(day), components(for: day, days: days, calendar: calendar))
        }
        let points = history.compactMap { day, parts in
            score(parts).map {
                ReadinessPoint(
                    day: day, score: $0, components: parts, restEpisodes: rests[day] ?? []
                )
            }
        }

        guard let latest = history.suffix(2).last(where: { score($0.1) != nil }),
            let latestScore = score(latest.1)
        else { return nil }
        return Readiness(day: latest.0, score: latestScore, components: latest.1, history: points)
    }

    static func components(for day: Date, days: [String: Day], calendar: Calendar) -> [ReadinessComponent] {
        let current = days[key(day)] ?? Day()
        let prior: [Day] = (1...baselineDays).compactMap { back in
            calendar.date(byAdding: .day, value: -back, to: day).map { days[key($0)] ?? Day() }
        }
        var parts: [ReadinessComponent] = []

        if let hrv = current.hrv, hrv > 0 {
            let logs = prior.compactMap(\.hrv).filter { $0 > 0 }.map(log)
            if let (mean, sd) = spread(logs) {
                let z = (log(hrv) - mean) / sd
                parts.append(
                    part("hrv", hrv, "ms", exp(mean - sd), exp(mean + sd), 7.5 + 2.5 * z)
                )
            }
        }
        if let resting = current.resting {
            if let (mean, sd) = spread(prior.compactMap(\.resting)) {
                let z = (mean - resting) / sd
                parts.append(part("resting", resting, "bpm", mean - sd, mean + sd, 7.5 + 2.5 * z))
            }
        }
        if let sleep = current.sleep {
            let hours = prior.compactMap(\.sleep)
            let (mean, sd) = spread(hours) ?? (sleep, 0)
            parts.append(
                part(
                    "sleep", sleep, "h", mean - sd, mean + sd, (sleep - 4.5) / 3.5 * 10,
                    nap: current.nap.flatMap { $0 > 0 ? $0 : nil }
                )
            )
        }

        let acute = prior.prefix(7).reduce(0) { $0 + $1.load } / 7
        let chronic = prior.prefix(42).reduce(0) { $0 + $1.load } / 42
        if chronic > 0 {
            let ratio = acute / chronic
            parts.append(part("load", ratio, "×", 0.8, 1.3, loadSubscore(ratio)))
        }

        let total = parts.reduce(0) { $0 + (weights[$1.key] ?? 0) }
        return parts.map { part in
            ReadinessComponent(
                key: part.key, value: part.value, unit: part.unit, normalLow: part.normalLow,
                normalHigh: part.normalHigh, subscore: part.subscore,
                weight: (weights[part.key] ?? 0) / total, napHours: part.napHours
            )
        }
    }

    static func score(_ parts: [ReadinessComponent]) -> Double? {
        guard parts.contains(where: { $0.key == "hrv" || $0.key == "resting" }) else { return nil }
        let value = parts.reduce(0) { $0 + $1.subscore * $1.weight }
        return (value * 10).rounded() / 10
    }

    static func loadSubscore(_ ratio: Double) -> Double {
        if ratio <= 1.0 { return 10 }
        if ratio <= 1.3 { return 10 - (ratio - 1.0) / 0.3 * 2.5 }
        return clamp(7.5 - (ratio - 1.3) / 0.4 * 7.5)
    }

    static func spread(_ values: [Double]) -> (Double, Double)? {
        guard values.count >= minimumBaseline else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
        return (mean, max(variance.squareRoot(), abs(mean) * 0.02, 1e-6))
    }

    private static func part(
        _ key: String, _ value: Double, _ unit: String, _ low: Double, _ high: Double,
        _ subscore: Double, nap: Double? = nil
    ) -> ReadinessComponent {
        ReadinessComponent(
            key: key, value: value, unit: unit, normalLow: low, normalHigh: high,
            subscore: clamp(subscore), weight: 0, napHours: nap
        )
    }

    static func clamp(_ value: Double) -> Double { min(max(value, 0), 10) }

    private static func key(_ date: Date) -> String { PlanItem.dayFormatter.string(from: date) }
}
