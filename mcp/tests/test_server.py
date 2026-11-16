#!/usr/bin/env python3
"""Tests for the MCP server, against a temporary archive.

Run: python -m unittest discover -s mcp/tests

They are deliberately plain unittest: the server has no dependencies, and a test
suite that needs pytest installed would undo that.
"""

from datetime import datetime
import json
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SERVER_COMMAND = [sys.executable, "-m", "fitness_health"]

SCHEMA = """
CREATE TABLE metric (id INTEGER PRIMARY KEY, key TEXT UNIQUE);
CREATE TABLE source (id INTEGER PRIMARY KEY, bundle_id TEXT, name TEXT);
CREATE TABLE sample (uuid BLOB PRIMARY KEY, metric_id INTEGER, start_ms INTEGER,
                     dur_ms INTEGER DEFAULT 0, value REAL, source_id INTEGER);
CREATE TABLE category_sample (uuid BLOB PRIMARY KEY, metric_id INTEGER, start_ms INTEGER,
                              dur_ms INTEGER DEFAULT 0, value INTEGER, source_id INTEGER);
CREATE TABLE workout (uuid BLOB PRIMARY KEY, activity_type INTEGER, start_ms INTEGER,
                      end_ms INTEGER, duration_s REAL, distance_m REAL, energy_kcal REAL,
                      source_name TEXT, source_bundle_id TEXT, device_name TEXT,
                      time_zone TEXT, is_indoor INTEGER, elevation_up_m REAL,
                      elevation_down_m REAL, weather_temp_c REAL, pool_length_m REAL,
                      plan_name TEXT, has_route INTEGER DEFAULT 0, raw TEXT);
CREATE TABLE workout_activity (uuid BLOB PRIMARY KEY, workout_uuid BLOB, idx INTEGER,
                               start_ms INTEGER, end_ms INTEGER, activity_type INTEGER,
                               location_type INTEGER, name TEXT);
CREATE TABLE planned_step (id INTEGER PRIMARY KEY, workout_uuid BLOB, idx INTEGER,
                           role TEXT, name TEXT, goal_kind TEXT, goal_value REAL, alert TEXT);
CREATE TABLE activity_type (id INTEGER PRIMARY KEY, name TEXT);
CREATE TABLE athlete (id INTEGER PRIMARY KEY CHECK (id = 1), date_of_birth_ms INTEGER,
                      biological_sex TEXT, blood_type TEXT, body_mass_kg REAL,
                      height_m REAL, updated_ms INTEGER);
CREATE TABLE plan_entry (id INTEGER PRIMARY KEY, day TEXT, slot TEXT, title TEXT,
                         detail TEXT, target TEXT, done INTEGER DEFAULT 0, rpe INTEGER,
                         note TEXT, updated_ms INTEGER, UNIQUE (day, slot));
CREATE TABLE sync_run (id INTEGER PRIMARY KEY, device_name TEXT, started_ms INTEGER,
                       finished_ms INTEGER, upserted INTEGER, deleted INTEGER,
                       bytes INTEGER, status TEXT);

CREATE VIEW v_sample AS
SELECT s.uuid, m.key AS metric, s.start_ms/1000.0 AS start_epoch,
       datetime(s.start_ms/1000,'unixepoch','localtime') AS start_local,
       s.dur_ms/1000.0 AS duration_s, s.value, src.bundle_id AS source_bundle_id,
       src.name AS source_name
FROM sample s JOIN metric m ON m.id=s.metric_id JOIN source src ON src.id=s.source_id;

CREATE VIEW v_category AS
SELECT c.uuid, m.key AS metric, c.start_ms/1000.0 AS start_epoch,
       datetime(c.start_ms/1000,'unixepoch','localtime') AS start_local,
       c.dur_ms/1000.0 AS duration_s, c.value, src.name AS source_name
FROM category_sample c JOIN metric m ON m.id=c.metric_id JOIN source src ON src.id=c.source_id;

CREATE VIEW v_workout AS
SELECT w.uuid, w.activity_type, COALESCE(t.name,'unknown') AS activity,
       datetime(w.start_ms/1000,'unixepoch','localtime') AS start_local,
       w.start_ms/1000.0 AS start_epoch, w.duration_s, w.distance_m, w.energy_kcal,
       CASE WHEN w.distance_m > 0 THEN w.duration_s/(w.distance_m/1000.0) END AS pace_s_per_km,
       w.plan_name, w.device_name, w.has_route
FROM workout w LEFT JOIN activity_type t ON t.id = w.activity_type;

CREATE VIEW v_workout_source AS
SELECT workout_uuid, metric_id, source_id, samples FROM (
  SELECT w.uuid AS workout_uuid, s.metric_id, s.source_id, COUNT(*) AS samples,
         ROW_NUMBER() OVER (PARTITION BY w.uuid, s.metric_id
                            ORDER BY COUNT(*) DESC, s.source_id) AS rank
  FROM workout w JOIN sample s ON s.start_ms >= w.start_ms AND s.start_ms < w.end_ms
  GROUP BY w.uuid, s.metric_id, s.source_id)
WHERE rank = 1 OR metric_id = (SELECT id FROM metric WHERE key = 'heart_rate');

CREATE VIEW v_workout_sample AS
SELECT w.uuid AS workout_uuid, m.key AS metric, s.start_ms, s.dur_ms, s.value,
       src.name AS source_name
FROM workout w JOIN sample s ON s.start_ms >= w.start_ms AND s.start_ms < w.end_ms
JOIN metric m ON m.id = s.metric_id JOIN source src ON src.id = s.source_id
JOIN v_workout_source pick ON pick.workout_uuid = w.uuid
 AND pick.metric_id = s.metric_id AND pick.source_id = s.source_id;

CREATE VIEW v_workout_metric AS
SELECT workout_uuid, metric, COUNT(*) AS samples, SUM(value) AS total, AVG(value) AS average,
       MIN(value) AS minimum, MAX(value) AS maximum,
       GROUP_CONCAT(DISTINCT source_name) AS source_name
FROM v_workout_sample GROUP BY workout_uuid, metric;
"""


def build_archive(path: Path) -> None:
    connection = sqlite3.connect(path)
    connection.executescript(SCHEMA)
    connection.execute("INSERT INTO activity_type VALUES (37,'running'), (9,'climbing')")
    connection.execute("INSERT INTO source VALUES (1,'com.apple.health','Watch'), (2,'com.apple.iphone','iPhone'),"
                       " (3,'com.apple.heartratecoordinatord','AirPods')")
    for index, key in enumerate(
        ["heart_rate", "resting_heart_rate", "hrv_sdnn", "sleep_analysis",
         "body_mass", "lean_body_mass", "body_fat_percentage", "vo2_max",
         "running_speed", "running_stride_length", "running_ground_contact_time",
         "distance_walking_running"], start=1
    ):
        connection.execute("INSERT INTO metric VALUES (?,?)", (index, key))

    now_ms = int(connection.execute("SELECT strftime('%s','now')*1000").fetchone()[0])
    day = 86_400_000

    # A run yesterday. Distance comes from the Watch and from the iPhone in the
    # pocket: the same metres twice, so the views must keep only the Watch. Heart
    # rate comes from the Watch and the AirPods, which take turns: both are kept.
    workout_start = now_ms - day
    connection.execute(
        "INSERT INTO workout (uuid, activity_type, start_ms, end_ms, duration_s, distance_m,"
        " energy_kcal, source_name, source_bundle_id, raw) VALUES (X'01', 37, ?, ?, 3600, 12000, 800, 'Watch','a','{}')",
        (workout_start, workout_start + 3_600_000),
    )
    connection.execute(
        "INSERT INTO workout_activity VALUES (X'0A', X'01', 0, ?, ?, 37, 1, 'Ripetuta 1')",
        (workout_start, workout_start + 600_000),
    )
    for offset in range(0, 3_600, 10):
        connection.execute(
            "INSERT INTO sample VALUES (randomblob(16), 1, ?, 0, ?, 1)",
            (workout_start + offset * 1000, 140 + (offset % 40)),
        )
    for offset in range(5, 3_600, 600):
        connection.execute(
            "INSERT INTO sample VALUES (randomblob(16), 1, ?, 0, ?, 3)",
            (workout_start + offset * 1000, 150),
        )
    for offset in range(0, 3_600, 10):
        connection.execute(
            "INSERT INTO sample VALUES (randomblob(16), 12, ?, 0, 33.3, 1)",
            (workout_start + offset * 1000,),
        )
    for offset in range(0, 3_600, 600):
        connection.execute(
            "INSERT INTO sample VALUES (randomblob(16), 12, ?, 0, 2000, 2)",
            (workout_start + offset * 1000,),
        )

    for back in range(1, 40):
        connection.execute(
            "INSERT INTO sample VALUES (randomblob(16), 2, ?, 0, ?, 1)",
            (now_ms - back * day, 47 + (back % 3)),
        )
        connection.execute(
            "INSERT INTO sample VALUES (randomblob(16), 3, ?, 0, ?, 1)",
            (now_ms - back * day, 70 - (back % 5)),
        )
    connection.execute(
        "INSERT INTO category_sample VALUES (randomblob(16), 4, ?, ?, 4, 1)",
        (now_ms - 8 * 3_600_000, 4 * 3_600_000),
    )
    for metric_id, value in [(5, 70.0), (6, 55.0), (7, 0.20), (8, 45.0)]:
        connection.execute(
            "INSERT INTO sample VALUES (randomblob(16), ?, ?, 0, ?, 1)",
            (metric_id, now_ms - 2 * day, value),
        )
    connection.execute(
        "INSERT INTO athlete VALUES (1, ?, 'male', NULL, 70.0, 1.70, ?)",
        (int(946_684_800_000), now_ms),
    )
    connection.execute(
        "INSERT INTO sync_run (device_name, started_ms, finished_ms, upserted, deleted, bytes, status)"
        " VALUES ('iPhone', ?, ?, 10, 0, 100, 'ok')", (now_ms, now_ms))
    connection.commit()
    connection.close()


def call(tool: str, arguments: dict | None = None, db: Path | None = None) -> dict:
    messages = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": tool, "arguments": arguments or {}}},
    ]
    import os
    environment = dict(os.environ)
    if db is not None:
        environment["FITNESS_DATA_DIR"] = str(db.parent)
    result = subprocess.run(
        SERVER_COMMAND, env=environment,
        input="\n".join(json.dumps(m) for m in messages),
        capture_output=True, text=True, timeout=60,
    )
    for line in result.stdout.splitlines():
        message = json.loads(line)
        if message.get("id") == 2:
            return json.loads(message["result"]["content"][0]["text"])
    raise AssertionError(f"no response: {result.stdout} {result.stderr}")


class MCPServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.db = Path(cls.directory.name) / "health.sqlite"
        build_archive(cls.db)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def test_protocol_handshake_and_tool_list(self):
        result = subprocess.run(
            SERVER_COMMAND,
            input='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n'
                  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}\n',
            capture_output=True, text=True, timeout=60,
        )
        lines = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(lines[0]["result"]["serverInfo"]["name"], "fitness-health")
        names = {tool["name"] for tool in lines[1]["result"]["tools"]}
        self.assertIn("training_status", names)
        self.assertIn("write_plan", names)
        for tool in lines[1]["result"]["tools"]:
            self.assertIn("description", tool, tool["name"])
            self.assertIn("inputSchema", tool, tool["name"])

    def test_cli_help_version_and_unknown_option(self):
        for option in ["-h", "--help", "--version"]:
            result = subprocess.run(SERVER_COMMAND + [option], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
        unknown = subprocess.run(SERVER_COMMAND + ["--unknown"], capture_output=True, text=True, timeout=10)
        self.assertEqual(unknown.returncode, 2)

    def test_data_directory_flag_does_not_require_an_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            selected = Path(directory) / "selected"
            message = {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                       "params": {"name": "setup_status", "arguments": {}}}
            result = subprocess.run(SERVER_COMMAND + ["--data-dir", str(selected)],
                                    input=json.dumps(message) + "\n", capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(json.loads(result.stdout)["result"]["content"][0]["text"])
            self.assertFalse(payload["archive_available"])
            self.assertFalse(selected.exists())

    def test_archive_path_with_uri_characters_remains_read_only(self):
        with tempfile.TemporaryDirectory() as directory:
            selected = Path(directory) / "archive?#example"
            selected.mkdir()
            db = selected / "health.sqlite"
            build_archive(db)
            self.assertEqual(call("query", {"sql": "SELECT COUNT(*) AS n FROM workout"}, db=db)[0]["n"], 1)
            self.assertIn("error", call("query", {"sql": "DELETE FROM workout"}, db=db))

    def test_training_status_compares_against_baselines(self):
        status = call("training_status", db=self.db)
        self.assertIsNotNone(status["hrv"])
        self.assertIsNotNone(status["hrv_baseline"])
        # A reading without its baseline is not interpretable, so it must be there.
        self.assertIn("hrv_deviation_pct", status)
        self.assertEqual(status["last_sync"]["status"], "ok")

    def test_athlete_profile_uses_observed_max_heart_rate(self):
        profile = call("athlete_profile", db=self.db)
        self.assertEqual(profile["sex"], "male")
        self.assertAlmostEqual(profile["body_mass_kg"], 70.0, places=1)

        connection = sqlite3.connect(self.db)
        recorded = connection.execute(
            "SELECT MAX(value) FROM sample WHERE metric_id = 1"
        ).fetchone()[0]
        connection.close()

        # The recorded maximum takes precedence over an age-based estimate,
        # because the formula's spread is about a whole zone wide.
        self.assertEqual(profile["max_heart_rate_observed"], round(recorded))
        self.assertNotEqual(profile["max_heart_rate_observed"], 220 - profile["age"])

    def test_workout_detail_drops_the_duplicate_distance_source(self):
        detail = call("workout_detail", db=self.db)
        distance = next(m for m in detail["metrics"] if m["metric"] == "distance_walking_running")
        # The Watch sampled 360 times, the iPhone 6. Only one may survive.
        self.assertEqual(distance["source_name"], "Watch")
        self.assertAlmostEqual(distance["total"], 360 * 33.3, places=0)
        self.assertEqual(len(detail["laps"]), 1)

    def test_workout_detail_merges_heart_rate_sources(self):
        detail = call("workout_detail", db=self.db)
        heart_rate = next(m for m in detail["metrics"] if m["metric"] == "heart_rate")
        # Watch and AirPods take turns: dropping either loses part of the run.
        self.assertEqual(set(heart_rate["source_name"].split(",")), {"Watch", "AirPods"})

    def test_the_athletes_own_zones_replace_the_computed_ones(self):
        zones_file = self.db.parent / "heart-rate-zones.json"
        zones_file.write_text(json.dumps({"Z2": 140, "Z3": 154, "Z4": 169, "Z5": 184}))
        try:
            zones = call("zone_distribution", {"days": 90}, db=self.db)
            profile = call("athlete_profile", db=self.db)
        finally:
            zones_file.unlink()
        self.assertEqual(zones["zone_bounds_from"], "athlete")
        self.assertEqual(zones["zone_bounds_bpm"]["Z2"], "140-153")
        self.assertEqual(zones["zone_bounds_bpm"]["Z5"], ">=184")
        self.assertEqual(profile["heart_rate_zones"]["Z4"], "169-183")

    def test_zone_distribution_sums_to_a_hundred(self):
        zones = call("zone_distribution", {"days": 90}, db=self.db)
        total = sum(zone["percent"] for zone in zones["zones"])
        self.assertAlmostEqual(total, 100, delta=0.5)
        self.assertIn("Z1", zones["zone_bounds_bpm"])

    def test_query_refuses_to_write(self):
        for statement in ["DELETE FROM sample", "drop table workout",
                          "UPDATE plan_entry SET done=1", "PRAGMA journal_mode=DELETE"]:
            result = call("query", {"sql": statement}, db=self.db)
            self.assertIn("error", result, statement)

    def test_query_refuses_a_flood_of_rows(self):
        result = call("query", {"sql": "SELECT * FROM v_sample"}, db=self.db)
        self.assertIn("error", result)
        self.assertIn("too many", result["error"])

    def test_query_reads(self):
        result = call("query", {"sql": "SELECT COUNT(*) AS n FROM workout"}, db=self.db)
        self.assertEqual(result[0]["n"], 1)

    def test_missing_heart_rate_does_not_invent_a_maximum(self):
        with tempfile.TemporaryDirectory() as directory:
            db = Path(directory) / "health.sqlite"
            build_archive(db)
            with sqlite3.connect(db) as connection:
                connection.execute("DELETE FROM sample WHERE metric_id=1")
            result = call("zone_distribution", db=db)
            self.assertIsNone(result["max_heart_rate_used"])
            self.assertEqual(result["zone_bounds_from"], "unavailable")
            self.assertEqual(result["zones"], [])

    def test_setup_protocol_works_before_first_sync(self):
        with tempfile.TemporaryDirectory() as directory:
            db = Path(directory) / "health.sqlite"
            status = call("setup_status", db=db)
            self.assertFalse(status["archive_available"])
            proposal = call("propose_profile", {"profile": {"goals": "Synthetic goal"}}, db=db)
            confirmed = call("confirm_profile", {"proposal_id": proposal["id"], "confirmed": True}, db=db)
            self.assertTrue(confirmed["saved"])
            self.assertEqual(call("setup_status", db=db)["profile"]["goals"], "Synthetic goal")
            self.assertFalse(db.exists())

    def test_write_plan_is_idempotent(self):
        today = datetime.now().strftime("%Y-%m-%d")
        entry = {"day": today, "slot": "long", "title": "LUNGO 12 km",
                 "target": "135-148 bpm"}
        call("write_plan", {"entries": [entry]}, db=self.db)
        call("write_plan", {"entries": [dict(entry, title="LUNGO 14 km")]}, db=self.db)
        plan = call("get_plan", {"days": 30}, db=self.db)
        matching = [item for item in plan if item["day"] == today]
        self.assertEqual(len(matching), 1, "day+slot is the key: rewriting must not duplicate")
        self.assertEqual(matching[0]["title"], "LUNGO 14 km")

    def test_write_plan_rejects_an_incomplete_entry(self):
        result = call("write_plan", {"entries": [{"day": "2026-10-04"}]}, db=self.db)
        self.assertIn("error", result)

    def test_trend_knows_its_metrics(self):
        self.assertIsInstance(call("trend", {"metric": "recovery"}, db=self.db), list)
        unknown = call("trend", {"metric": "nonsense"}, db=self.db)
        self.assertIn("available", unknown[0])

    def test_last_night_is_whole_and_a_nap_does_not_replace_it(self):
        # 23:30 → 07:00 across midnight, plus a nap at 14:00 today. A window of
        # "the last 20 hours" read at 22:00 kept only the part after 02:00.
        from datetime import datetime, time as clock, timedelta

        def ms(moment: datetime) -> int:
            return int(moment.timestamp() * 1000)

        today = datetime.now().date()
        bedtime = datetime.combine(today - timedelta(days=1), clock(23, 30))
        nap = datetime.combine(today, clock(14, 0))
        with tempfile.TemporaryDirectory() as directory:
            db = Path(directory) / "health.sqlite"
            build_archive(db)
            connection = sqlite3.connect(db)
            connection.execute("DELETE FROM category_sample")
            connection.execute(
                "INSERT INTO category_sample VALUES (randomblob(16), 4, ?, ?, 3, 1)",
                (ms(bedtime), 3 * 3_600_000),
            )
            connection.execute(
                "INSERT INTO category_sample VALUES (randomblob(16), 4, ?, ?, 5, 1)",
                (ms(bedtime + timedelta(hours=3)), 4.5 * 3_600_000),
            )
            connection.execute(
                "INSERT INTO category_sample VALUES (randomblob(16), 4, ?, ?, 3, 1)",
                (ms(nap), 3_600_000),
            )
            connection.commit()
            connection.close()
            status = call("training_status", db=db)
        self.assertAlmostEqual(status["sleep_hours"], 7.5, places=1)
        self.assertEqual(status["sleep_onset"], "23:30")
        self.assertEqual(status["sleep_wake"], "07:00")
        self.assertEqual(status["rem_min"], 270)

    def test_the_plan_says_how_much_of_a_run_went_over_its_ceiling(self):
        yesterday = call("query", {"sql": "SELECT date(start_local) AS d FROM v_workout"},
                         db=self.db)[0]["d"]
        call("write_plan", {"entries": [
            {"day": yesterday, "slot": "easy", "title": "FACILE", "target": "130-150 bpm"}
        ]}, db=self.db)
        plan = call("get_plan", {"days": 3}, db=self.db)
        entry = next(item for item in plan if item["day"] == yesterday)
        run = entry["recorded"][0]
        # The Watch cycles 140, 150, 160, 170 (360 samples, half over 150); the
        # AirPods add 6 at 150, inside. 180 of 366 → 49%.
        self.assertEqual(run["pct_above_target"], 49)
        self.assertAlmostEqual(
            run["pct_above_target"] + run["pct_in_target"] + run["pct_below_target"], 100, delta=1
        )

    def test_a_pace_is_never_read_as_a_heart_rate(self):
        from fitness_health.server import heart_rate_range
        self.assertEqual(heart_rate_range("130-150 bpm"), (130, 150))
        self.assertEqual(heart_rate_range("135–148 bpm · 6:15–6:45/km"), (135, 148))
        self.assertIsNone(heart_rate_range("6:15–6:45/km"))
        self.assertIsNone(heart_rate_range("RPE 6"))
        self.assertIsNone(heart_rate_range(None))

    def test_body_assessments_compare_each_method_with_itself(self):
        visit = {
            "date": "2026-01-01", "weight_kg": 65.0,
            "circumferences_cm": {"waist": 78.0, "abdomen": 81.0},
            "skinfolds_mm": {"abdominal": 14.0, "suprailiac": 8.0},
            "skinfold_estimate": {"fat_kg": 7.0}, "bia": {"fat_kg": 14.0},
        }
        later = {
            "date": "2026-04-01", "weight_kg": 70.0,
            "circumferences_cm": {"waist": 80.0, "abdomen": 87.0},
            "skinfolds_mm": {"abdominal": 12.0, "suprailiac": 10.0},
            "skinfold_estimate": {"fat_kg": 6.0}, "bia": {"fat_kg": 17.0},
        }
        path = self.db.parent / "body-assessments.json"
        # Written out of order: the tool sorts by date before comparing.
        path.write_text(json.dumps({"height_cm": 170.0, "visits": [later, visit]}))
        try:
            result = call("body_assessments", db=self.db)
        finally:
            path.unlink()
        self.assertEqual([v["date"] for v in result["visits"]], ["2026-01-01", "2026-04-01"])
        self.assertEqual(result["visits"][0]["skinfold_sum_mm"], 22.0)
        change = result["changes"][0]
        self.assertEqual(change["abdomen_cm"], 6.0)
        self.assertEqual(change["skinfold_sum_mm"], -0.0)
        # The two estimates disagree in sign: they stay apart, never averaged.
        self.assertLess(change["skinfold_fat_kg"], 0)
        self.assertGreater(change["bia_fat_kg"], 0)

    def test_missing_body_assessments_say_how_to_add_them(self):
        result = call("body_assessments", db=self.db)
        self.assertIn("error", result)
        self.assertIn("hint", result)

    def test_labs_separates_never_measured_from_normal(self):
        path = self.db.parent / "labs.json"
        path.write_text(json.dumps({"records": [
            {"date": "2024-01-01", "alt_u_l": 100.0, "platelets_10e6": 200.0, "flagged": {"alt_u_l": "H"}},
            {"date": "2025-01-01", "alt_u_l": 20.0, "platelets_10e6": 180.0},
        ]}))
        try:
            result = call("labs", db=self.db)
        finally:
            path.unlink()
        alt = next(s for s in result["series"] if s["analyte"] == "alt_u_l")
        self.assertEqual([p["value"] for p in alt["points"]], [100.0, 20.0])
        self.assertEqual(alt["points"][0]["flagged"], "H")
        # Reference limits belong to the source report, not a hardcoded threshold.
        self.assertNotIn("alt_peaks_over_uln", result["liver_screening"])
        self.assertIn("ast_u_l", result["liver_screening"]["markers_never_measured"])

    def test_missing_labs_say_how_to_add_them(self):
        result = call("labs", db=self.db)
        self.assertIn("error", result)
        self.assertIn("hint", result)

    def test_a_missing_archive_says_what_to_do(self):
        with tempfile.TemporaryDirectory() as directory:
            result = call("training_status", db=Path(directory) / "absent" / "health.sqlite")
            self.assertIn("error", result)
            self.assertIn("sync", result["error"].lower())


if __name__ == "__main__":
    unittest.main(verbosity=2)
