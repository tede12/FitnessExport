import FitnessSyncKit
import FitnessUI
import Foundation
import SQLite3
import os

private let dbLog = Logger(subsystem: "org.fitnessexport.FitnessExportMac", category: "database")

private final class SQLiteHandle {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        sqlite3_close_v2(pointer)
    }
}

private let sqliteTransient = unsafeBitCast(
    -1, to: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self
)

actor HealthDatabase {
    struct DatabaseError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let db: SQLiteHandle
    private var handle: OpaquePointer { db.pointer }
    let url: URL

    private var metricIDs: [String: Int64] = [:]
    private var sourceIDs: [SourceRecord: Int64] = [:]

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            throw DatabaseError(
                message: AppLanguage.format("Impossibile aprire il database: %@", url.path))
        }
        self.db = SQLiteHandle(pointer: db)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        try Self.configure(db)
        for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: url.path + suffix) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path + suffix)
        }
        try Self.migrate(db)
    }

    private static func configure(_ handle: OpaquePointer) throws {
        func run(_ sql: String) throws { try execute(sql, on: handle) }

        try run("PRAGMA journal_mode=WAL")

        try run("PRAGMA synchronous=NORMAL")
        try run("PRAGMA foreign_keys=ON")
        try run("PRAGMA temp_store=MEMORY")

        try run("PRAGMA cache_size=-65536")
        try run("PRAGMA busy_timeout=5000")
        try run("PRAGMA mmap_size=268435456")
    }

    private static func migrate(_ handle: OpaquePointer) throws {
        func run(_ sql: String) throws { try execute(sql, on: handle) }
        try run(
            """
            CREATE TABLE IF NOT EXISTS meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS cursor (
                stream TEXT PRIMARY KEY,
                anchor BLOB,
                updated_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS metric (
                id INTEGER PRIMARY KEY,
                key TEXT NOT NULL UNIQUE
            );

            CREATE TABLE IF NOT EXISTS source (
                id INTEGER PRIMARY KEY,
                bundle_id TEXT NOT NULL,
                name TEXT NOT NULL,
                UNIQUE (bundle_id, name)
            );

            CREATE TABLE IF NOT EXISTS sample (
                uuid BLOB PRIMARY KEY,
                metric_id INTEGER NOT NULL REFERENCES metric(id),
                start_ms INTEGER NOT NULL,
                dur_ms INTEGER NOT NULL DEFAULT 0,
                value REAL NOT NULL,
                source_id INTEGER NOT NULL REFERENCES source(id)
            ) WITHOUT ROWID;

            CREATE INDEX IF NOT EXISTS sample_metric_time
                ON sample (metric_id, start_ms);

            CREATE TABLE IF NOT EXISTS category_sample (
                uuid BLOB PRIMARY KEY,
                metric_id INTEGER NOT NULL REFERENCES metric(id),
                start_ms INTEGER NOT NULL,
                dur_ms INTEGER NOT NULL DEFAULT 0,
                value INTEGER NOT NULL,
                source_id INTEGER NOT NULL REFERENCES source(id)
            ) WITHOUT ROWID;

            CREATE INDEX IF NOT EXISTS category_metric_time
                ON category_sample (metric_id, start_ms);

            CREATE TABLE IF NOT EXISTS workout (
                uuid BLOB PRIMARY KEY,
                activity_type INTEGER NOT NULL,
                start_ms INTEGER NOT NULL,
                end_ms INTEGER NOT NULL,
                duration_s REAL NOT NULL,
                distance_m REAL,
                energy_kcal REAL,
                source_name TEXT NOT NULL,
                source_bundle_id TEXT NOT NULL,
                device_name TEXT,
                time_zone TEXT,
                is_indoor INTEGER,
                elevation_up_m REAL,
                elevation_down_m REAL,
                weather_temp_c REAL,
                pool_length_m REAL,
                plan_name TEXT,
                has_route INTEGER NOT NULL DEFAULT 0,
                raw TEXT NOT NULL
            ) WITHOUT ROWID;

            CREATE INDEX IF NOT EXISTS workout_start ON workout (start_ms);

            CREATE TABLE IF NOT EXISTS workout_activity (
                uuid BLOB PRIMARY KEY,
                workout_uuid BLOB NOT NULL REFERENCES workout(uuid) ON DELETE CASCADE,
                idx INTEGER NOT NULL,
                start_ms INTEGER NOT NULL,
                end_ms INTEGER,
                activity_type INTEGER NOT NULL,
                location_type INTEGER NOT NULL,
                name TEXT
            ) WITHOUT ROWID;

            CREATE INDEX IF NOT EXISTS workout_activity_workout
                ON workout_activity (workout_uuid, idx);

            CREATE TABLE IF NOT EXISTS workout_event (
                id INTEGER PRIMARY KEY,
                workout_uuid BLOB NOT NULL REFERENCES workout(uuid) ON DELETE CASCADE,
                type INTEGER NOT NULL,
                start_ms INTEGER NOT NULL,
                end_ms INTEGER NOT NULL
            );

            CREATE INDEX IF NOT EXISTS workout_event_workout
                ON workout_event (workout_uuid, start_ms);

            CREATE TABLE IF NOT EXISTS planned_step (
                id INTEGER PRIMARY KEY,
                workout_uuid BLOB NOT NULL REFERENCES workout(uuid) ON DELETE CASCADE,
                idx INTEGER NOT NULL,
                role TEXT NOT NULL,
                name TEXT,
                goal_kind TEXT NOT NULL,
                goal_value REAL,
                alert TEXT
            );

            CREATE INDEX IF NOT EXISTS planned_step_workout
                ON planned_step (workout_uuid, idx);

            CREATE TABLE IF NOT EXISTS route_point (
                id INTEGER PRIMARY KEY,
                workout_uuid BLOB NOT NULL REFERENCES workout(uuid) ON DELETE CASCADE,
                ts_ms INTEGER NOT NULL,
                lat REAL NOT NULL,
                lon REAL NOT NULL,
                altitude_m REAL NOT NULL,
                h_accuracy_m REAL NOT NULL,
                v_accuracy_m REAL NOT NULL,
                speed_ms REAL NOT NULL,
                course_deg REAL NOT NULL
            );

            CREATE INDEX IF NOT EXISTS route_point_workout
                ON route_point (workout_uuid, ts_ms);
            CREATE TABLE IF NOT EXISTS athlete (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                date_of_birth_ms INTEGER,
                biological_sex TEXT,
                blood_type TEXT,
                body_mass_kg REAL,
                height_m REAL,
                updated_ms INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS activity_type (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS plan_entry (
                id INTEGER PRIMARY KEY,
                day TEXT NOT NULL,
                slot TEXT NOT NULL,
                title TEXT NOT NULL,
                detail TEXT,
                target TEXT,
                done INTEGER NOT NULL DEFAULT 0,
                rpe INTEGER,
                note TEXT,
                updated_ms INTEGER NOT NULL,
                UNIQUE (day, slot)
            );

            CREATE TABLE IF NOT EXISTS sync_run (
                id INTEGER PRIMARY KEY,
                device_name TEXT NOT NULL,
                started_ms INTEGER NOT NULL,
                finished_ms INTEGER,
                upserted INTEGER NOT NULL DEFAULT 0,
                deleted INTEGER NOT NULL DEFAULT 0,
                bytes INTEGER NOT NULL DEFAULT 0,
                status TEXT NOT NULL
            );
            """
        )
        try run(
            "INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', '2')"
        )
        for entry in WorkoutActivityNames.all {
            try run(
                """
                INSERT INTO activity_type (id, name) VALUES (\(entry.rawValue), '\(entry.name)')
                ON CONFLICT(id) DO UPDATE SET name = excluded.name
                """
            )
        }
        try createViews(handle)
    }

    private static func createViews(_ handle: OpaquePointer) throws {
        func run(_ sql: String) throws { try execute(sql, on: handle) }
        try run(
            """
            DROP VIEW IF EXISTS v_sample;
            CREATE VIEW v_sample AS
            SELECT
                s.uuid              AS uuid,
                m.key               AS metric,
                s.start_ms / 1000.0 AS start_epoch,
                datetime(s.start_ms / 1000, 'unixepoch', 'localtime') AS start_local,
                s.dur_ms / 1000.0   AS duration_s,
                s.value             AS value,
                src.bundle_id       AS source_bundle_id,
                src.name            AS source_name
            FROM sample s
            JOIN metric m ON m.id = s.metric_id
            JOIN source src ON src.id = s.source_id;

            DROP VIEW IF EXISTS v_category;
            CREATE VIEW v_category AS
            SELECT
                c.uuid              AS uuid,
                m.key               AS metric,
                c.start_ms / 1000.0 AS start_epoch,
                datetime(c.start_ms / 1000, 'unixepoch', 'localtime') AS start_local,
                c.dur_ms / 1000.0   AS duration_s,
                c.value             AS value,
                src.bundle_id       AS source_bundle_id,
                src.name            AS source_name
            FROM category_sample c
            JOIN metric m ON m.id = c.metric_id
            JOIN source src ON src.id = c.source_id;

            DROP VIEW IF EXISTS v_workout;
            CREATE VIEW v_workout AS
            SELECT
                w.uuid,
                w.activity_type,
                COALESCE(t.name, 'unknown') AS activity,
                datetime(w.start_ms / 1000, 'unixepoch', 'localtime') AS start_local,
                w.start_ms / 1000.0 AS start_epoch,
                w.duration_s,
                w.distance_m,
                w.energy_kcal,
                CASE WHEN w.distance_m > 0
                     THEN w.duration_s / (w.distance_m / 1000.0)
                     ELSE NULL END AS pace_s_per_km,
                w.plan_name,
                w.device_name,
                w.has_route
            FROM workout w
            LEFT JOIN activity_type t ON t.id = w.activity_type;
            DROP VIEW IF EXISTS v_workout_source;
            CREATE VIEW v_workout_source AS
            SELECT workout_uuid, metric_id, source_id, samples
            FROM (
                SELECT w.uuid AS workout_uuid,
                       s.metric_id AS metric_id,
                       s.source_id AS source_id,
                       COUNT(*) AS samples,
                       ROW_NUMBER() OVER (
                           PARTITION BY w.uuid, s.metric_id
                           ORDER BY COUNT(*) DESC, s.source_id
                       ) AS rank
                FROM workout w
                JOIN sample s
                  ON s.start_ms >= w.start_ms AND s.start_ms < w.end_ms
                GROUP BY w.uuid, s.metric_id, s.source_id
            )
            WHERE rank = 1
               OR metric_id = (SELECT id FROM metric WHERE key = 'heart_rate');

            DROP VIEW IF EXISTS v_workout_sample;
            CREATE VIEW v_workout_sample AS
            SELECT
                w.uuid        AS workout_uuid,
                m.key         AS metric,
                s.start_ms    AS start_ms,
                s.dur_ms      AS dur_ms,
                s.value       AS value,
                src.name      AS source_name
            FROM workout w
            JOIN sample s
              ON s.start_ms >= w.start_ms AND s.start_ms < w.end_ms
            JOIN metric m ON m.id = s.metric_id
            JOIN source src ON src.id = s.source_id
            JOIN v_workout_source pick
              ON pick.workout_uuid = w.uuid
             AND pick.metric_id = s.metric_id
             AND pick.source_id = s.source_id;
            DROP VIEW IF EXISTS v_workout_metric;
            CREATE VIEW v_workout_metric AS
            SELECT
                workout_uuid,
                metric,
                COUNT(*)    AS samples,
                SUM(value)  AS total,
                AVG(value)  AS average,
                MIN(value)  AS minimum,
                MAX(value)  AS maximum,
                GROUP_CONCAT(DISTINCT source_name) AS source_name
            FROM v_workout_sample
            GROUP BY workout_uuid, metric;
            DROP VIEW IF EXISTS v_workout_sample_all;
            CREATE VIEW v_workout_sample_all AS
            SELECT
                w.uuid   AS workout_uuid,
                m.key    AS metric,
                s.start_ms,
                s.dur_ms,
                s.value,
                src.name AS source_name
            FROM workout w
            JOIN sample s
              ON s.start_ms >= w.start_ms AND s.start_ms < w.end_ms
            JOIN metric m ON m.id = s.metric_id
            JOIN source src ON src.id = s.source_id;
            """
        )
    }

    func saveProfile(_ profile: AthleteProfile) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(
            """
            INSERT INTO athlete (id, date_of_birth_ms, biological_sex, blood_type,
                                 body_mass_kg, height_m, updated_ms)
            VALUES (1, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                date_of_birth_ms = excluded.date_of_birth_ms,
                biological_sex = excluded.biological_sex,
                blood_type = excluded.blood_type,
                body_mass_kg = excluded.body_mass_kg,
                height_m = excluded.height_m,
                updated_ms = excluded.updated_ms
            """,
            &statement
        )
        if let birth = profile.dateOfBirth {
            sqlite3_bind_int64(statement, 1, milliseconds(birth))
        } else {
            sqlite3_bind_null(statement, 1)
        }
        bind(optionalText: profile.biologicalSex, at: 2, statement)
        bind(optionalText: profile.bloodType, at: 3, statement)
        bind(optionalDouble: profile.bodyMassKg, at: 4, statement)
        bind(optionalDouble: profile.heightM, at: 5, statement)
        sqlite3_bind_int64(statement, 6, milliseconds(Date()))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError("salvataggio profilo")
        }
    }

    struct PlanEntry: Sendable, Equatable {
        var day: String
        var slot: String
        var title: String
        var detail: String?
        var target: String?
        var done: Bool
        var rpe: Int?
        var note: String?
    }

    func upsertPlan(_ entries: [PlanEntry]) throws {
        try transaction {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(
                """
                INSERT INTO plan_entry (day, slot, title, detail, target, done, rpe, note, updated_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(day, slot) DO UPDATE SET
                    title = excluded.title, detail = excluded.detail,
                    target = excluded.target, updated_ms = excluded.updated_ms
                """,
                &statement
            )
            for entry in entries {
                bind(text: entry.day, at: 1, statement)
                bind(text: entry.slot, at: 2, statement)
                bind(text: entry.title, at: 3, statement)
                bind(optionalText: entry.detail, at: 4, statement)
                bind(optionalText: entry.target, at: 5, statement)
                sqlite3_bind_int64(statement, 6, entry.done ? 1 : 0)
                if let rpe = entry.rpe {
                    sqlite3_bind_int64(statement, 7, Int64(rpe))
                } else {
                    sqlite3_bind_null(statement, 7)
                }
                bind(optionalText: entry.note, at: 8, statement)
                sqlite3_bind_int64(statement, 9, milliseconds(Date()))
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw lastError("salvataggio piano")
                }
                sqlite3_reset(statement)
            }
        }
    }

    func markPlan(day: String, slot: String, done: Bool, rpe: Int?, note: String?) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(
            """
            UPDATE plan_entry SET done = ?, rpe = ?, note = ?, updated_ms = ?
            WHERE day = ? AND slot = ?
            """,
            &statement
        )
        sqlite3_bind_int64(statement, 1, done ? 1 : 0)
        if let rpe {
            sqlite3_bind_int64(statement, 2, Int64(rpe))
        } else {
            sqlite3_bind_null(statement, 2)
        }
        bind(optionalText: note, at: 3, statement)
        sqlite3_bind_int64(statement, 4, milliseconds(Date()))
        bind(text: day, at: 5, statement)
        bind(text: slot, at: 6, statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError("aggiornamento piano")
        }
    }

    func rows(_ sql: String) throws -> [[String: SQLValue]] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(sql, &statement)

        var result: [[String: SQLValue]] = []
        let columnCount = sqlite3_column_count(statement)
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: SQLValue] = [:]
            for index in 0..<columnCount {
                guard let namePointer = sqlite3_column_name(statement, index) else { continue }
                let name = String(cString: namePointer)
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER:
                    row[name] = .number(Double(sqlite3_column_int64(statement, index)))
                case SQLITE_FLOAT:
                    row[name] = .number(sqlite3_column_double(statement, index))
                case SQLITE_NULL:
                    row[name] = .null
                default:
                    if let text = sqlite3_column_text(statement, index) {
                        row[name] = .text(String(cString: text))
                    } else {
                        row[name] = .null
                    }
                }
            }
            result.append(row)
        }
        return result
    }

    func cursor(for stream: SyncStream) throws -> Data? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT anchor FROM cursor WHERE stream = ?", &statement)
        bind(text: stream.storageKey, at: 1, statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, 0))
        return Data(bytes: bytes, count: count)
    }

    func allCursors() throws -> [String: Data] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT stream, anchor FROM cursor", &statement)
        var result: [String: Data] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let keyPointer = sqlite3_column_text(statement, 0) else { continue }
            let key = String(cString: keyPointer)
            if let bytes = sqlite3_column_blob(statement, 1) {
                result[key] = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
            }
        }
        return result
    }

    func resetCursors() throws {
        try execute("DELETE FROM cursor")
    }

    func applyQuantities(
        _ records: [QuantityRecord],
        sources: [SourceRecord],
        metricKey: String,
        stream: SyncStream,
        anchor: Data?
    ) throws -> Int {
        try transaction {
            let metricID = try metricID(forKey: metricKey)
            let sourceIDs = try sourceIDs(for: sources)

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(
                """
                INSERT INTO sample (uuid, metric_id, start_ms, dur_ms, value, source_id)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(uuid) DO UPDATE SET
                    metric_id = excluded.metric_id,
                    start_ms  = excluded.start_ms,
                    dur_ms    = excluded.dur_ms,
                    value     = excluded.value,
                    source_id = excluded.source_id
                """,
                &statement
            )

            for record in records {

                guard sourceIDs.indices.contains(record.sourceIndex) else {
                    throw DatabaseError(
                        message: "indice sorgente fuori intervallo: \(record.sourceIndex)"
                    )
                }
                bind(uuid: record.uuid, at: 1, statement)
                sqlite3_bind_int64(statement, 2, metricID)
                sqlite3_bind_int64(statement, 3, milliseconds(record.start))
                sqlite3_bind_int64(
                    statement, 4,
                    Int64((record.end.timeIntervalSince(record.start) * 1_000).rounded())
                )
                sqlite3_bind_double(statement, 5, record.value)
                sqlite3_bind_int64(statement, 6, sourceIDs[record.sourceIndex])
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw lastError("inserimento campione")
                }
                sqlite3_reset(statement)
            }

            try setCursor(stream: stream, anchor: anchor)
            return records.count
        }
    }

    func applyCategories(
        _ records: [CategoryRecord],
        sources: [SourceRecord],
        metricKey: String,
        stream: SyncStream,
        anchor: Data?
    ) throws -> Int {
        try transaction {
            let metricID = try metricID(forKey: metricKey)
            let sourceIDs = try sourceIDs(for: sources)

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(
                """
                INSERT INTO category_sample (uuid, metric_id, start_ms, dur_ms, value, source_id)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(uuid) DO UPDATE SET
                    metric_id = excluded.metric_id,
                    start_ms  = excluded.start_ms,
                    dur_ms    = excluded.dur_ms,
                    value     = excluded.value,
                    source_id = excluded.source_id
                """,
                &statement
            )

            for record in records {
                guard sourceIDs.indices.contains(record.sourceIndex) else {
                    throw DatabaseError(
                        message: "indice sorgente fuori intervallo: \(record.sourceIndex)"
                    )
                }
                bind(uuid: record.uuid, at: 1, statement)
                sqlite3_bind_int64(statement, 2, metricID)
                sqlite3_bind_int64(statement, 3, milliseconds(record.start))
                sqlite3_bind_int64(
                    statement, 4,
                    Int64((record.end.timeIntervalSince(record.start) * 1_000).rounded())
                )
                sqlite3_bind_int64(statement, 5, Int64(record.value))
                sqlite3_bind_int64(statement, 6, sourceIDs[record.sourceIndex])
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw lastError("inserimento campione categoriale")
                }
                sqlite3_reset(statement)
            }

            try setCursor(stream: stream, anchor: anchor)
            return records.count
        }
    }

    func applyWorkouts(_ workouts: [WorkoutRecord], anchor: Data?) throws -> Int {
        try transaction {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970

            var insert: OpaquePointer?
            defer { sqlite3_finalize(insert) }
            try prepare(
                """
                INSERT INTO workout (
                    uuid, activity_type, start_ms, end_ms, duration_s, distance_m, energy_kcal,
                    source_name, source_bundle_id, device_name, time_zone, is_indoor,
                    elevation_up_m, elevation_down_m, weather_temp_c, pool_length_m,
                    plan_name, has_route, raw
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(uuid) DO UPDATE SET
                    activity_type = excluded.activity_type,
                    start_ms = excluded.start_ms, end_ms = excluded.end_ms,
                    duration_s = excluded.duration_s, distance_m = excluded.distance_m,
                    energy_kcal = excluded.energy_kcal, source_name = excluded.source_name,
                    source_bundle_id = excluded.source_bundle_id,
                    device_name = excluded.device_name, time_zone = excluded.time_zone,
                    is_indoor = excluded.is_indoor, elevation_up_m = excluded.elevation_up_m,
                    elevation_down_m = excluded.elevation_down_m,
                    weather_temp_c = excluded.weather_temp_c,
                    pool_length_m = excluded.pool_length_m, plan_name = excluded.plan_name,
                    has_route = excluded.has_route, raw = excluded.raw
                """,
                &insert
            )

            for workout in workouts {

                try deleteChildren(of: workout.uuid)

                bind(uuid: workout.uuid, at: 1, insert)
                sqlite3_bind_int64(insert, 2, Int64(workout.activityType))
                sqlite3_bind_int64(insert, 3, milliseconds(workout.start))
                sqlite3_bind_int64(insert, 4, milliseconds(workout.end))
                sqlite3_bind_double(insert, 5, workout.duration)
                bind(optionalDouble: workout.totalDistance, at: 6, insert)
                bind(optionalDouble: workout.totalEnergy, at: 7, insert)
                bind(text: workout.sourceName, at: 8, insert)
                bind(text: workout.sourceBundleID, at: 9, insert)
                bind(optionalText: workout.deviceName, at: 10, insert)
                bind(optionalText: workout.timeZone, at: 11, insert)
                if let indoor = workout.isIndoor {
                    sqlite3_bind_int64(insert, 12, indoor ? 1 : 0)
                } else {
                    sqlite3_bind_null(insert, 12)
                }
                bind(optionalDouble: workout.elevationAscended, at: 13, insert)
                bind(optionalDouble: workout.elevationDescended, at: 14, insert)
                bind(optionalDouble: workout.weatherTemperature, at: 15, insert)
                bind(optionalDouble: workout.poolLength, at: 16, insert)
                bind(optionalText: workout.planName, at: 17, insert)
                sqlite3_bind_int64(insert, 18, workout.hasRoute ? 1 : 0)

                let raw = String(decoding: try encoder.encode(workout), as: UTF8.self)
                bind(text: raw, at: 19, insert)

                guard sqlite3_step(insert) == SQLITE_DONE else {
                    throw lastError("inserimento allenamento")
                }
                sqlite3_reset(insert)

                try insertActivities(workout)
                try insertEvents(workout)
                try insertPlannedSteps(workout)
            }

            try setCursor(stream: .workouts, anchor: anchor)
            return workouts.count
        }
    }

    func applyRoutes(_ routes: [RouteRecord], anchor: Data?) throws -> Int {
        try transaction {
            var deleteStatement: OpaquePointer?
            try prepare("DELETE FROM route_point WHERE workout_uuid = ?", &deleteStatement)
            defer { sqlite3_finalize(deleteStatement) }

            var insert: OpaquePointer?
            defer { sqlite3_finalize(insert) }
            try prepare(
                """
                INSERT INTO route_point (
                    workout_uuid, ts_ms, lat, lon, altitude_m,
                    h_accuracy_m, v_accuracy_m, speed_ms, course_deg
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                &insert
            )

            var points = 0
            for route in routes {
                bind(uuid: route.workoutUUID, at: 1, deleteStatement)
                guard sqlite3_step(deleteStatement) == SQLITE_DONE else {
                    throw lastError("pulizia percorso")
                }
                sqlite3_reset(deleteStatement)

                for point in route.points {
                    bind(uuid: route.workoutUUID, at: 1, insert)
                    sqlite3_bind_int64(insert, 2, milliseconds(point.timestamp))
                    sqlite3_bind_double(insert, 3, point.latitude)
                    sqlite3_bind_double(insert, 4, point.longitude)
                    sqlite3_bind_double(insert, 5, point.altitude)
                    sqlite3_bind_double(insert, 6, point.horizontalAccuracy)
                    sqlite3_bind_double(insert, 7, point.verticalAccuracy)
                    sqlite3_bind_double(insert, 8, point.speed)
                    sqlite3_bind_double(insert, 9, point.course)
                    guard sqlite3_step(insert) == SQLITE_DONE else {
                        throw lastError("inserimento punto del percorso")
                    }
                    sqlite3_reset(insert)
                    points += 1
                }
            }

            try setCursor(stream: .routes, anchor: anchor)
            return points
        }
    }

    func applyDeletions(
        _ uuids: [UUID], stream: SyncStream, anchor: Data?
    ) throws -> Int {
        try transaction {
            let table: String
            switch stream {
            case .quantity: table = "sample"
            case .category: table = "category_sample"
            case .workouts: table = "workout"
            case .routes: table = "route_point"
            }
            let column = stream == .routes ? "workout_uuid" : "uuid"

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare("DELETE FROM \(table) WHERE \(column) = ?", &statement)

            for uuid in uuids {
                bind(uuid: uuid, at: 1, statement)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw lastError("cancellazione")
                }
                sqlite3_reset(statement)
            }

            try setCursor(stream: stream, anchor: anchor)
            return uuids.count
        }
    }

    struct Stats: Sendable, Equatable {
        var samples: Int
        var categorySamples: Int
        var workouts: Int
        var routePoints: Int
        var fileSizeBytes: Int
        var earliest: Date?
        var latest: Date?
    }

    func stats() throws -> Stats {
        var stats = Stats(
            samples: try count("SELECT COUNT(*) FROM sample"),
            categorySamples: try count("SELECT COUNT(*) FROM category_sample"),
            workouts: try count("SELECT COUNT(*) FROM workout"),
            routePoints: try count("SELECT COUNT(*) FROM route_point"),
            fileSizeBytes: 0,
            earliest: nil,
            latest: nil
        )
        var total = 0
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                let size = attributes[.size] as? Int
            {
                total += size
            }
        }
        stats.fileSizeBytes = total
        if let earliest = try? optionalInt("SELECT MIN(start_ms) FROM sample") {
            stats.earliest = Date(timeIntervalSince1970: Double(earliest) / 1_000)
        }
        if let latest = try? optionalInt("SELECT MAX(start_ms) FROM sample") {
            stats.latest = Date(timeIntervalSince1970: Double(latest) / 1_000)
        }
        return stats
    }

    func finalizeSync() {
        try? execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try? execute("PRAGMA optimize")
    }

    func recordRun(
        deviceName: String, started: Date, finished: Date?, upserted: Int, deleted: Int,
        bytes: Int, status: String
    ) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(
            """
            INSERT INTO sync_run (device_name, started_ms, finished_ms, upserted, deleted, bytes, status)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            &statement
        )
        bind(text: deviceName, at: 1, statement)
        sqlite3_bind_int64(statement, 2, milliseconds(started))
        if let finished {
            sqlite3_bind_int64(statement, 3, milliseconds(finished))
        } else {
            sqlite3_bind_null(statement, 3)
        }
        sqlite3_bind_int64(statement, 4, Int64(upserted))
        sqlite3_bind_int64(statement, 5, Int64(deleted))
        sqlite3_bind_int64(statement, 6, Int64(bytes))
        bind(text: status, at: 7, statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError("registrazione sincronizzazione")
        }
    }

    private func deleteChildren(of workoutUUID: UUID) throws {
        for table in ["workout_activity", "workout_event", "planned_step"] {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare("DELETE FROM \(table) WHERE workout_uuid = ?", &statement)
            bind(uuid: workoutUUID, at: 1, statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw lastError("pulizia \(table)")
            }
        }
    }

    private func insertActivities(_ workout: WorkoutRecord) throws {
        guard !workout.activities.isEmpty else { return }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(
            """
            INSERT INTO workout_activity
                (uuid, workout_uuid, idx, start_ms, end_ms, activity_type, location_type, name)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(uuid) DO UPDATE SET
                workout_uuid = excluded.workout_uuid, idx = excluded.idx,
                start_ms = excluded.start_ms, end_ms = excluded.end_ms,
                activity_type = excluded.activity_type,
                location_type = excluded.location_type, name = excluded.name
            """,
            &statement
        )
        for (index, activity) in workout.activities.enumerated() {
            bind(uuid: activity.uuid, at: 1, statement)
            bind(uuid: workout.uuid, at: 2, statement)
            sqlite3_bind_int64(statement, 3, Int64(index))
            sqlite3_bind_int64(statement, 4, milliseconds(activity.start))
            if let end = activity.end {
                sqlite3_bind_int64(statement, 5, milliseconds(end))
            } else {
                sqlite3_bind_null(statement, 5)
            }
            sqlite3_bind_int64(statement, 6, Int64(activity.activityType))
            sqlite3_bind_int64(statement, 7, Int64(activity.locationType))
            bind(optionalText: activity.metadata["HKWorkoutActivityName"], at: 8, statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw lastError("inserimento lap")
            }
            sqlite3_reset(statement)
        }
    }

    private func insertEvents(_ workout: WorkoutRecord) throws {
        guard !workout.events.isEmpty else { return }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(
            """
            INSERT INTO workout_event (workout_uuid, type, start_ms, end_ms)
            VALUES (?, ?, ?, ?)
            """,
            &statement
        )
        for event in workout.events {
            bind(uuid: workout.uuid, at: 1, statement)
            sqlite3_bind_int64(statement, 2, Int64(event.type))
            sqlite3_bind_int64(statement, 3, milliseconds(event.start))
            sqlite3_bind_int64(statement, 4, milliseconds(event.end))
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw lastError("inserimento evento")
            }
            sqlite3_reset(statement)
        }
    }

    private func insertPlannedSteps(_ workout: WorkoutRecord) throws {
        guard !workout.plannedSteps.isEmpty else { return }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(
            """
            INSERT INTO planned_step (workout_uuid, idx, role, name, goal_kind, goal_value, alert)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            &statement
        )
        for step in workout.plannedSteps {
            bind(uuid: workout.uuid, at: 1, statement)
            sqlite3_bind_int64(statement, 2, Int64(step.index))
            bind(text: step.role, at: 3, statement)
            bind(optionalText: step.name, at: 4, statement)
            bind(text: step.goalKind, at: 5, statement)
            bind(optionalDouble: step.goalValue, at: 6, statement)
            bind(optionalText: step.alert, at: 7, statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw lastError("inserimento step pianificato")
            }
            sqlite3_reset(statement)
        }
    }

    private func metricID(forKey key: String) throws -> Int64 {
        if let cached = metricIDs[key] { return cached }
        try execute("INSERT OR IGNORE INTO metric (key) VALUES ('\(escaped(key))')")
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT id FROM metric WHERE key = ?", &statement)
        bind(text: key, at: 1, statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError(message: "metrica non trovata: \(key)")
        }
        let id = sqlite3_column_int64(statement, 0)
        metricIDs[key] = id
        return id
    }

    private func sourceIDs(for sources: [SourceRecord]) throws -> [Int64] {
        var ids: [Int64] = []
        ids.reserveCapacity(sources.count)
        for source in sources {
            if let cached = sourceIDs[source] {
                ids.append(cached)
                continue
            }
            var insert: OpaquePointer?
            try prepare(
                "INSERT OR IGNORE INTO source (bundle_id, name) VALUES (?, ?)", &insert
            )
            bind(text: source.bundleID, at: 1, insert)
            bind(text: source.name, at: 2, insert)
            _ = sqlite3_step(insert)
            sqlite3_finalize(insert)

            var select: OpaquePointer?
            defer { sqlite3_finalize(select) }
            try prepare(
                "SELECT id FROM source WHERE bundle_id = ? AND name = ?", &select
            )
            bind(text: source.bundleID, at: 1, select)
            bind(text: source.name, at: 2, select)
            guard sqlite3_step(select) == SQLITE_ROW else {
                throw DatabaseError(message: "sorgente non trovata: \(source.bundleID)")
            }
            let id = sqlite3_column_int64(select, 0)
            sourceIDs[source] = id
            ids.append(id)
        }
        return ids
    }

    private func setCursor(stream: SyncStream, anchor: Data?) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(
            """
            INSERT INTO cursor (stream, anchor, updated_at) VALUES (?, ?, ?)
            ON CONFLICT(stream) DO UPDATE SET anchor = excluded.anchor,
                                              updated_at = excluded.updated_at
            """,
            &statement
        )
        bind(text: stream.storageKey, at: 1, statement)
        if let anchor {
            _ = anchor.withUnsafeBytes { buffer in
                sqlite3_bind_blob(statement, 2, buffer.baseAddress, Int32(anchor.count), sqliteTransient)
            }
        } else {
            sqlite3_bind_null(statement, 2)
        }
        sqlite3_bind_int64(statement, 3, milliseconds(Date()))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError("aggiornamento cursore")
        }
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        try Self.execute(sql, on: handle)
    }

    private static func execute(_ sql: String, on handle: OpaquePointer?) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? AppLanguage.text("errore sconosciuto")
            sqlite3_free(errorPointer)
            throw DatabaseError(message: AppLanguage.format("SQL fallito: %@", message))
        }
    }

    private func prepare(_ sql: String, _ statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError("preparazione")
        }
    }

    private func count(_ sql: String) throws -> Int {
        Int(try optionalInt(sql) ?? 0)
    }

    private func optionalInt(_ sql: String) throws -> Int64? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(sql, &statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private func bind(uuid: UUID, at index: Int32, _ statement: OpaquePointer?) {
        var bytes = uuid.uuid
        withUnsafeBytes(of: &bytes) { buffer in
            _ = sqlite3_bind_blob(statement, index, buffer.baseAddress, 16, sqliteTransient)
        }
    }

    private func bind(text: String, at index: Int32, _ statement: OpaquePointer?) {
        _ = sqlite3_bind_text(statement, index, text, -1, sqliteTransient)
    }

    private func bind(optionalText: String?, at index: Int32, _ statement: OpaquePointer?) {
        if let optionalText {
            bind(text: optionalText, at: index, statement)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bind(optionalDouble: Double?, at index: Int32, _ statement: OpaquePointer?) {
        if let optionalDouble {
            sqlite3_bind_double(statement, index, optionalDouble)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private func lastError(_ context: String) -> DatabaseError {
        let message = String(cString: sqlite3_errmsg(handle))
        dbLog.error("\(context, privacy: .private): \(message, privacy: .private)")
        return DatabaseError(message: "\(context): \(message)")
    }
}
