# FitnessExport

<img src="FitnessExport/Assets.xcassets/Logo.imageset/Logo.png" alt="FitnessExport logo" width="96" height="96">

FitnessExport reads workouts from Apple Health. You can export them as FIT files,
view splits and training trends, or upload them to Garmin Connect and Intervals.icu.
The Mac app stores a local copy of your data, which you can also query through MCP.

## Build

You need Xcode and Tuist to build the app. It runs on iOS/iPadOS 17+ and macOS 15+.
Tested with Xcode 27.2 and Tuist 4.216.7.

```sh
cp .env.example .env
# Set your Apple signing team and unique bundle prefix in .env.
./run.sh sim            # synthetic workouts in the simulator
./run.sh iphone         # connected physical iPhone
./run.sh mac            # menu-bar companion
./run.sh --help
```

`run.sh` loads `.env` and generates the Xcode workspace. Never commit `.env`.
For manual Xcode setup, export those variables and run `tuist generate --no-open`.

## Use

1. In Library, grant Health read access and create the workout index.
2. Select workouts to analyze, export, or upload. Configure upload accounts in Settings.
3. Optional: pair the Mac companion by scanning its QR code from iOS Settings.
4. Choose System, English or Italiano in each app's language settings.

Real Health data and Watch scheduling require a physical device. Garmin's website
integration can require updates when its endpoints change.

## Optional MCP server

Python 3.10+. Install locally in a virtual environment; no runtime dependencies:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install ./mcp
.venv/bin/fitness-health --help
```

Add `.venv/bin/fitness-health` to your MCP client. The [setup guide](docs/personal-setup.md)
covers profiles, heart-rate zones and documents.

## Data

Account credentials are saved in Keychain. Your Mac stores its archive in
`~/Library/Application Support/org.fitnessexport/`. Transfers between paired devices are encrypted.
The archive itself is not encrypted. You choose whether to upload workouts or
connect an MCP client.

[Architecture and development](docs/development.md) · [Synchronization](docs/mac-sync.md) ·
[Archive schema](docs/health-store-reference.md) · [MIT license](LICENSE)
