import Foundation

enum TrainingQueries {

    static let todaySQL = """
        WITH asleep AS (
          SELECT c.start_ms, c.start_ms + c.dur_ms AS end_ms, c.value,
                 date(c.start_ms/1000, 'unixepoch', 'localtime', '-12 hours') AS night
          FROM category_sample c
          WHERE c.metric_id = (SELECT id FROM metric WHERE key = 'sleep_analysis')
            AND c.value IN (1,3,4,5)
            AND c.start_ms > CAST(strftime('%s','now','-32 days') AS INTEGER) * 1000
            AND CAST(strftime('%H', c.start_ms/1000, 'unixepoch', 'localtime') AS INT)
                NOT BETWEEN 12 AND 17
        ),
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
        night_hr AS (
          SELECT a.night, AVG(s.value) AS bpm
          FROM asleep a JOIN sample s
            ON s.metric_id = (SELECT id FROM metric WHERE key = 'heart_rate')
           AND s.start_ms >= a.start_ms AND s.start_ms < a.end_ms
          GROUP BY a.night
        ),
        daily AS (
          SELECT date(start_local) AS d,
                 AVG(CASE WHEN metric='resting_heart_rate' THEN value END) AS rhr,
                 AVG(CASE WHEN metric='hrv_sdnn' THEN value END) AS hrv
          FROM v_sample
          WHERE metric IN ('resting_heart_rate','hrv_sdnn')
            AND start_epoch > CAST(strftime('%s','now','-60 days') AS INTEGER)
          GROUP BY d
        ),
        recent AS (SELECT AVG(rhr) AS rhr, AVG(hrv) AS hrv FROM daily WHERE d >= date('now','localtime','-2 days')),
        base AS (SELECT AVG(rhr) AS rhr, AVG(hrv) AS hrv FROM daily WHERE d < date('now','localtime','-2 days')),
        last_session AS (
          SELECT activity, ROUND(duration_s/60.0) AS minutes,
                 ROUND(distance_m/1000.0, 1) AS km,
                 CAST(julianday('now','localtime') - julianday(date(start_local)) AS INT) AS days_ago
          FROM v_workout ORDER BY start_epoch DESC LIMIT 1
        ),
        long_run AS (
          SELECT CAST(julianday('now','localtime') - julianday(date(start_local)) AS INT) AS days_ago,
                 ROUND(distance_m/1000.0, 1) AS km
          FROM v_workout WHERE activity='running' AND distance_m >= 10000
          ORDER BY start_epoch DESC LIMIT 1
        ),
        mass AS (
          SELECT ROUND(value, 1) AS kg, date(start_local) AS on_day
          FROM v_sample WHERE metric='body_mass' ORDER BY start_epoch DESC LIMIT 1
        ),
        lean AS (
          SELECT ROUND(value, 1) AS kg FROM v_sample
          WHERE metric='lean_body_mass' ORDER BY start_epoch DESC LIMIT 1
        ),
        fat AS (
          SELECT ROUND(value*100, 1) AS pct FROM v_sample
          WHERE metric='body_fat_percentage' ORDER BY start_epoch DESC LIMIT 1
        )
        SELECT (SELECT hours FROM sleep) AS sleep_hours,
               (SELECT deep_min FROM sleep) AS deep_min,
               (SELECT rem_min FROM sleep) AS rem_min,
               (SELECT onset FROM sleep) AS sleep_onset,
               (SELECT wake FROM sleep) AS sleep_wake,
               ROUND((SELECT bpm FROM night_hr WHERE night = (SELECT night FROM last_night)), 1) AS sleep_hr,
               ROUND((SELECT AVG(bpm) FROM night_hr WHERE night < (SELECT night FROM last_night)), 1) AS sleep_hr_base,
               ROUND((SELECT rhr FROM recent), 1) AS rhr,
               ROUND((SELECT rhr FROM base), 1) AS rhr_base,
               ROUND((SELECT hrv FROM recent), 1) AS hrv,
               ROUND((SELECT hrv FROM base), 1) AS hrv_base,
               (SELECT activity FROM last_session) AS last_activity,
               (SELECT minutes FROM last_session) AS last_minutes,
               (SELECT km FROM last_session) AS last_km,
               (SELECT days_ago FROM last_session) AS last_days_ago,
               (SELECT days_ago FROM long_run) AS long_days_ago,
               (SELECT km FROM long_run) AS long_km,
               (SELECT kg FROM mass) AS mass_kg,
               (SELECT on_day FROM mass) AS mass_day,
               (SELECT kg FROM lean) AS lean_kg,
               (SELECT pct FROM fat) AS fat_pct,
               (SELECT MAX(started_ms) FROM sync_run) AS last_sync_ms
        """

    static let weekSQL = """
        SELECT date(start_local) AS day,
               CASE CAST(strftime('%w', start_local) AS INT)
                    WHEN 1 THEN 'lun' WHEN 2 THEN 'mar' WHEN 3 THEN 'mer' WHEN 4 THEN 'gio'
                    WHEN 5 THEN 'ven' WHEN 6 THEN 'sab' ELSE 'dom' END AS weekday,
               activity,
               ROUND(duration_s/60.0) AS minutes,
               ROUND(distance_m/1000.0, 2) AS km,
               CASE WHEN pace_s_per_km IS NOT NULL
                    THEN printf('%d:%02d', CAST(pace_s_per_km/60 AS INT),
                                CAST(pace_s_per_km % 60 AS INT)) END AS pace,
               plan_name,
               (SELECT ROUND(AVG(s.value)) FROM workout w JOIN sample s
                  ON s.metric_id = (SELECT id FROM metric WHERE key = 'heart_rate')
                 AND s.start_ms >= w.start_ms AND s.start_ms < w.end_ms
                WHERE w.uuid = v_workout.uuid) AS avg_hr
        FROM v_workout
        WHERE start_epoch > CAST(strftime('%s','now','-7 days') AS INTEGER)
        ORDER BY start_epoch DESC
        """

    static let planSQL = """
        SELECT day, slot, title, detail, target, done, rpe, note
        FROM plan_entry
        WHERE day >= date('now','localtime','-1 day') AND day <= date('now','localtime','+8 days')
        ORDER BY day, slot
        """

    static let volumeSQL = """
        SELECT strftime('%Y-W%W', start_local) AS week,
               ROUND(SUM(CASE WHEN activity='running' THEN distance_m END)/1000.0, 1) AS km,
               SUM(activity='running') AS runs,
               SUM(activity IN ('traditional strength training','functional strength training',
                                'core training')) AS strength,
               SUM(activity='climbing') AS climbing,
               ROUND(SUM(duration_s)/3600.0, 1) AS hours
        FROM v_workout
        WHERE start_epoch > CAST(strftime('%s','now','-84 days') AS INTEGER)
        GROUP BY week ORDER BY week
        """

    static let recoverySQL = """
        SELECT date(start_local) AS day,
               ROUND(AVG(CASE WHEN metric='resting_heart_rate' THEN value END), 1) AS rhr,
               ROUND(AVG(CASE WHEN metric='hrv_sdnn' THEN value END), 1) AS hrv
        FROM v_sample
        WHERE metric IN ('resting_heart_rate','hrv_sdnn')
          AND start_epoch > CAST(strftime('%s','now','-45 days') AS INTEGER)
        GROUP BY day ORDER BY day
        """

    static let sleepSQL = """
        SELECT date(start_local, '-12 hours') AS night,
               ROUND(SUM(CASE WHEN value IN (1,3,4,5) THEN duration_s END)/3600.0, 1) AS hours
        FROM v_category
        WHERE metric = 'sleep_analysis'
          AND start_epoch > CAST(strftime('%s','now','-31 days') AS INTEGER)
        GROUP BY night HAVING hours > 0 ORDER BY night
        """

    static let bodySQL = """
        SELECT date(start_local) AS day,
               ROUND(AVG(CASE WHEN metric='body_mass' THEN value END), 1) AS mass,
               ROUND(AVG(CASE WHEN metric='lean_body_mass' THEN value END), 1) AS lean,
               ROUND(AVG(CASE WHEN metric='body_fat_percentage' THEN value END)*100, 1) AS fat
        FROM v_sample
        WHERE metric IN ('body_mass','lean_body_mass','body_fat_percentage')
          AND start_epoch > CAST(strftime('%s','now','-550 days') AS INTEGER)
        GROUP BY day HAVING mass IS NOT NULL ORDER BY day
        """

    static let fitnessSQL = """
        SELECT strftime('%Y-%m', start_local) AS month,
               ROUND(AVG(value), 1) AS vo2max,
               COUNT(*) AS samples
        FROM v_sample
        WHERE metric = 'vo2_max'
          AND start_epoch > CAST(strftime('%s','now','-730 days') AS INTEGER)
        GROUP BY month ORDER BY month
        """

    static let formSQL = """
        WITH per_run AS (
          SELECT strftime('%Y-%m', w.start_local) AS month, w.uuid,
                 MAX(CASE WHEN m.metric='running_speed' THEN m.average END) AS speed,
                 MAX(CASE WHEN m.metric='heart_rate' THEN m.average END) AS hr,
                 MAX(CASE WHEN m.metric='running_ground_contact_time' THEN m.average END) AS gct,
                 MAX(CASE WHEN m.metric='running_stride_length' THEN m.average END) AS stride
          FROM v_workout w JOIN v_workout_metric m ON m.workout_uuid = w.uuid
          WHERE w.activity='running' AND w.distance_m > 3000 AND w.duration_s > 900
          GROUP BY w.uuid
        )
        SELECT month, COUNT(*) AS runs,
               ROUND(AVG(speed), 2) AS speed,
               ROUND(AVG(hr)) AS hr,
               ROUND(AVG(speed/hr)*1000, 2) AS efficiency,
               ROUND(AVG(speed/stride*60)) AS cadence,
               ROUND(AVG(gct)) AS gct
        FROM per_run
        WHERE speed IS NOT NULL AND hr IS NOT NULL AND stride IS NOT NULL
        GROUP BY month ORDER BY month
        """
}
