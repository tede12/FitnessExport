import FitnessSyncKit
import Foundation

enum RestDetector {

    struct Bin: Equatable {

        let startMs: Int64
        let heartRate: Double?
        let steps: Double
    }

    static let binMs: Int64 = 600_000
    static let margin = 3.0
    static let maxSteps = 10.0
    static let minimumMinutes = 30.0
    static let days = 75

    static func build(from database: HealthDatabase) async throws -> [String: [RestEpisode]] {
        guard let sleeping = try await database.rows(sleepingHeartRateSQL).first?["bpm"]?.double
        else { return [:] }
        async let binRows = database.rows(binsSQL)
        async let busyRows = database.rows(busySQL)
        let bins = try await binRows.compactMap { row -> Bin? in
            guard let start = row["bin"]?.int else { return nil }
            return Bin(
                startMs: Int64(start) * binMs, heartRate: row["hr"]?.double,
                steps: row["steps"]?.double ?? 0
            )
        }
        let busy = try await busyRows.compactMap { row -> ClosedRange<Int64>? in
            guard let start = row["start_ms"]?.int, let end = row["end_ms"]?.int, end >= start
            else { return nil }
            return Int64(start)...Int64(end)
        }
        let episodes = detect(bins: bins, busy: busy, sleepingHeartRate: sleeping)
        return Dictionary(grouping: episodes) { key(for: $0) }
    }

    static let sleepingHeartRateSQL = """
        SELECT AVG(s.value) AS bpm
        FROM category_sample c
        JOIN sample s
          ON s.metric_id = (SELECT id FROM metric WHERE key = 'heart_rate')
         AND s.start_ms >= c.start_ms AND s.start_ms < c.start_ms + c.dur_ms
        WHERE c.metric_id = (SELECT id FROM metric WHERE key = 'sleep_analysis')
          AND c.value IN (1,3,4,5)
          AND c.start_ms > CAST(strftime('%s','now','-30 days') AS INTEGER) * 1000
        """

    static let binsSQL = """
        SELECT s.start_ms / \(binMs) AS bin,
               AVG(CASE WHEN m.key = 'heart_rate' THEN s.value END) AS hr,
               SUM(CASE WHEN m.key = 'step_count' THEN s.value END) AS steps
        FROM sample s JOIN metric m ON m.id = s.metric_id
        WHERE m.key IN ('heart_rate', 'step_count')
          AND s.start_ms > CAST(strftime('%s','now','-\(days) days') AS INTEGER) * 1000
          AND CAST(strftime('%H', s.start_ms/1000, 'unixepoch', 'localtime') AS INT) BETWEEN 12 AND 21
        GROUP BY bin
        ORDER BY bin
        """

    static let busySQL = """
        SELECT c.start_ms, c.start_ms + c.dur_ms AS end_ms
        FROM category_sample c
        WHERE c.metric_id = (SELECT id FROM metric WHERE key = 'sleep_analysis')
          AND c.value IN (1,3,4,5)
          AND c.start_ms > CAST(strftime('%s','now','-\(days) days') AS INTEGER) * 1000
        UNION ALL
        SELECT start_ms, end_ms FROM workout
        WHERE start_ms > CAST(strftime('%s','now','-\(days) days') AS INTEGER) * 1000
        """

    static func detect(
        bins: [Bin], busy: [ClosedRange<Int64>], sleepingHeartRate: Double
    ) -> [RestEpisode] {
        let threshold = sleepingHeartRate + margin
        let restful = bins.filter { bin in
            guard let hr = bin.heartRate, hr <= threshold, bin.steps <= maxSteps else {
                return false
            }
            let range = bin.startMs...(bin.startMs + binMs - 1)
            return !busy.contains { $0.overlaps(range) }
        }.sorted { $0.startMs < $1.startMs }

        var episodes: [RestEpisode] = []
        var run: [Bin] = []

        func close() {
            defer { run = [] }
            guard let first = run.first, let last = run.last else { return }
            let start = first.startMs
            let end = last.startMs + binMs
            guard Double(end - start) / 60_000 >= minimumMinutes else { return }
            let rates = run.compactMap(\.heartRate)
            episodes.append(
                RestEpisode(
                    start: Date(timeIntervalSince1970: Double(start) / 1000),
                    end: Date(timeIntervalSince1970: Double(end) / 1000),
                    heartRate: rates.reduce(0, +) / Double(rates.count),
                    sleepingHeartRate: sleepingHeartRate
                )
            )
        }

        let present = Dictionary(bins.map { ($0.startMs, $0) }, uniquingKeysWith: { a, _ in a })
        for bin in restful {
            if let last = run.last {
                let gap = (bin.startMs - last.startMs) / binMs

                let bridgeable = gap == 2 && present[last.startMs + binMs] == nil
                if gap != 1 && !bridgeable { close() }
            }
            run.append(bin)
        }
        close()
        return episodes
    }

    static func key(for episode: RestEpisode) -> String {
        PlanItem.dayFormatter.string(from: episode.start.addingTimeInterval(12 * 3_600))
    }
}
