# Development

The Xcode project is generated from `Project.swift`:

| Target | Responsibility |
| --- | --- |
| `FitnessExport` | iOS app and HealthKit access |
| `FitnessExportMac` | Mac companion and SQLite archive |
| `FitnessSyncKit` | Pairing, transport and codecs |
| `FitnessUI` | Shared views, charts and localization |

## Open in Xcode

After configuring `.env` as described in the README:

```sh
set -a
source .env
set +a
tuist generate --no-open
open FitnessExport.xcworkspace
```

`set -a` exports the variables loaded from `.env`. Select the iOS or Mac app scheme.

## Tests

```sh
./run.sh test
python3 -m unittest discover -s Scripts -p 'test_*.py'
```

Use `./run.sh test <ios|mac|kit|mcp>` for a single suite.

Tests use generated workout data and mock uploads. Check HealthKit permissions,
camera pairing, Watch scheduling and Keychain access on a physical device.
