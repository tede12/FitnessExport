import CoreFoundation
import FitnessSyncKit
import Foundation

/// Forecasts matching weekdays with recency-weighted medians.
/// Expected volume is run probability multiplied by distance.
enum WeekZonesBuilder {

    struct Run: Equatable {
        let day: String
        let kilometres: Double

        let zoneSamples: [Int]
        let planName: String?

        var zoneKilometres: [Double] {
            let total = zoneSamples.reduce(0, +)
            guard total > 0 else { return Array(repeating: 0, count: 5) }
            return zoneSamples.map { kilometres * Double($0) / Double(total) }
        }
    }

    struct Zones: Equatable {

        let floors: [Int]
        let source: String
    }

    static let historyWeeks = 8
    static let halfLifeWeeks = 3.0
    static let defaultEasyShare = 0.8

    static let trendGrowth = 1.10

    static func build(
        from database: HealthDatabase, now: Date = Date()
    ) async throws -> WeekZones? {
        let directory = database.url.deletingLastPathComponent()
        let zones: Zones
        if let athlete = loadZones(from: directory) {
            zones = athlete
        } else {
            let row = try await database.rows(maxHeartRateSQL).first
            guard let maximum = row?["bpm"]?.double, maximum > 0 else { return nil }
            zones = Zones(
                floors: [0.6, 0.7, 0.8, 0.9].map { Int(($0 * maximum).rounded()) },
                source: "observed max"
            )
        }
        let rows = try await database.rows(runsSQL(floors: zones.floors))
        let runs = rows.map { row in
            Run(
                day: row["day"]?.string ?? "",
                kilometres: row["km"]?.double ?? 0,
                zoneSamples: (1...5).map { row["z\($0)"]?.int ?? 0 },
                planName: row["plan_name"]?.string
            )
        }
        return make(
            runs: runs, zones: zones, athleteTarget: loadTarget(from: directory), now: now
        )
    }

    static func loadZones(from directory: URL) -> Zones? {
        let profileURL = directory.appendingPathComponent("personal-context.json")
        if let data = try? Data(contentsOf: profileURL),
            let profile = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let zones = profile["zones"] as? [String: Any]
        {
            return validatedZones(zones)
        }
        let url = directory.appendingPathComponent("heart-rate-zones.json")
        guard let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return validatedZones(object)
    }

    private static func validatedZones(_ object: [String: Any]) -> Zones? {
        let numbers = ["Z2", "Z3", "Z4", "Z5"].compactMap { object[$0] as? NSNumber }
        guard numbers.count == 4,
            numbers.allSatisfy({
                CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue == Double($0.intValue)
                    && (30...250).contains($0.intValue)
            })
        else { return nil }
        let floors = numbers.map(\.intValue)
        guard Set(floors).count == 4, floors == floors.sorted() else { return nil }
        return Zones(floors: floors, source: "athlete")
    }

    static func loadTarget(from directory: URL) -> WeekTarget? {
        let url = directory.appendingPathComponent("weekly-target.json")
        guard let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let kilometres = (object["kilometres"] as? NSNumber)?.doubleValue, kilometres > 0
        else { return nil }
        let share = (object["easy_share"] as? NSNumber)?.doubleValue ?? defaultEasyShare
        return WeekTarget(
            kilometres: kilometres, easyShare: min(max(share, 0), 1), source: "athlete"
        )
    }

    static func runsSQL(floors: [Int]) -> String {
        let f = floors.map(String.init)
        return """
            WITH runs AS (
              SELECT w.uuid, date(v.start_local) AS day, v.distance_m, v.plan_name,
                     w.start_ms, w.end_ms
              FROM v_workout v JOIN workout w ON w.uuid = v.uuid
              WHERE v.activity = 'running' AND v.distance_m > 0
                AND date(v.start_local) >= date('now','localtime','weekday 0','-6 days',
                                                 '-\(historyWeeks * 7) days')
            )
            SELECT r.day, ROUND(r.distance_m/1000.0, 3) AS km, r.plan_name,
                   SUM(s.value <  \(f[0])) AS z1,
                   SUM(s.value >= \(f[0]) AND s.value < \(f[1])) AS z2,
                   SUM(s.value >= \(f[1]) AND s.value < \(f[2])) AS z3,
                   SUM(s.value >= \(f[2]) AND s.value < \(f[3])) AS z4,
                   SUM(s.value >= \(f[3])) AS z5
            FROM runs r
            LEFT JOIN sample s
              ON s.metric_id = (SELECT id FROM metric WHERE key = 'heart_rate')
             AND s.start_ms >= r.start_ms AND s.start_ms < r.end_ms
            GROUP BY r.uuid
            ORDER BY r.day
            """
    }

    static let maxHeartRateSQL = """
        SELECT MAX(value) AS bpm FROM v_sample
        WHERE metric = 'heart_rate'
          AND start_epoch > CAST(strftime('%s','now','-365 days') AS INTEGER)
        """

    static func make(
        runs: [Run], zones: Zones, athleteTarget: WeekTarget?, now: Date
    ) -> WeekZones? {
        guard !runs.isEmpty else { return nil }
        let calendar = isoCalendar
        let format = PlanItem.dayFormatter
        let today = calendar.startOfDay(for: now)
        guard let monday = calendar.dateInterval(of: .weekOfYear, for: today)?.start
        else { return nil }
        let mondayKey = format.string(from: monday)
        let todayKey = format.string(from: today)

        let thisWeek = runs.filter { $0.day >= mondayKey }
        let history = runs.filter { $0.day < mondayKey }

        var done = Array(repeating: 0.0, count: 5)
        var unzoned = 0.0
        for run in thisWeek {
            if run.zoneSamples.reduce(0, +) == 0 {
                unzoned += run.kilometres
            } else {
                done = zip(done, run.zoneKilometres).map(+)
            }
        }

        let ranToday = thisWeek.contains { $0.day == todayKey }
        let remaining = (0..<7).compactMap { offset -> Date? in
            calendar.date(byAdding: .day, value: offset, to: monday)
        }.filter { $0 > today || ($0 == today && !ranToday) }

        let weeks = observedWeeks(history: history, monday: monday, calendar: calendar)
        let forecast = remaining.map { day in
            forecastDay(day, history: history, weeks: weeks, calendar: calendar)
        }

        let target =
            athleteTarget
            ?? trendTarget(history: history, monday: monday, calendar: calendar)

        return WeekZones(
            weekStart: mondayKey, zoneFloors: zones.floors, zonesSource: zones.source,
            target: target, done: done, unzoned: unzoned, forecast: forecast
        )
    }

    static func observedWeeks(history: [Run], monday: Date, calendar: Calendar) -> [Date] {
        guard let first = history.map(\.day).min(),
            let firstDate = PlanItem.dayFormatter.date(from: first),
            let firstMonday = calendar.dateInterval(of: .weekOfYear, for: firstDate)?.start
        else { return [] }
        return (1...historyWeeks).compactMap { back in
            calendar.date(byAdding: .weekOfYear, value: -back, to: monday)
        }.filter { $0 >= firstMonday }.reversed()
    }

    static func forecastDay(
        _ day: Date, history: [Run], weeks: [Date], calendar: Calendar
    ) -> DayForecast {
        let format = PlanItem.dayFormatter
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? day
        let offset = calendar.dateComponents([.day], from: weekStart, to: day).day ?? 0

        var weightTotal = 0.0
        var weightRan = 0.0
        var samples: [(km: Double, weight: Double)] = []
        var zoneKilometres = Array(repeating: 0.0, count: 5)
        var names: [String: Double] = [:]
        var weeksWithRun = 0

        for (index, weekStart) in weeks.enumerated() {
            let age = Double(weeks.count - 1 - index)
            let weight = pow(0.5, age / halfLifeWeeks)
            weightTotal += weight
            guard let sameDay = calendar.date(byAdding: .day, value: offset, to: weekStart)
            else { continue }
            let key = format.string(from: sameDay)
            let runs = history.filter { $0.day == key }
            guard !runs.isEmpty else { continue }
            weeksWithRun += 1
            weightRan += weight
            samples.append((runs.reduce(0) { $0 + $1.kilometres }, weight))
            for run in runs {
                zoneKilometres = zip(zoneKilometres, run.zoneKilometres.map { $0 * weight })
                    .map(+)
                if let name = run.planName { names[name, default: 0] += weight }
            }
        }

        let zoneTotal = zoneKilometres.reduce(0, +)
        return DayForecast(
            day: format.string(from: day),
            probability: weightTotal > 0 ? weightRan / weightTotal : 0,
            kilometres: weightedMedian(samples),
            zoneShare: zoneTotal > 0 ? zoneKilometres.map { $0 / zoneTotal } : zoneKilometres,
            weeksWithRun: weeksWithRun,
            weeksObserved: weeks.count,
            usualPlanName: names.max { $0.value < $1.value }?.key
        )
    }

    static func trendTarget(history: [Run], monday: Date, calendar: Calendar) -> WeekTarget {
        let format = PlanItem.dayFormatter
        let since = calendar.date(byAdding: .weekOfYear, value: -4, to: monday) ?? monday
        let sinceKey = format.string(from: since)
        let total = history.filter { $0.day >= sinceKey }.reduce(0) { $0 + $1.kilometres }
        return WeekTarget(
            kilometres: (total / 4 * trendGrowth).rounded(),
            easyShare: defaultEasyShare,
            source: "trend"
        )
    }

    static func weightedMedian(_ samples: [(km: Double, weight: Double)]) -> Double {
        let sorted = samples.sorted { $0.km < $1.km }
        let half = sorted.reduce(0) { $0 + $1.weight } / 2
        var running = 0.0
        for sample in sorted {
            running += sample.weight
            if running >= half { return sample.km }
        }
        return 0
    }

    static var isoCalendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        return calendar
    }
}
