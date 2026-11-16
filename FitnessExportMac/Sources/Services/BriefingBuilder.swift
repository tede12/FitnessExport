import FitnessSyncKit
import Foundation

enum BriefingBuilder {

    static func build(
        from database: HealthDatabase, now: Date = Date()
    ) async throws -> TrainingBriefing {
        async let todayRows = database.rows(TrainingQueries.todaySQL)
        async let planRows = database.rows(TrainingQueries.planSQL)
        async let weekRows = database.rows(TrainingQueries.weekSQL)
        async let volumeRows = database.rows(TrainingQueries.volumeSQL)
        async let recoveryRows = database.rows(TrainingQueries.recoverySQL)
        async let sleepRows = database.rows(TrainingQueries.sleepSQL)
        async let bodyRows = database.rows(TrainingQueries.bodySQL)
        async let formRows = database.rows(TrainingQueries.formSQL)
        async let fitnessRows = database.rows(TrainingQueries.fitnessSQL)
        async let weekZones = WeekZonesBuilder.build(from: database, now: now)
        async let readiness = ReadinessBuilder.build(from: database, now: now)

        return TrainingBriefing(
            generatedAt: Date(),
            today: today(from: try await todayRows.first ?? [:]),
            plan: try await planRows.map(plan(from:)),
            week: try await weekRows.map(session(from:)),
            series: TrendSeries(
                volume: try await volumeRows.map(volume(from:)),
                recovery: try await recoveryRows.map(recovery(from:)),
                sleep: try await sleepRows.compactMap(sleep(from:)),
                body: try await bodyRows.map(body(from:)),
                form: try await formRows.map(form(from:)),
                fitness: try await fitnessRows.map(fitness(from:))
            ),
            weekZones: try await weekZones,
            readiness: try await readiness
        )
    }

    private static func today(from row: [String: SQLValue]) -> TodayStatus {
        var status = TodayStatus()
        status.sleepHours = row["sleep_hours"]?.double
        status.deepMinutes = row["deep_min"]?.double
        status.remMinutes = row["rem_min"]?.double
        status.sleepOnset = row["sleep_onset"]?.string
        status.sleepWake = row["sleep_wake"]?.string
        status.sleepHeartRate = row["sleep_hr"]?.double
        status.sleepHeartRateBaseline = row["sleep_hr_base"]?.double
        status.hrv = row["hrv"]?.double
        status.hrvBaseline = row["hrv_base"]?.double
        status.restingHeartRate = row["rhr"]?.double
        status.restingHeartRateBaseline = row["rhr_base"]?.double
        status.bodyMass = row["mass_kg"]?.double
        status.leanMass = row["lean_kg"]?.double
        status.fatPercent = row["fat_pct"]?.double
        status.massDay = row["mass_day"]?.string
        status.lastActivity = row["last_activity"]?.string
        status.lastMinutes = row["last_minutes"]?.double
        status.lastKilometres = row["last_km"]?.double
        status.lastDaysAgo = row["last_days_ago"]?.int
        status.longRunDaysAgo = row["long_days_ago"]?.int
        status.longRunKilometres = row["long_km"]?.double
        return status
    }

    private static func plan(from row: [String: SQLValue]) -> PlanItem {
        PlanItem(
            day: row["day"]?.string ?? "",
            slot: row["slot"]?.string ?? "other",
            title: row["title"]?.string ?? "",
            detail: row["detail"]?.string,
            target: row["target"]?.string,
            done: row["done"]?.bool ?? false,
            rpe: row["rpe"]?.int,
            note: row["note"]?.string
        )
    }

    private static func session(from row: [String: SQLValue]) -> SessionSummary {
        SessionSummary(
            day: row["day"]?.string ?? "",
            activity: row["activity"]?.string ?? "—",
            minutes: row["minutes"]?.double ?? 0,
            kilometres: row["km"]?.double,
            pace: row["pace"]?.string,
            planName: row["plan_name"]?.string,
            heartRate: row["avg_hr"]?.double
        )
    }

    private static func volume(from row: [String: SQLValue]) -> WeekVolume {
        WeekVolume(
            week: row["week"]?.string ?? "",
            kilometres: row["km"]?.double,
            runs: row["runs"]?.int ?? 0,
            strength: row["strength"]?.int ?? 0,
            climbing: row["climbing"]?.int ?? 0,
            hours: row["hours"]?.double
        )
    }

    private static func recovery(from row: [String: SQLValue]) -> DayRecovery {
        DayRecovery(
            day: row["day"]?.string ?? "",
            restingHeartRate: row["rhr"]?.double,
            hrv: row["hrv"]?.double
        )
    }

    private static func sleep(from row: [String: SQLValue]) -> NightSleep? {
        guard let hours = row["hours"]?.double else { return nil }
        return NightSleep(night: row["night"]?.string ?? "", hours: hours)
    }

    private static func body(from row: [String: SQLValue]) -> BodyPoint {
        BodyPoint(
            day: row["day"]?.string ?? "",
            mass: row["mass"]?.double,
            lean: row["lean"]?.double,
            fat: row["fat"]?.double
        )
    }

    private static func fitness(from row: [String: SQLValue]) -> FitnessPoint {
        FitnessPoint(
            month: row["month"]?.string ?? "",
            vo2Max: row["vo2max"]?.double,
            samples: row["samples"]?.int ?? 0
        )
    }

    private static func form(from row: [String: SQLValue]) -> FormPoint {
        FormPoint(
            month: row["month"]?.string ?? "",
            runs: row["runs"]?.int ?? 0,
            speed: row["speed"]?.double,
            heartRate: row["hr"]?.double,
            efficiency: row["efficiency"]?.double,
            cadence: row["cadence"]?.double,
            groundContact: row["gct"]?.double
        )
    }
}
