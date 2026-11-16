# Health store reference

SQLite schema and query examples for the Mac archive.

```
~/Library/Application Support/org.fitnessexport/health.sqlite
```

The database uses WAL mode, so queries can run during synchronization. Open it
read-only when querying it directly.

## Workout totals and samples

A Watch and an iPhone can both record distance during the same run. Adding their
samples would count that distance twice. `v_workout_sample` and `v_workout_metric`
select the source with the most samples for each workout and metric. Heart rate
keeps all sources because Watch and AirPods can alternate during a run.
Use `v_workout_sample_all` to compare sources.

Samples are matched to workouts by time. That window can include everyday
activity recorded during pauses. For workout totals, use `distance_m`,
`energy_kcal` and `duration_s` from `workout`, rather than adding up its samples.

## Tables

| table | one row per | notes |
|---|---|---|
| `sample` | numeric sample | `uuid` PK, `start_ms`, `dur_ms`, `value`, `metric_id`, `source_id` |
| `category_sample` | categorical sample | sleep stages, mindful sessions; `value` is HealthKit's raw enum |
| `workout` | workout | totals from HealthKit, plus full JSON in `raw` |
| `workout_activity` | lap | the steps of a structured session, or one row for a free run |
| `workout_event` | event | pauses, resumes, segments, auto splits |
| `planned_step` | prescribed step | from a WorkoutKit custom workout, when there was one |
| `route_point` | GPS fix | with horizontal/vertical accuracy |
| `athlete` | the athlete (single row) | date of birth, sex, latest mass and height |
| `activity_type` | HKWorkoutActivityType | raw value → readable name |
| `plan_entry` | prescribed session | `day` + `slot` unique; `done`, `rpe`, `note` come back from the dashboard |
| `metric`, `source` | lookup | keep row size down |
| `cursor` | stream | where the last sync got to; do not touch |
| `sync_run` | sync | history of transfers |

Times are integer milliseconds since the epoch. `dur_ms` is a duration, not an
end time — instantaneous samples store 0.

## Views

| view | gives you |
|---|---|
| `v_sample` | every numeric sample with metric key, local time, source name |
| `v_category` | the same for categorical samples |
| `v_workout` | one row per workout with `activity` name, pace, distance, plan name |
| `v_workout_metric` | per workout and metric: `total`, `average`, `minimum`, `maximum`, source disambiguated |
| `v_workout_sample` | samples belonging to a workout, one source per metric |
| `v_workout_sample_all` | every sample in the window, every source |
| `v_workout_source` | which source was picked, and how many samples it had |

## Metric keys

Stable, and the primary key of `metric`. Grouped by what they answer.

**Recovery** — `resting_heart_rate`, `hrv_sdnn`, `respiratory_rate`,
`oxygen_saturation`, `wrist_temperature`, `heart_rate_recovery_1min`,
`walking_heart_rate`

**Sleep** — `sleep_analysis` (category), `sleeping_breathing_disturbances`

**Body** — `body_mass`, `lean_body_mass`, `body_fat_percentage`,
`body_mass_index`, `waist_circumference`, `height`

**Fitness** — `vo2_max`, `six_minute_walk`

**Daily load** — `step_count`, `active_energy`, `basal_energy`, `exercise_time`,
`stand_time`, `flights_climbed`, `time_in_daylight`, `physical_effort`

**During a workout** — `heart_rate`, `distance_walking_running`,
`distance_cycling`, `distance_swimming`, `running_power`, `running_speed`,
`running_stride_length`, `running_vertical_oscillation`,
`running_ground_contact_time`, `cycling_power`, `cycling_speed`,
`cycling_cadence`, `swimming_stroke_count`, `water_temperature`,
`workout_effort`, `estimated_workout_effort`

**Nutrition** — `dietary_energy`, `dietary_water`, `dietary_protein`,
`dietary_carbohydrates`

**Vitals** — `blood_pressure_systolic`, `blood_pressure_diastolic`,
`blood_glucose`, `body_temperature`

A metric with no rows means the athlete has no such device, not that the sync
failed. Check `cursor` to tell the two apart: every stream that ran has a row.

### Sleep stage values

`category_sample.value` for `sleep_analysis`:
`0` in bed · `1` asleep (unspecified) · `2` awake · `3` core · `4` deep · `5` REM

Core plus deep plus REM is time asleep. Do not add `0`: on Apple Watch "in bed"
overlaps the stages.

**Which night a segment belongs to.** Key it by the evening it started:
`date(start_local, '-12 hours')`, so 00:03 belongs to the day before. "Last
night" is the latest key seen in the past 36 hours — never a window counted back
from now: "the last 20 hours" read at 22:00 starts at 02:00 and drops the first
part of the night (7.3 h came out as 4.5 h). Segments starting between 12:00 and
17:59 are naps; leave them out, or an afternoon nap replaces last night.

## Worked queries

```sql
-- Weekly running volume and pace, last 12 weeks
SELECT strftime('%Y-%W', start_local) AS week,
       COUNT(*) AS runs,
       ROUND(SUM(distance_m) / 1000.0, 1) AS km,
       ROUND(AVG(pace_s_per_km) / 60.0, 2) AS pace_min_km
FROM v_workout
WHERE activity = 'running' AND distance_m > 1000
  AND start_epoch > strftime('%s', 'now', '-84 days')
GROUP BY week ORDER BY week;

-- Morning readiness: RHR and HRV against their own 7-day baseline
WITH daily AS (
  SELECT date(start_local) AS day,
         AVG(CASE WHEN metric = 'resting_heart_rate' THEN value END) AS rhr,
         AVG(CASE WHEN metric = 'hrv_sdnn' THEN value END) AS hrv
  FROM v_sample
  WHERE metric IN ('resting_heart_rate', 'hrv_sdnn')
    AND start_epoch > strftime('%s', 'now', '-120 days')
  GROUP BY day
)
SELECT day, ROUND(rhr) AS rhr, ROUND(hrv) AS hrv,
       ROUND(AVG(rhr) OVER (ORDER BY day ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING)) AS rhr_base,
       ROUND(AVG(hrv) OVER (ORDER BY day ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING)) AS hrv_base
FROM daily ORDER BY day DESC LIMIT 21;

-- Sleep last night, by stage (night keyed by its evening, naps left out)
WITH night AS (
  SELECT value, duration_s, date(start_local, '-12 hours') AS night
  FROM v_category
  WHERE metric = 'sleep_analysis'
    AND start_epoch > CAST(strftime('%s', 'now', '-36 hours') AS INTEGER)
    AND CAST(strftime('%H', start_local) AS INT) NOT BETWEEN 12 AND 17
)
SELECT CASE value WHEN 3 THEN 'core' WHEN 4 THEN 'deep' WHEN 5 THEN 'rem'
                  WHEN 2 THEN 'awake' ELSE 'other' END AS stage,
       ROUND(SUM(duration_s) / 60.0) AS minutes
FROM night
WHERE night = (SELECT MAX(night) FROM night)
GROUP BY stage;

-- The laps of the last structured session
SELECT a.idx + 1 AS lap, a.name,
       ROUND((a.end_ms - a.start_ms) / 1000.0) AS seconds
FROM workout_activity a
JOIN workout w ON w.uuid = a.workout_uuid
WHERE w.uuid = (SELECT uuid FROM workout w2
                WHERE (SELECT COUNT(*) FROM workout_activity x
                        WHERE x.workout_uuid = w2.uuid) > 2
                ORDER BY w2.start_ms DESC LIMIT 1)
ORDER BY a.idx;

-- Running form over time: contact time and stride, monthly
SELECT strftime('%Y-%m', w.start_local) AS month,
       ROUND(AVG(CASE WHEN m.metric = 'running_ground_contact_time' THEN m.average END)) AS gct_ms,
       ROUND(AVG(CASE WHEN m.metric = 'running_stride_length' THEN m.average END), 2) AS stride_m,
       ROUND(AVG(CASE WHEN m.metric = 'running_vertical_oscillation' THEN m.average END), 1) AS vo_cm
FROM v_workout w
JOIN v_workout_metric m ON m.workout_uuid = w.uuid
WHERE w.activity = 'running' AND w.distance_m > 3000
GROUP BY month ORDER BY month;

-- Strength and climbing sessions alongside running, by week
SELECT strftime('%Y-%W', start_local) AS week,
       SUM(activity = 'running') AS runs,
       SUM(activity IN ('traditional strength training',
                        'functional strength training', 'core training')) AS strength,
       SUM(activity = 'climbing') AS climbing,
       ROUND(SUM(duration_s) / 3600.0, 1) AS hours
FROM v_workout
WHERE start_epoch > strftime('%s', 'now', '-84 days')
GROUP BY week ORDER BY week;
```

## Freshness

```sql
SELECT datetime(started_ms / 1000, 'unixepoch', 'localtime') AS last_sync,
       upserted, deleted, status
FROM sync_run ORDER BY id DESC LIMIT 1;
```

Check the latest synchronization before interpreting missing data.
