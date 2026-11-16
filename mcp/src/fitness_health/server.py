#!/usr/bin/env python3
"""Local stdio MCP tools for aggregate Health queries and confirmed personal setup."""

from __future__ import annotations

import argparse
import json
import os
from . import __version__
from .personal_setup import PersonalSetup
import re
import sqlite3
import sys
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Callable

DB_PATH = Path(os.environ.get("FITNESS_DATA_DIR", str(Path.home() / "Library/Application Support/org.fitnessexport"))) / "health.sqlite"
personal_setup = PersonalSetup(DB_PATH.parent)
PROFILE_PATH = DB_PATH.parent / "athlete-profile.md"
# Legacy personal-zone file: lower bpm bounds for Z2 through Z5.
ZONES_PATH = DB_PATH.parent / "heart-rate-zones.json"
# Visits measured outside Health (skinfolds, tape, a clinic's bioimpedance).
# Private health records: they live next to the archive, never in the repository.
ASSESSMENTS_PATH = DB_PATH.parent / "body-assessments.json"
# Optional legacy laboratory series, stored outside the repository.
LABS_PATH = DB_PATH.parent / "labs.json"

# Optional markers: absence never implies a normal result.
LIVER_MARKERS = ("ast_u_l", "ggt_u_l", "insulin_u_ml", "hba1c_pct", "ldl_mg_dl")

PROTOCOL_VERSION = "2024-11-05"
SERVER_INFO = {"name": "fitness-health", "version": __version__}

# Reject write operations in the SQL query tool.
FORBIDDEN_SQL = (
    "insert", "update", "delete", "drop", "alter", "create", "replace",
    "attach", "detach", "pragma", "vacuum", "reindex",
)


# ── Database ────────────────────────────────────────────────────────────────

def connect(writable: bool = False) -> sqlite3.Connection:
    if not DB_PATH.exists():
        raise FileNotFoundError(
            f"No archive at {DB_PATH}. Open the Mac companion and sync from the iPhone."
        )
    uri = DB_PATH.resolve().as_uri() + f"?mode={'rw' if writable else 'ro'}"
    connection = sqlite3.connect(uri, uri=True, timeout=10)
    connection.row_factory = sqlite3.Row
    return connection


def rows(sql: str, params: tuple = (), writable: bool = False) -> list[dict]:
    with connect(writable) as connection:
        return [dict(row) for row in connection.execute(sql, params).fetchall()]


def one(sql: str, params: tuple = ()) -> dict:
    result = rows(sql, params)
    return result[0] if result else {}


def since_clause(days: int) -> str:
    """Cast SQLite TEXT epochs before comparing them with numeric timestamps."""
    return f"CAST(strftime('%s','now','-{int(days)} days') AS INTEGER)"


# ── Tools ───────────────────────────────────────────────────────────────────

def _asleep_cte(days: int) -> str:
    """Group overnight sleep by date(start - 12h), excluding afternoon naps.

    Use the latest recorded night within 36 hours and compute its mean heart rate."""
    return f"""
        asleep AS (
          SELECT c.start_ms, c.start_ms + c.dur_ms AS end_ms, c.value,
                 date(c.start_ms/1000, 'unixepoch', 'localtime', '-12 hours') AS night
          FROM category_sample c
          WHERE c.metric_id = (SELECT id FROM metric WHERE key = 'sleep_analysis')
            AND c.value IN (1,3,4,5)
            AND c.start_ms > {since_clause(days)} * 1000
            AND CAST(strftime('%H', c.start_ms/1000, 'unixepoch', 'localtime') AS INT)
                NOT BETWEEN 12 AND 17
        ),
        night_hr AS (
          SELECT a.night, AVG(s.value) AS bpm
          FROM asleep a JOIN sample s
            ON s.metric_id = (SELECT id FROM metric WHERE key = 'heart_rate')
           AND s.start_ms >= a.start_ms AND s.start_ms < a.end_ms
          GROUP BY a.night
        )"""


def tool_training_status(_: dict) -> dict:
    """Summarize recovery, recent activity and the current plan."""
    status = one(f"""
        WITH {_asleep_cte(32)},
        last_night AS (
          SELECT MAX(night) AS night FROM asleep
          WHERE start_ms > CAST(strftime('%s','now','-36 hours') AS INTEGER) * 1000
        ),
        sleep AS (
          SELECT ROUND(SUM(end_ms - start_ms)/3600000.0, 1) AS hours,
                 ROUND(SUM(CASE WHEN value = 4 THEN end_ms - start_ms END)/60000.0) AS deep_min,
                 ROUND(SUM(CASE WHEN value = 5 THEN end_ms - start_ms END)/60000.0) AS rem_min,
                 strftime('%H:%M', MIN(start_ms)/1000, 'unixepoch', 'localtime') AS onset,
                 strftime('%H:%M', MAX(end_ms)/1000, 'unixepoch', 'localtime') AS wake
          FROM asleep WHERE night = (SELECT night FROM last_night)
        ),
        daily AS (
          SELECT date(start_local) AS d,
                 AVG(CASE WHEN metric='resting_heart_rate' THEN value END) AS rhr,
                 AVG(CASE WHEN metric='hrv_sdnn' THEN value END) AS hrv
          FROM v_sample WHERE metric IN ('resting_heart_rate','hrv_sdnn')
            AND start_epoch > {since_clause(60)}
          GROUP BY d
        )
        SELECT (SELECT hours FROM sleep) AS sleep_hours,
               (SELECT deep_min FROM sleep) AS deep_min,
               (SELECT rem_min FROM sleep) AS rem_min,
               (SELECT onset FROM sleep) AS sleep_onset,
               (SELECT wake FROM sleep) AS sleep_wake,
               ROUND((SELECT bpm FROM night_hr WHERE night = (SELECT night FROM last_night)),1)
                 AS sleeping_hr,
               ROUND((SELECT AVG(bpm) FROM night_hr WHERE night < (SELECT night FROM last_night)),1)
                 AS sleeping_hr_baseline,
               ROUND((SELECT AVG(hrv) FROM daily WHERE d >= date('now','localtime','-2 days')),1) AS hrv,
               ROUND((SELECT AVG(hrv) FROM daily WHERE d <  date('now','localtime','-2 days')),1) AS hrv_baseline,
               ROUND((SELECT AVG(rhr) FROM daily WHERE d >= date('now','localtime','-2 days')),1) AS resting_hr,
               ROUND((SELECT AVG(rhr) FROM daily WHERE d <  date('now','localtime','-2 days')),1) AS resting_hr_baseline
    """)

    if status.get("hrv") and status.get("hrv_baseline"):
        status["hrv_deviation_pct"] = round(
            (status["hrv"] - status["hrv_baseline"]) / status["hrv_baseline"] * 100, 1
        )

    status["last_sync"] = one(
        "SELECT datetime(started_ms/1000,'unixepoch','localtime') AS at, upserted, status"
        " FROM sync_run ORDER BY id DESC LIMIT 1"
    )
    status["last_session"] = one(f"""
        SELECT date(start_local) AS day, activity, ROUND(duration_s/60.0) AS minutes,
               ROUND(distance_m/1000.0,1) AS km,
               CAST(julianday('now','localtime') - julianday(date(start_local)) AS INT) AS days_ago
        FROM v_workout ORDER BY start_epoch DESC LIMIT 1
    """)
    status["last_long_run"] = one("""
        SELECT date(start_local) AS day, ROUND(distance_m/1000.0,1) AS km,
               CAST(julianday('now','localtime') - julianday(date(start_local)) AS INT) AS days_ago
        FROM v_workout WHERE activity='running' AND distance_m >= 10000
        ORDER BY start_epoch DESC LIMIT 1
    """)
    status["plan_today"] = rows(
        "SELECT slot, title, target, done FROM plan_entry"
        " WHERE day = date('now','localtime') ORDER BY slot"
    )
    status["week_so_far"] = one(f"""
        SELECT COUNT(*) AS sessions,
               ROUND(SUM(CASE WHEN activity='running' THEN distance_m END)/1000.0,1) AS running_km,
               SUM(activity IN ('traditional strength training','functional strength training',
                                'core training')) AS strength_sessions
        FROM v_workout WHERE start_epoch > {since_clause(7)}
    """)
    return status


def tool_athlete_profile(_: dict) -> dict:
    """Return Health demographics, personal context and heart-rate zones."""
    profile = one("""
        SELECT biological_sex AS sex,
               date(date_of_birth_ms/1000,'unixepoch') AS date_of_birth,
               CAST((julianday('now') - julianday(date(date_of_birth_ms/1000,'unixepoch')))/365.25 AS INT) AS age,
               ROUND(body_mass_kg,1) AS body_mass_kg,
               ROUND(height_m,2) AS height_m
        FROM athlete LIMIT 1
    """)
    latest = one("""
        SELECT ROUND(MAX(CASE WHEN metric='lean_body_mass' THEN value END),1) AS lean_mass_kg,
               ROUND(MAX(CASE WHEN metric='body_fat_percentage' THEN value END)*100,1) AS body_fat_pct
        FROM v_sample
        WHERE metric IN ('lean_body_mass','body_fat_percentage')
          AND start_epoch > CAST(strftime('%s','now','-120 days') AS INTEGER)
    """)
    profile.update({k: v for k, v in latest.items() if v is not None})

    profile["max_heart_rate_observed"] = one(f"""
        SELECT ROUND(MAX(value)) AS bpm FROM v_sample
        WHERE metric='heart_rate' AND start_epoch > {since_clause(365)}
    """).get("bpm")

    cuts, origin = _zone_cuts()
    profile["heart_rate_zones"] = {**_zone_bounds(cuts), "from": origin}

    context = personal_setup.status({})["profile"]
    profile["personal_context"] = context
    if context:
        profile["notes"] = "Personal context is configured; see personal_context."
    elif PROFILE_PATH.exists():
        profile["notes"] = PROFILE_PATH.read_text(encoding="utf-8")
    else:
        profile["notes"] = f"No profile file at {PROFILE_PATH}. Ask the athlete for goals and constraints."
    return profile


def tool_list_workouts(args: dict) -> list[dict]:
    """List recent workouts with a bounded result size."""
    days = int(args.get("days", 30))
    activity = args.get("activity")
    limit = min(int(args.get("limit", 40)), 200)
    where = [f"start_epoch > {since_clause(days)}"]
    params: list[Any] = []
    if activity:
        where.append("activity = ?")
        params.append(activity)
    return rows(f"""
        SELECT date(start_local) AS day,
               CASE CAST(strftime('%w', start_local) AS INT)
                    WHEN 1 THEN 'mon' WHEN 2 THEN 'tue' WHEN 3 THEN 'wed' WHEN 4 THEN 'thu'
                    WHEN 5 THEN 'fri' WHEN 6 THEN 'sat' ELSE 'sun' END AS weekday,
               activity, ROUND(duration_s/60.0) AS minutes,
               ROUND(distance_m/1000.0,2) AS km,
               CASE WHEN pace_s_per_km IS NOT NULL
                    THEN printf('%d:%02d', CAST(pace_s_per_km/60 AS INT),
                                CAST(pace_s_per_km % 60 AS INT)) END AS pace_per_km,
               plan_name,
               (SELECT COUNT(*) FROM workout_activity a WHERE a.workout_uuid = v.uuid) AS laps
        FROM v_workout v
        WHERE {' AND '.join(where)}
        ORDER BY start_epoch DESC LIMIT {limit}
    """, tuple(params))


def tool_workout_detail(args: dict) -> dict:
    """One session, fully: totals, per-metric averages, laps, heart-rate zones."""
    day = args.get("day")
    where = "date(w.start_local) = ?" if day else "1=1"
    params = (day,) if day else ()
    workout = one(f"""
        SELECT w.uuid, date(w.start_local) AS day,
               datetime(w.start_local) AS started, w.activity,
               ROUND(w.duration_s/60.0,1) AS minutes, ROUND(w.distance_m/1000.0,2) AS km,
               CASE WHEN w.pace_s_per_km IS NOT NULL
                    THEN printf('%d:%02d', CAST(w.pace_s_per_km/60 AS INT),
                                CAST(w.pace_s_per_km % 60 AS INT)) END AS pace_per_km,
               w.energy_kcal, w.plan_name, w.device_name
        FROM v_workout w WHERE {where} ORDER BY w.start_epoch DESC LIMIT 1
    """, params)
    if not workout:
        return {"error": "No workout found" + (f" on {day}" if day else "")}

    uuid = workout.pop("uuid")
    workout["metrics"] = rows("""
        SELECT metric, ROUND(average,2) AS average, ROUND(minimum,2) AS minimum,
               ROUND(maximum,2) AS maximum, ROUND(total,1) AS total, source_name
        FROM v_workout_metric WHERE workout_uuid = ? ORDER BY metric
    """, (uuid,))
    workout["laps"] = rows("""
        SELECT idx + 1 AS lap, name,
               ROUND((end_ms - start_ms)/1000.0) AS seconds
        FROM workout_activity WHERE workout_uuid = ? ORDER BY idx
    """, (uuid,))
    workout["planned_steps"] = rows("""
        SELECT idx + 1 AS step, role, goal_kind, goal_value, alert
        FROM planned_step WHERE workout_uuid = ? ORDER BY idx
    """, (uuid,))
    workout["heart_rate_zones"] = _zones_for(uuid)
    return workout


def _max_heart_rate() -> float | None:
    observed = one(f"""
        SELECT ROUND(MAX(value)) AS bpm FROM v_sample
        WHERE metric='heart_rate' AND start_epoch > {since_clause(365)}
    """).get("bpm")
    return float(observed) if observed else None


def _zone_cuts() -> tuple[list[int], str]:
    """Return personal or observed-maximum zone boundaries with their provenance."""
    configured = personal_setup.status({})["profile"].get("zones")
    if configured:
        return [configured[z] for z in ("Z2", "Z3", "Z4", "Z5")], "athlete"
    if ZONES_PATH.exists():
        zones = json.loads(ZONES_PATH.read_text(encoding="utf-8"))
        return [int(zones[z]) for z in ("Z2", "Z3", "Z4", "Z5")], "athlete"
    maximum = _max_heart_rate()
    if maximum is None:
        return [], "unavailable"
    return [round(maximum * b) for b in (0.6, 0.7, 0.8, 0.9)], "observed max"


def _zone_bounds(cuts: list[int]) -> dict:
    if not cuts:
        return {}
    return {
        "Z1": f"<{cuts[0]}", "Z2": f"{cuts[0]}-{cuts[1]-1}", "Z3": f"{cuts[1]}-{cuts[2]-1}",
        "Z4": f"{cuts[2]}-{cuts[3]-1}", "Z5": f">={cuts[3]}",
    }


def _zones_for(uuid: str | None = None, days: int | None = None) -> list[dict]:
    """Time in zone as a share of samples."""
    cuts, _ = _zone_cuts()
    if not cuts:
        return []
    if uuid:
        where, params = "s.workout_uuid = ?", (uuid,)
        table = "v_workout_sample s"
    else:
        where = f"w.activity='running' AND w.start_epoch > {since_clause(days or 56)}"
        params = ()
        table = "v_workout_sample s JOIN v_workout w ON w.uuid = s.workout_uuid"
    result = rows(f"""
        SELECT CASE WHEN s.value < {cuts[0]} THEN 'Z1'
                    WHEN s.value < {cuts[1]} THEN 'Z2'
                    WHEN s.value < {cuts[2]} THEN 'Z3'
                    WHEN s.value < {cuts[3]} THEN 'Z4'
                    ELSE 'Z5' END AS zone,
               COUNT(*) AS samples
        FROM {table}
        WHERE s.metric='heart_rate' AND {where}
        GROUP BY zone ORDER BY zone
    """, params)
    total = sum(row["samples"] for row in result) or 1
    for row in result:
        row["percent"] = round(row["samples"] / total * 100, 1)
    return result


def tool_zone_distribution(args: dict) -> dict:
    days = int(args.get("days", 56))
    maximum = _max_heart_rate()
    cuts, origin = _zone_cuts()
    zones = _zones_for(days=days)
    easy = sum(z["percent"] for z in zones if z["zone"] in ("Z1", "Z2"))
    hard = sum(z["percent"] for z in zones if z["zone"] in ("Z4", "Z5"))
    return {
        "days": days,
        "max_heart_rate_used": maximum,
        "zone_bounds_bpm": _zone_bounds(cuts),
        "zone_bounds_from": origin,
        "zones": zones,
        "easy_percent": round(easy, 1),
        "hard_percent": round(hard, 1),
        "note": "No heart-rate zones available." if not cuts else "Personal zones take precedence; estimates based on observed maximum are not physiological thresholds.",
    }


def tool_trend(args: dict) -> list[dict]:
    """Monthly or weekly trend for one thing. Aggregated in SQL, not in context."""
    metric = args.get("metric", "volume")
    months = int(args.get("months", 6))
    days = months * 31

    if metric == "volume":
        return rows(f"""
            SELECT strftime('%Y-W%W', start_local) AS period,
                   ROUND(SUM(CASE WHEN activity='running' THEN distance_m END)/1000.0,1) AS running_km,
                   SUM(activity='running') AS runs,
                   SUM(activity IN ('traditional strength training','functional strength training',
                                    'core training')) AS strength,
                   SUM(activity='climbing') AS climbing,
                   ROUND(SUM(duration_s)/3600.0,1) AS hours
            FROM v_workout WHERE start_epoch > {since_clause(days)}
            GROUP BY period ORDER BY period
        """)
    if metric == "form":
        return rows("""
            WITH per_run AS (
              SELECT strftime('%Y-%m', w.start_local) AS month, w.uuid,
                     MAX(CASE WHEN m.metric='running_speed' THEN m.average END) AS speed,
                     MAX(CASE WHEN m.metric='heart_rate' THEN m.average END) AS hr,
                     MAX(CASE WHEN m.metric='running_ground_contact_time' THEN m.average END) AS gct,
                     MAX(CASE WHEN m.metric='running_stride_length' THEN m.average END) AS stride
              FROM v_workout w JOIN v_workout_metric m ON m.workout_uuid = w.uuid
              WHERE w.activity='running' AND w.distance_m > 3000 AND w.duration_s > 900
              GROUP BY w.uuid)
            SELECT month, COUNT(*) AS runs, ROUND(AVG(speed),2) AS speed_ms,
                   ROUND(AVG(hr)) AS heart_rate,
                   ROUND(AVG(speed/hr)*1000,2) AS efficiency,
                   ROUND(AVG(speed/stride*60)) AS cadence_spm,
                   ROUND(AVG(gct)) AS ground_contact_ms
            FROM per_run WHERE speed IS NOT NULL AND hr IS NOT NULL AND stride IS NOT NULL
            GROUP BY month ORDER BY month
        """)
    if metric == "recovery":
        return rows(f"""
            SELECT date(start_local) AS day,
                   ROUND(AVG(CASE WHEN metric='resting_heart_rate' THEN value END),1) AS resting_hr,
                   ROUND(AVG(CASE WHEN metric='hrv_sdnn' THEN value END),1) AS hrv
            FROM v_sample WHERE metric IN ('resting_heart_rate','hrv_sdnn')
              AND start_epoch > {since_clause(min(days, 90))}
            GROUP BY day ORDER BY day
        """)
    if metric == "sleep":
        # Heart-rate averages include only recorded sleep segments.
        return rows(f"""
            WITH {_asleep_cte(min(days, 90))}
            SELECT a.night,
                   ROUND(SUM(a.end_ms - a.start_ms)/3600000.0, 1) AS hours,
                   ROUND(SUM(CASE WHEN a.value = 4 THEN a.end_ms - a.start_ms END)/60000.0) AS deep_min,
                   ROUND(SUM(CASE WHEN a.value = 5 THEN a.end_ms - a.start_ms END)/60000.0) AS rem_min,
                   strftime('%H:%M', MIN(a.start_ms)/1000, 'unixepoch', 'localtime') AS onset,
                   strftime('%H:%M', MAX(a.end_ms)/1000, 'unixepoch', 'localtime') AS wake,
                   ROUND((SELECT bpm FROM night_hr h WHERE h.night = a.night), 1) AS sleeping_hr
            FROM asleep a GROUP BY a.night ORDER BY a.night
        """)
    if metric == "body":

        return rows(f"""
            SELECT date(start_local) AS day,
                   ROUND(AVG(CASE WHEN metric='body_mass' THEN value END),1) AS mass_kg,
                   ROUND(AVG(CASE WHEN metric='lean_body_mass' THEN value END),1) AS lean_kg,
                   ROUND(AVG(CASE WHEN metric='body_fat_percentage' THEN value END)*100,1) AS fat_pct,
                   ROUND(AVG(CASE WHEN metric='body_mass' THEN value END)
                         * AVG(CASE WHEN metric='body_fat_percentage' THEN value END),1) AS fat_kg,
                   ROUND(AVG(CASE WHEN metric='waist_circumference' THEN value END),1) AS waist_cm
            FROM v_sample
            WHERE metric IN ('body_mass','lean_body_mass','body_fat_percentage','waist_circumference')
              AND start_epoch > {since_clause(days)}
            GROUP BY day HAVING mass_kg IS NOT NULL OR waist_cm IS NOT NULL ORDER BY day
        """)
    if metric == "vo2max":
        return rows(f"""
            SELECT strftime('%Y-%m', start_local) AS month,
                   ROUND(AVG(value),1) AS vo2max, COUNT(*) AS samples
            FROM v_sample WHERE metric='vo2_max' AND start_epoch > {since_clause(days)}
            GROUP BY month ORDER BY month
        """)
    return [{"error": f"Unknown metric '{metric}'",
             "available": ["volume", "form", "recovery", "sleep", "body", "vo2max"]}]


def tool_body_assessments(_: dict) -> dict:
    """Compare external body assessments within each measurement method."""
    if not ASSESSMENTS_PATH.exists():
        return {"error": f"No assessments at {ASSESSMENTS_PATH}.",
                "hint": "Send the PDFs of a visit and they will be transcribed there."}
    data = json.loads(ASSESSMENTS_PATH.read_text(encoding="utf-8"))
    height = data.get("height_cm")

    def summary(visit: dict) -> dict:
        tape = visit.get("circumferences_cm", {})
        folds = visit.get("skinfolds_mm", {})
        estimate = visit.get("skinfold_estimate", {})
        bia = visit.get("bia", {})
        return {
            "date": visit["date"],
            "context": visit.get("context"),
            "weight_kg": visit.get("weight_kg"),
            "waist_cm": tape.get("waist"),
            "abdomen_cm": tape.get("abdomen"),
            "hips_cm": tape.get("hips"),
            "abdomen_to_height": round(tape["abdomen"] / height, 3)
                if height and tape.get("abdomen") else None,
            "skinfold_sum_mm": round(sum(folds.values()), 1) if folds else None,
            "abdominal_skinfold_mm": folds.get("abdominal"),
            "suprailiac_skinfold_mm": folds.get("suprailiac"),
            "arm_muscle_area_cm2": estimate.get("arm_muscle_area_cm2"),
            "thigh_muscle_area_cm2": estimate.get("thigh_muscle_area_cm2"),
            "skinfold_fat_kg": estimate.get("fat_kg"),
            "bia_fat_kg": bia.get("fat_kg"),
            "bia_ffm_kg": bia.get("ffm_kg"),
            "phase_angle_deg": bia.get("phase_angle_deg"),
            "ecw_tbw_pct": bia.get("ecw_tbw_pct"),
        }

    visits = [summary(v) for v in sorted(data.get("visits", []), key=lambda v: v["date"])]
    compared = [k for k in visits[0] if k not in ("date", "context")] if visits else []
    changes = []
    for before, after in zip(visits, visits[1:]):
        delta = {"from": before["date"], "to": after["date"]}
        for key in compared:
            if isinstance(before[key], (int, float)) and isinstance(after[key], (int, float)):
                delta[key] = round(after[key] - before[key], 2)
        changes.append(delta)
    return {
        "about": data.get("about"),
        "known": data.get("known"),
        "visits": visits,
        "changes": changes,
        "full_record": str(ASSESSMENTS_PATH),
    }


UNITS = {
    "alt_u_l": "U/L", "ast_u_l": "U/L", "ggt_u_l": "U/L",
    "glucose_mg_dl": "mg/dL", "hba1c_pct": "%", "insulin_u_ml": "uU/mL",
    "creatinine_mg_dl": "mg/dL", "total_protein_g_dl": "g/dL",
    "total_cholesterol_mg_dl": "mg/dL", "hdl_mg_dl": "mg/dL",
    "ldl_mg_dl": "mg/dL", "triglycerides_mg_dl": "mg/dL", "ferritin_ng_ml": "ng/mL",
    "hemoglobin_g_dl": "g/dL", "hct_pct": "%", "platelets_10e6": "x10e6/ml",
    "wbc_10e6": "x10e6/ml", "mcv_fl": "fL", "mch_pg": "pg", "mchc_g_dl": "g/dL",
    "mpv_fl": "fL", "weight_kg": "kg", "height_cm": "cm", "bmi": "kg/m2",
    "resting_hr_bpm": "bpm", "hr_max_bpm": "bpm",
    "urine_specific_gravity": "", "urine_ph": "",
    "rbc_10e9": "x10e9/ml", "rdw_pct": "%", "non_hdl_mg_dl": "mg/dL", "alp_u_l": "U/L",
    "ck_u_l": "U/L", "crp_mg_dl": "mg/dL", "albumin_g_dl": "g/dL", "gamma_globulin_g_dl": "g/dL",
    "neutrophils_10e6": "x10e6/ml", "lymphocytes_10e6": "x10e6/ml", "monocytes_10e6": "x10e6/ml",
    "eosinophils_10e6": "x10e6/ml", "basophils_10e6": "x10e6/ml", "fecal_calprotectin_mg_kg": "mg/kg",
}


def tool_labs(_: dict) -> dict:
    """Read laboratory series; missing measurements are not normal results."""
    if not LABS_PATH.exists():
        return {"error": f"No labs at {LABS_PATH}.",
                "hint": "Use setup_status, explicitly import selected reports, and review extracted measurements before confirming a profile."}
    data = json.loads(LABS_PATH.read_text(encoding="utf-8"))
    records = sorted(data.get("records", []), key=lambda r: r["date"])


    keys: dict[str, dict] = {}
    for r in records:
        for key, value in r.items():
            if not isinstance(value, (int, float)) or isinstance(value, bool):
                continue
            series = keys.setdefault(key, {"analyte": key, "unit": UNITS.get(key, ""), "points": []})
            point = {"date": r["date"], "value": value}
            if r.get("flagged", {}).get(key):
                point["flagged"] = r["flagged"][key]
            series["points"].append(point)

    never_measured = [m for m in LIVER_MARKERS if m not in keys]

    return {
        "caveats": data.get("caveats"),
        "records": records,
        "series": [keys[k] for k in sorted(keys)],
        "liver_screening": {
            "markers_never_measured": never_measured,
            "note": "Absent above means never tested, not normal. FIB-4 needs AST; "
                    "with ALT alone it cannot be computed and was not.",
        },
        "full_record": str(LABS_PATH),
    }


def tool_load_balance(args: dict) -> dict:
    """Estimate acute/chronic load from duration and relative heart-rate intensity."""
    days = int(args.get("days", 60))
    maximum = _max_heart_rate()
    if maximum is None:
        return {"error": "No observed maximum heart rate. Load estimate unavailable."}
    daily = rows(f"""
        SELECT date(w.start_local) AS day,
               ROUND(SUM(w.duration_s/60.0 *
                   CASE WHEN m.average IS NULL THEN 1.0
                        ELSE POWER(m.average / {maximum}, 2) * 2.2 END), 1) AS load
        FROM v_workout w
        LEFT JOIN v_workout_metric m
               ON m.workout_uuid = w.uuid AND m.metric = 'heart_rate'
        WHERE w.start_epoch > {since_clause(days)}
        GROUP BY day ORDER BY day
    """)
    by_day = {row["day"]: row["load"] or 0 for row in daily}

    def window_mean(span: int) -> float:
        today = datetime.now().date()
        values = [
            by_day.get((today - timedelta(days=offset)).isoformat(), 0)
            for offset in range(span)
        ]
        return round(sum(values) / span, 1)

    acute, chronic = window_mean(7), window_mean(42)
    ratio = round(acute / chronic, 2) if chronic else None
    return {
        "acute_7d": acute,
        "chronic_42d": chronic,
        "ratio": ratio,
        "reading": (
            "no history yet" if not chronic
            else "detraining" if ratio < 0.8
            else "steady" if ratio <= 1.3
            else "ramping fast — watch recovery markers"
        ),
        "daily": daily[-21:],
        "note": "Load is duration weighted by intensity relative to observed max HR "
                f"({maximum:.0f} bpm), not a validated TSS.",
    }


def tool_best_efforts(args: dict) -> list[dict]:
    """Aggregate fastest whole sessions by distance band and month."""
    months = int(args.get("months", 12))
    return rows(f"""
        SELECT band, month, ROUND(km,1) AS km,
               printf('%d:%02d', CAST(pace/60 AS INT), CAST(pace % 60 AS INT)) AS pace_per_km,
               day
        FROM (
          SELECT CASE WHEN distance_m < 5000 THEN '3-5 km'
                      WHEN distance_m < 10000 THEN '5-10 km'
                      WHEN distance_m < 15000 THEN '10-15 km'
                      ELSE '15+ km' END AS band,
                 strftime('%Y-%m', start_local) AS month,
                 distance_m/1000.0 AS km, pace_s_per_km AS pace,
                 date(start_local) AS day,
                 ROW_NUMBER() OVER (
                   PARTITION BY strftime('%Y-%m', start_local),
                     CASE WHEN distance_m < 5000 THEN '3-5 km'
                          WHEN distance_m < 10000 THEN '5-10 km'
                          WHEN distance_m < 15000 THEN '10-15 km'
                          ELSE '15+ km' END
                   ORDER BY pace_s_per_km
                 ) AS rank
          FROM v_workout
          WHERE activity='running' AND distance_m >= 3000 AND pace_s_per_km IS NOT NULL
            AND start_epoch > {since_clause(months * 31)}
        ) WHERE rank = 1 ORDER BY band, month
    """)


def heart_rate_range(target: str | None) -> tuple[int, int] | None:
    """Extract an increasing pair of values between 90 and 220 bpm from a target."""
    if not target:
        return None
    numbers = [int(n) for n in re.findall(r"\d+", target) if 90 <= int(n) <= 220]
    if len(numbers) >= 2 and numbers[0] < numbers[1]:
        return numbers[0], numbers[1]
    return None


def tool_get_plan(args: dict) -> list[dict]:
    """Return planned sessions, completion and recorded heart-rate target adherence."""
    days = int(args.get("days", 14))
    plan = rows(f"""
        SELECT day, slot, title, detail, target, done, rpe, note
        FROM plan_entry
        WHERE day >= date('now','localtime','-{days} days')
          AND day <= date('now','localtime','+14 days')
        ORDER BY day, slot
    """)
    today = datetime.now().date().isoformat()
    for entry in plan:
        if entry["day"] > today:
            continue
        adherence = ""
        if bounds := heart_rate_range(entry.get("target")):
            low, high = bounds
            adherence = (
                f", ROUND(100.0 * SUM(s.value > {high}) / COUNT(s.value)) AS pct_above_target"
                f", ROUND(100.0 * SUM(s.value BETWEEN {low} AND {high}) / COUNT(s.value)) AS pct_in_target"
                f", ROUND(100.0 * SUM(s.value < {low}) / COUNT(s.value)) AS pct_below_target"
            )
        entry["recorded"] = rows(f"""
            SELECT v.activity, time(v.start_local) AS started,
                   ROUND(v.duration_s/60.0) AS minutes, ROUND(v.distance_m/1000.0,2) AS km,
                   ROUND(AVG(s.value)) AS avg_hr {adherence}
            FROM v_workout v
            JOIN workout w ON w.uuid = v.uuid
            LEFT JOIN sample s
              ON s.metric_id = (SELECT id FROM metric WHERE key = 'heart_rate')
             AND s.start_ms >= w.start_ms AND s.start_ms < w.end_ms
            WHERE date(v.start_local) = ?
            GROUP BY v.uuid ORDER BY v.start_epoch
        """, (entry["day"],))
    return plan


def tool_write_plan(args: dict) -> dict:
    """Upsert planned sessions by day and slot without editing recorded Health data."""
    entries = args.get("entries") or []
    if not entries:
        return {"error": "No entries given."}
    written = 0
    with connect(writable=True) as connection:
        for entry in entries:
            if not entry.get("day") or not entry.get("slot") or not entry.get("title"):
                return {"error": "Each entry needs at least day, slot and title."}
            connection.execute("""
                INSERT INTO plan_entry (day, slot, title, detail, target, done, updated_ms)
                VALUES (?, ?, ?, ?, ?, 0, CAST(strftime('%s','now') AS INTEGER) * 1000)
                ON CONFLICT(day, slot) DO UPDATE SET
                    title = excluded.title, detail = excluded.detail,
                    target = excluded.target, updated_ms = excluded.updated_ms
            """, (
                entry["day"], entry["slot"], entry["title"],
                entry.get("detail"), entry.get("target"),
            ))
            written += 1
        connection.commit()
    return {
        "written": written,
        "note": "The iPhone picks this up at the next sync; the Mac window shows it now.",
    }


def tool_query(args: dict) -> list[dict] | dict:
    """Run a read-only query with a 200-row limit."""
    sql = (args.get("sql") or "").strip()
    if not sql:
        return {"error": "No SQL given."}
    lowered = sql.lower()
    if any(word in lowered.split() or f"{word} " in lowered for word in FORBIDDEN_SQL):
        return {"error": "This tool is read-only. Use write_plan to change the plan."}
    if ";" in sql.rstrip(";"):
        return {"error": "One statement at a time."}
    try:
        with connect() as connection:
            result = [dict(row) for row in connection.execute(sql.rstrip(";")).fetchmany(201)]
    except sqlite3.Error as error:
        return {"error": str(error)}
    if len(result) > 200:
        return {
            "error": f"{len(result)} rows is too many to read. Aggregate in SQL "
                     "(GROUP BY, AVG, LIMIT) — that is what the database is for."
        }
    return result


TOOLS: dict[str, tuple[Callable[[dict], Any], dict]] = {
    "training_status": (tool_training_status, {
        "description": "Sleep, HRV and resting heart rate against personal baselines, recent sessions, today's plan and this week's totals.",
        "inputSchema": {"type": "object", "properties": {}},
    }),
    "athlete_profile": (tool_athlete_profile, {
        "description": "Health measurements, observed maximum heart rate, goals and weekly availability.",
        "inputSchema": {"type": "object", "properties": {}},
    }),
    "list_workouts": (tool_list_workouts, {
        "description": "Recent sessions, one compact row each.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "days": {"type": "integer", "description": "How far back (default 30)."},
                "activity": {"type": "string", "description": "e.g. running, climbing."},
                "limit": {"type": "integer", "description": "Max rows (default 40, cap 200)."},
            },
        },
    }),
    "workout_detail": (tool_workout_detail, {
        "description": "Workout totals, source-resolved metrics, laps, planned steps and heart-rate zones.",
        "inputSchema": {
            "type": "object",
            "properties": {"day": {"type": "string", "description": "yyyy-mm-dd; omit for the latest."}},
        },
    }),
    "zone_distribution": (tool_zone_distribution, {
        "description": "Running time by heart-rate zone. Uses personal zones when available, otherwise estimates from observed maximum heart rate.",
        "inputSchema": {
            "type": "object",
            "properties": {"days": {"type": "integer", "description": "Window (default 56)."}},
        },
    }),
    "trend": (tool_trend, {
        "description": "Training and health measurements grouped by week or month.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "metric": {
                    "type": "string",
                    "enum": ["volume", "form", "recovery", "sleep", "body", "vo2max"],
                },
                "months": {"type": "integer", "description": "How far back (default 6)."},
            },
            "required": ["metric"],
        },
    }),
    "body_assessments": (tool_body_assessments, {
        "description": "Body measurements recorded outside Health, with changes compared within each measurement method.",
        "inputSchema": {"type": "object", "properties": {}},
    }),
    "labs": (tool_labs, {
        "description": "Lab results grouped by analyte, with recorded flags and missing screening markers. Missing results are unknown, not normal.",
        "inputSchema": {"type": "object", "properties": {}},
    }),
    "load_balance": (tool_load_balance, {
        "description": "Approximate training load over 7 days and 42 days, with their ratio.",
        "inputSchema": {
            "type": "object",
            "properties": {"days": {"type": "integer", "description": "History to read (default 60)."}},
        },
    }),
    "best_efforts": (tool_best_efforts, {
        "description": "Fastest whole sessions by distance band and month.",
        "inputSchema": {
            "type": "object",
            "properties": {"months": {"type": "integer", "description": "Default 12."}},
        },
    }),
    "get_plan": (tool_get_plan, {
        "description": "Planned sessions, completion and RPE. Past sessions include recorded heart rate and time above, within or below a bpm target.",
        "inputSchema": {
            "type": "object",
            "properties": {"days": {"type": "integer", "description": "How far back (default 14)."}},
        },
    }),
    "write_plan": (tool_write_plan, {
        "description": "Create or update sessions by day and slot. Slots: coach, strength, long, easy, rest.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "entries": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "day": {"type": "string", "description": "yyyy-mm-dd"},
                            "slot": {"type": "string"},
                            "title": {"type": "string"},
                            "detail": {"type": "string"},
                            "target": {
                                "type": "string",
                                "description": "The one number that matters, e.g. '135-148 bpm'. "
                                               "A heart-rate range here becomes a Watch alert.",
                            },
                        },
                        "required": ["day", "slot", "title"],
                    },
                }
            },
            "required": ["entries"],
        },
    }),
    "query": (tool_query, {
        "description": "Read-only SQL against the archive, for questions the other tools do not "
                       "cover. Views: v_sample, v_category, v_workout, v_workout_metric, "
                       "v_workout_sample. Aggregate in SQL; more than 200 rows is refused.",
        "inputSchema": {
            "type": "object",
            "properties": {"sql": {"type": "string"}},
            "required": ["sql"],
        },
    }),
}


TOOLS.update(personal_setup.tools())

# ── JSON-RPC ────────────────────────────────────────────────────────────────

def respond(message_id: Any, result: Any = None, error: dict | None = None) -> None:
    payload: dict[str, Any] = {"jsonrpc": "2.0", "id": message_id}
    if error is not None:
        payload["error"] = error
    else:
        payload["result"] = result
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


def handle(message: dict) -> None:
    method = message.get("method")
    message_id = message.get("id")

    # Notifications carry no id and expect no answer.
    if message_id is None:
        return

    if method == "initialize":
        respond(message_id, {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {}},
            "serverInfo": SERVER_INFO,
        })
    elif method == "ping":
        respond(message_id, {})
    elif method == "tools/list":
        respond(message_id, {
            "tools": [
                {"name": name, **schema} for name, (_, schema) in TOOLS.items()
            ]
        })
    elif method == "tools/call":
        params = message.get("params") or {}
        name = params.get("name")
        entry = TOOLS.get(name)
        if entry is None:
            respond(message_id, error={"code": -32601, "message": f"Unknown tool: {name}"})
            return
        function, _ = entry
        try:
            result = function(params.get("arguments") or {})
            respond(message_id, {
                "content": [{"type": "text", "text": json.dumps(result, ensure_ascii=False, indent=2)}]
            })
        except Exception as error:
            respond(message_id, {
                "content": [{"type": "text", "text": json.dumps({"error": str(error)})}],
                "isError": True,
            })
    else:
        respond(message_id, error={"code": -32601, "message": f"Unknown method: {method}"})


def configure_storage(directory: Path) -> None:
    global DB_PATH, PROFILE_PATH, ZONES_PATH, ASSESSMENTS_PATH, LABS_PATH, personal_setup
    directory = directory.expanduser().resolve()
    DB_PATH = directory / "health.sqlite"
    PROFILE_PATH = directory / "athlete-profile.md"
    ZONES_PATH = directory / "heart-rate-zones.json"
    ASSESSMENTS_PATH = directory / "body-assessments.json"
    LABS_PATH = directory / "labs.json"
    personal_setup = PersonalSetup(directory)
    TOOLS.update(personal_setup.tools())


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    parser.add_argument("--data-dir", type=Path, help="Local archive directory (default: FITNESS_DATA_DIR or application storage)")
    args = parser.parse_args()
    if args.data_dir is not None:
        configure_storage(args.data_dir)
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        handle(message)


if __name__ == "__main__":
    main()
