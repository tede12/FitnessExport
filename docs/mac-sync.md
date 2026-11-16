# iPhone-to-Mac synchronization

The iOS app reads HealthKit and transfers records to the Mac companion's local
SQLite archive:

```text
Apple Watch → HealthKit (iPhone) → FitnessExport iOS
                                          │ TLS-PSK over TCP
                                          ▼
                              FitnessExportMac menu-bar app
                                          │
                                          ▼
           ~/Library/Application Support/org.fitnessexport/health.sqlite
```

## Ownership and recovery

The iPhone opens the connection; the Mac requests missing data. Each stream's
cursor lives on the Mac and advances in the same SQLite transaction as its
records. Acknowledgements are sent after commit. If a connection fails before
commit, the next sync requests the same batch. UUID-based upserts make replay
idempotent and support deletion propagation.

## Pairing and authentication

Pair once using the QR code:

1. The Mac generates a random 32-byte pairing key and uses it as the initial TLS PSK.
2. The phone scans the QR code and sends its Ed25519 signing key and X25519 agreement key.
3. Both peers derive the same session key through X25519 and HKDF-SHA256.
4. Both save pairing material in Keychain; the one-time QR key is discarded.

Subsequent syncs authenticate through TLS-PSK and a fresh signed challenge:

```text
iPhone → connect using the session key
Mac    → authChallenge(nonce)
iPhone → authResponse(Ed25519 signature)
Mac    → authenticated
iPhone → ready(catalog)
Mac    → syncRequest(cursors)
iPhone → batch(header) + payload
Mac    → batchAck(sequence), after database commit
iPhone → finished(summary)
Mac    → completed
```

The nonce prevents authentication replay. Up to four batches can be in flight.
A failed stream retains its previous cursor without blocking other streams.
The public companion listens on port 7445, which is included in the QR payload.

## Encoding and bounded reads

Samples use columnar encoding followed by LZFSE compression. Homogeneous columns
allow delta encoding of timestamps and values. Floating-point values are scaled
to integers only when every value round-trips exactly; otherwise their original
64-bit representation is preserved. GPS precision is not reduced.

HealthKit reads use paginated `HKAnchoredObjectQuery` calls: 10,000 records per
page, or 5,000 for high-frequency metrics. The next page can be read while the
current page is transmitted. Do not set `updateHandler` on these one-shot queries:
repeated callbacks would resume the same continuation more than once.

## Archive

The SQLite database uses WAL mode so readers can query during synchronization.
Tables include `sample`, `category_sample`, `workout`, `workout_activity`,
`workout_event`, `planned_step`, `route_point`, `athlete`, `activity_type`,
`metric`, `source`, `cursor` and `sync_run`. Full workout JSON is retained in
`workout.raw` alongside indexed fields.

See [the archive reference](health-store-reference.md) for schema details and
query examples.

```sql
-- Average running pace by month.
SELECT strftime('%Y-%m', start_local) AS month,
       COUNT(*) AS runs,
       ROUND(AVG(pace_s_per_km) / 60, 2) AS pace_min_km
FROM v_workout
WHERE activity_type = 37 AND distance_m > 3000
GROUP BY month ORDER BY month;

-- Resting heart rate and HRV over the last 30 days.
SELECT date(start_local) AS day,
       ROUND(AVG(CASE WHEN metric = 'resting_heart_rate' THEN value END), 0) AS resting_hr,
       ROUND(AVG(CASE WHEN metric = 'hrv_sdnn' THEN value END), 0) AS hrv
FROM v_sample
WHERE metric IN ('resting_heart_rate', 'hrv_sdnn')
  AND start_epoch > CAST(strftime('%s', 'now', '-30 days') AS INTEGER)
GROUP BY day ORDER BY day DESC;
```

## Aggregation rules

Different devices can record the same distance. Adding their samples would count
that distance more than once. `v_workout_sample` and `v_workout_metric` select the
source with the most samples for each workout/metric pair. Heart rate keeps all
sources because Watch and AirPods can alternate during a workout.
`v_workout_sample_all` retains every source for comparisons.

Samples are associated with workouts by time interval. Pauses can therefore
include additional everyday activity samples. Use `workout.distance_m` as the
authoritative workout distance rather than summing all samples in its interval.

## Limitations

- One phone can be served per listening port: the TLS PSK is selected when the
  listener opens, rather than separately for each accepted connection.
- Sync is manual. Automatic HealthKit background delivery would require an
  observer query and the corresponding background-delivery entitlement.
- Workout/sample association is temporal rather than an explicit HealthKit link.
- The peers need network reachability. The host prefers a Tailscale address when
  available, otherwise a local address. Remote access is not provided by a hosted service.
