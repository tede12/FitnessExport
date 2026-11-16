#!/usr/bin/env bash
# Build, test and run FitnessExport from this checkout.
set -euo pipefail
cd "$(dirname "$0")"
if [ -f .env ]; then
  set -a
  source ./.env
  set +a
fi

VERSION="1.0.0"
WORKSPACE="FitnessExport.xcworkspace"
IOS_SCHEME="FitnessExport"
IOS_APP_NAME="FitnessExport"
IOS_BUNDLE_ID="${FITNESS_BUNDLE_PREFIX:-org.fitnessexport}.FitnessExport"
MAC_SCHEME="FitnessExportMac"
MAC_APP_NAME="FitnessExportMac"
MAC_BUNDLE_ID="${FITNESS_BUNDLE_PREFIX:-org.fitnessexport}.FitnessExportMac"
KIT_SCHEME="FitnessSyncKit"
UI_SCHEME="FitnessUI"
DERIVED_DATA=".derivedData"
APPLICATIONS_DIR="${APPLICATIONS_DIR:-$HOME/Applications/FitnessExport}"
DATA_DIR="$HOME/Library/Application Support/org.fitnessexport"
DB_PATH="$DATA_DIR/health.sqlite"
SIM_DEVICE="${FITNESS_SIM_DEVICE:-iPhone 17 Pro}"
# Keychain services the two apps use for pairing material.
KEYCHAIN_SERVICES=(
  "org.fitnessexport.sync.devices"
  "org.fitnessexport.sync.host"
  "org.fitnessexport.sync.identity"
  "org.fitnessexport.sync.hosts"
)
# Register the current build with LaunchServices.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

# ── colours / output helpers ────────────────────────────────────────────────
# Honor NO_COLOR for terminal output.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; D=$'\033[2m'; R=$'\033[31m'; G=$'\033[32m'
  Y=$'\033[33m'; BL=$'\033[34m'; C=$'\033[36m'; X=$'\033[0m'
else
  B=; D=; R=; G=; Y=; BL=; C=; X=
fi
step() { printf "%s▸%s %s\n"  "$BL" "$X" "$*"; }
ok()   { printf "%s✓%s %s\n"  "$G"  "$X" "$*"; }
warn() { printf "%s!%s %s\n"  "$Y"  "$X" "$*"; }
err()  { printf "%s✗%s %s\n"  "$R"  "$X" "$*" >&2; }
info() { printf "%s   %s%s\n" "$D"  "$*" "$X"; }
hr()   { printf "%s%s%s\n" "$D" "────────────────────────────────────────────" "$X"; }

ASSUME_YES=0
confirm() {
  [ "$ASSUME_YES" = "1" ] && return 0
  local reply
  printf "%s?%s %s %s[y/N]%s " "$Y" "$X" "$1" "$D" "$X"
  read -r reply || true
  [[ "$reply" =~ ^[Yy]$ ]]
}

# Pipe a build through xcbeautify when available, otherwise keep the lines worth reading.
prettify() {
  if command -v xcbeautify >/dev/null; then
    xcbeautify
  else
    grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)|Executed [0-9]+ test" || true
  fi
}

# Regenerate targets after source files change.
ensure_generated() {
  if ! command -v tuist >/dev/null; then
    [ -d "$WORKSPACE" ] || { err "Tuist is missing and $WORKSPACE isn't generated."; exit 1; }
    return 0
  fi
  step "Generating Xcode project (tuist generate)…"
  tuist generate --no-open >/dev/null
}

# ── macOS companion ─────────────────────────────────────────────────────────
# Process matching requires absolute executable paths.
mac_app_path() { printf "%s/%s/Build/Products/%s/%s.app" "$PWD" "$DERIVED_DATA" "${1:-Debug}" "$MAC_APP_NAME"; }

# Match executable paths owned by this checkout or its private install directory.
mac_pids() {
  local pid executable
  for pid in $(pgrep -x "$MAC_APP_NAME" || true); do
    executable="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
    case "$executable" in
      "$PWD/$DERIVED_DATA/"*|"$APPLICATIONS_DIR/$MAC_APP_NAME.app/"*) printf '%s\n' "$pid" ;;
    esac
  done
}

mac_running() { [ -n "$(mac_pids)" ]; }

quit_mac() {
  local pid n=0
  for pid in $(mac_pids); do kill -TERM "$pid"; done
  while mac_running && [ "$n" -lt 25 ]; do sleep 0.2; n=$((n + 1)); done
  if mac_running; then
    err "Companion is still running; close it before rebuilding."
    exit 1
  fi
}

purge_mac() {
  local app; app="$(mac_app_path "${1:-Debug}")"
  # `|| return 0`, not `&&`: under `set -e` a false `[ -d ] && {…}` returns 1
  # and silently kills the script when there is no previous build.
  [ -d "$app" ] || return 0
  step "Removing previous build: $app"
  rm -rf "$app"
}

register_product() { [ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$1" >/dev/null 2>&1 || true; }

mac_running_exec() {
  local pid; pid="$(mac_pids | head -1)" || true
  [ -n "$pid" ] && ps -p "$pid" -o comm= 2>/dev/null || true
}

build_mac() {
  local config="${1:-Debug}"
  ensure_generated
  step "Building the macOS companion ($config)…"
  if ! xcodebuild build -workspace "$WORKSPACE" -scheme "$MAC_SCHEME" \
        -configuration "$config" -destination 'platform=macOS' \
        -derivedDataPath "$DERIVED_DATA" 2>&1 | prettify; then
    err "macOS build failed."
    exit 1
  fi
  ok "macOS build succeeded."
}

install_mac() {
  local config="${1:-Release}" src
  src="$(mac_app_path "$config")"
  [ -d "$src" ] || { err "Not built yet: $src"; exit 1; }
  INSTALLED_APP_PATH="$APPLICATIONS_DIR/$MAC_APP_NAME.app"
  mkdir -p "$APPLICATIONS_DIR"
  step "Installing → $INSTALLED_APP_PATH"
  if ! rm -rf "$INSTALLED_APP_PATH" 2>/dev/null || ! cp -R "$src" "$INSTALLED_APP_PATH" 2>/dev/null; then
    err "Could not write to $APPLICATIONS_DIR (permission denied?)."
    info "Retry with sudo, or pick a writable dir: APPLICATIONS_DIR=\"\$HOME/Applications\" ./run.sh mac --release"
    exit 1
  fi
  register_product "$INSTALLED_APP_PATH"
  ok "Installed $MAC_APP_NAME.app in $APPLICATIONS_DIR."
}

launch_mac() {
  local config="${1:-Debug}" app
  app="${2:-$(mac_app_path "$config")}"
  [ -d "$app" ] || { err "Not built yet: $app"; info "Try: ./run.sh mac"; exit 1; }

  step "Launching: $app"
  register_product "$app"
  open "$app"
  sleep 2

  # Confirm macOS launched THIS bundle, not a stale registered copy.
  local run_exec; run_exec="$(mac_running_exec)"
  case "$run_exec" in
    "$app"/*) : ;;
    *)
      warn "Launched instance isn't the fresh build — retrying."
      quit_mac; register_product "$app"; open "$app"; sleep 2
      run_exec="$(mac_running_exec)"
      ;;
  esac

  case "$run_exec" in
    "$app"/*)
      ok "$MAC_APP_NAME running (PID $(mac_pids | head -1))."
      info "Look for the ECG icon in the menu bar, then choose “Associa iPhone…”." ;;
    "") err "$MAC_APP_NAME didn't start — check Console.app."; exit 1 ;;
    *)  err "A stale $MAC_APP_NAME is running, not the fresh build."; exit 1 ;;
  esac
}

# ── iOS on a physical device ────────────────────────────────────────────────
UDID_RE='[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}'

# UDID of the wanted physical device (by name or UDID), else the first iPhone found.
device_udid() {
  local wanted="${1:-}" json udid
  json="$(mktemp)"
  xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1 \
    || { rm -f "$json"; err "devicectl is unavailable: Xcode 15+ required."; exit 1; }
  udid="$(python3 - "$json" "$wanted" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
wanted = sys.argv[2]
for device in data.get("result", {}).get("devices", []):
    hardware = device.get("hardwareProperties", {})
    properties = device.get("deviceProperties", {})
    if hardware.get("reality") == "simulated":
        continue
    if hardware.get("platform") not in ("iOS", None):
        continue
    udid = hardware.get("udid", "")
    name = properties.get("name", "")
    if wanted and wanted not in (udid, name):
        continue
    print(udid)
    break
PY
)"
  rm -f "$json"
  printf '%s' "$udid"
}

cmd_iphone() {
  local wanted="${1:-}" udid
  udid="$(device_udid "$wanted")"
  if [ -z "$udid" ]; then
    err "No physical iPhone found${wanted:+ matching '$wanted'}."
    info "Connect it, unlock it, trust this computer, and enable Developer Mode"
    info "(Settings ▸ Privacy & Security ▸ Developer Mode)."
    info "List devices: xcrun devicectl list devices"
    exit 1
  fi
  step "Device: $udid"

  ensure_generated
  step "Building the iOS app ($CONFIG) for the device…"
  if ! xcodebuild build -workspace "$WORKSPACE" -scheme "$IOS_SCHEME" \
        -configuration "$CONFIG" -destination "platform=iOS,id=$udid" \
        -derivedDataPath "$DERIVED_DATA" \
        -allowProvisioningUpdates -allowProvisioningDeviceRegistration 2>&1 | prettify; then
    err "iOS build failed."
    exit 1
  fi

  local app="$DERIVED_DATA/Build/Products/$CONFIG-iphoneos/$IOS_APP_NAME.app"
  [ -d "$app" ] || { err "Built app not found: $app"; exit 1; }

  step "Installing on the device…"
  xcrun devicectl device install app --device "$udid" "$app" >/dev/null

  step "Launching ${IOS_BUNDLE_ID}…"
  xcrun devicectl device process launch --device "$udid" --terminate-existing "$IOS_BUNDLE_ID" >/dev/null
  ok "Installed and running on the iPhone."
  info "Open Impostazioni ▸ Mac to pair it with the companion."
}

cmd_devices() {
  step "Connected devices:"
  xcrun devicectl list devices 2>/dev/null | sed "s/^/   ${D}/;s/\$/${X}/"
  info "Pick one with: ./run.sh iphone \"Example iPhone\""
}

# ── iOS on a Simulator ──────────────────────────────────────────────────────
sim_udid() {
  local udid
  udid="$(xcrun simctl list devices available | grep -F "$SIM_DEVICE (" \
          | grep -Eo "$UDID_RE" | head -1)"
  if [ -z "$udid" ]; then
    udid="$(xcrun simctl list devices available | grep -E 'iPhone' \
            | grep -Eo "$UDID_RE" | head -1)"
  fi
  printf '%s' "$udid"
}

boot_sim() {
  local udid="$1"
  open -a Simulator >/dev/null 2>&1 || true
  step "Booting the Simulator ($SIM_DEVICE)…"
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 \
    || xcrun simctl boot "$udid" >/dev/null 2>&1 || true
}

cmd_sim() {
  local udid; udid="$(sim_udid)"
  [ -n "$udid" ] || { err "No iOS Simulator found."; info "Install one: Xcode ▸ Settings ▸ Components."; exit 1; }

  ensure_generated
  step "Building the iOS app for the Simulator…"
  if ! xcodebuild build -workspace "$WORKSPACE" -scheme "$IOS_SCHEME" \
        -configuration Debug -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "$DERIVED_DATA" 2>&1 | prettify; then
    err "Simulator build failed."
    exit 1
  fi

  boot_sim "$udid"
  local app="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/$IOS_APP_NAME.app"
  [ -d "$app" ] || { err "Built app not found: $app"; exit 1; }

  step "Installing and launching on ${SIM_DEVICE}…"
  xcrun simctl install "$udid" "$app"
  xcrun simctl launch "$udid" "$IOS_BUNDLE_ID" -ui-testing >/dev/null 2>&1
  ok "Running on $SIM_DEVICE ($udid)."
  # Simulator runs explicitly use synthetic fixtures.
  info "Health data is synthetic here — pair with the Mac from a real iPhone."
}

cmd_sims() {
  step "Available simulators:"
  xcrun simctl list devices available | grep -E 'iPhone|iPad' \
    | sed "s/^[[:space:]]*/   ${D}/;s/\$/${X}/"
  info "Choose one with: FITNESS_SIM_DEVICE=\"iPhone 17\" ./run.sh sim"
}

# ── build only ──────────────────────────────────────────────────────────────

build_ios_simulator() {
  ensure_generated
  step "Building the iOS app (${CONFIG}, Simulator)…"
  if ! xcodebuild build -workspace "$WORKSPACE" -scheme "$IOS_SCHEME" \
        -configuration "$CONFIG" -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "$DERIVED_DATA" 2>&1 | prettify; then
    err "iOS build failed."; exit 1
  fi
  ok "iOS build succeeded."
}

build_kit() {
  ensure_generated
  step "Building the shared frameworks (${CONFIG})…"
  local scheme
  for scheme in "$KIT_SCHEME" "$UI_SCHEME"; do
    if ! xcodebuild build -workspace "$WORKSPACE" -scheme "$scheme" \
          -configuration "$CONFIG" -destination 'platform=macOS' \
          -derivedDataPath "$DERIVED_DATA" 2>&1 | prettify; then
      err "$scheme build failed."; exit 1
    fi
  done
  ok "Frameworks built."
}

cmd_build() {
  case "${1:-all}" in
    mac)  build_mac "$CONFIG"; info "$(mac_app_path "$CONFIG")" ;;
    ios)  build_ios_simulator ;;
    kit)  build_kit ;;
    all)  build_kit; build_mac "$CONFIG"; build_ios_simulator
          ok "Everything builds." ;;
    *)    err "Unknown target: $1"; info "Use: mac | ios | kit | all"; exit 1 ;;
  esac
}

# ── tests ───────────────────────────────────────────────────────────────────
run_suite() {
  local name="$1"; shift
  step "Testing ${name}…"
  if ! xcodebuild test "$@" -derivedDataPath "$DERIVED_DATA" 2>&1 | prettify; then
    err "$name tests failed."
    exit 1
  fi
}

cmd_test() {
  local target="${1:-all}"
  if [ "$target" != "mcp" ]; then ensure_generated; fi
  case "$target" in
    kit)
      run_suite "FitnessSyncKit" -workspace "$WORKSPACE" -scheme "$KIT_SCHEME" -destination 'platform=macOS' ;;
    mac)
      run_suite "the macOS companion" -workspace "$WORKSPACE" -scheme "$MAC_SCHEME" -destination 'platform=macOS' ;;
    ios)
      run_suite "the iOS app" -workspace "$WORKSPACE" -scheme "$IOS_SCHEME" \
        -destination "platform=iOS Simulator,name=$SIM_DEVICE" -only-testing:FitnessExportTests ;;
    mcp)
      step "Testing the MCP server…"
      PYTHONPATH="$PWD/mcp/src${PYTHONPATH:+:$PYTHONPATH}" python3 -m unittest discover -s mcp/tests || { err "MCP tests failed."; exit 1; } ;;
    all)
      cmd_test kit; cmd_test mac; cmd_test ios; cmd_test mcp ;;
    *)
      err "Unknown suite: $target"; info "Use: kit | mac | ios | mcp | all"; exit 1 ;;
  esac
  ok "$target tests passed."
}

# ── the local store ─────────────────────────────────────────────────────────
cmd_db() {
  [ -f "$DB_PATH" ] || { warn "No store yet: $DB_PATH"; info "Launch the companion once: ./run.sh mac"; return 0; }

  # Anything after `db` is run as SQL, so quick questions don't need a client.
  local sql="${1:-}"
  if [ -n "$sql" ]; then
    sqlite3 -readonly -header -column "$DB_PATH" "$sql"
    return 0
  fi

  hr
  info "$DB_PATH"
  local size; size="$(du -ch "$DB_PATH" "$DB_PATH-wal" 2>/dev/null | tail -1 | cut -f1)"
  info "size: ${size:-unknown}"
  hr
  sqlite3 -readonly -header -column "$DB_PATH" "
    SELECT 'samples'   AS what, COUNT(*) AS rows FROM sample
    UNION ALL SELECT 'categories', COUNT(*) FROM category_sample
    UNION ALL SELECT 'workouts',   COUNT(*) FROM workout
    UNION ALL SELECT 'laps',       COUNT(*) FROM workout_activity
    UNION ALL SELECT 'route pts',  COUNT(*) FROM route_point
    UNION ALL SELECT 'athlete',    COUNT(*) FROM athlete;"
  hr
  step "Last syncs:"
  sqlite3 -readonly -header -column "$DB_PATH" "
    SELECT datetime(started_ms / 1000, 'unixepoch', 'localtime') AS started,
           device_name, upserted, deleted, status
    FROM sync_run ORDER BY id DESC LIMIT 5;"
  info "Run SQL directly: ./run.sh db \"SELECT * FROM v_workout LIMIT 5\""
}

# ── MCP ─────────────────────────────────────────────────────────────────────
cmd_mcp() {
  local action="${1:-check}"
  case "$action" in
    check)
      step "Checking the MCP server…"
      if ! python3 -c "import ast,sys; ast.parse(open('mcp/health_mcp.py').read())" 2>/dev/null; then
        err "mcp/health_mcp.py does not parse."; exit 1
      fi
      local tools
      tools="$(printf '%s\n' \
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
        '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
        | python3 mcp/health_mcp.py 2>/dev/null \
        | python3 -c "import sys,json; [print(' '.join(t['name'] for t in json.loads(l)['result']['tools'])) for l in sys.stdin if json.loads(l).get('id')==2]")"
      [ -n "$tools" ] || { err "The server did not answer tools/list."; exit 1; }
      ok "MCP ready — $(echo "$tools" | wc -w | tr -d ' ') tools"
      info "$tools"
      ;;
    test)
      step "Running the MCP tests…"
      PYTHONPATH="$PWD/mcp/src${PYTHONPATH:+:$PYTHONPATH}" python3 -m unittest discover -s mcp/tests || { err "MCP tests failed."; exit 1; }
      ok "MCP tests passed."
      ;;
    *)
      err "Unknown action: $action"; info "Use: check | test"; exit 1 ;;
  esac
}

# ── maintenance ─────────────────────────────────────────────────────────────
guard_data_dir() {
  [ -n "$HOME" ] || { err "HOME is unset — refusing to delete."; exit 1; }
  case "$DATA_DIR" in
    */Library/Application\ Support/FitnessExport) : ;;
    *) err "Unexpected data dir, refusing: $DATA_DIR"; exit 1 ;;
  esac
}

# Remove pairing credentials without deleting the archive.
cmd_unpair() {
  warn "Forgets every paired device on this Mac and this app's own identity."
  info "The synced data stays; you will have to scan the QR again."
  confirm "Unpair now?" || { info "Aborted."; return 0; }
  quit_mac
  local service
  for service in "${KEYCHAIN_SERVICES[@]}"; do
    while security delete-generic-password -s "$service" >/dev/null 2>&1; do :; done
  done
  ok "Pairing material removed."
}

cmd_reset_store() {
  warn "Deletes the database, including saved training plans: $DB_PATH"
  info "Health records can be synchronized again from the iPhone."
  confirm "Delete the store?" || { info "Aborted."; return 0; }
  quit_mac
  guard_data_dir
  rm -f "$DB_PATH" "$DB_PATH-wal" "$DB_PATH-shm"
  ok "Store deleted — it will be recreated on the next launch."
}

cmd_clean() {
  quit_mac
  step "Cleaning build artefacts…"
  rm -rf "$DERIVED_DATA" Derived
  ok "Removed $DERIVED_DATA and Derived."
}

# Install the Release product outside DerivedData.
cmd_install() {
  CONFIG="Release"
  quit_mac
  purge_mac "$CONFIG"
  build_mac "$CONFIG"
  install_mac "$CONFIG"
  launch_mac "$CONFIG" "$INSTALLED_APP_PATH"
  info "Add it to Login Items in System Settings to have it always running."
}

cmd_status() {
  hr
  if mac_running; then
    ok "$MAC_APP_NAME running (PID $(mac_pids | head -1))"
  else
    warn "$MAC_APP_NAME not running"
  fi
  local app; app="$(mac_app_path Debug)"
  if [ -d "$app" ]; then
    info "built: $(stat -f '%Sm' "$app/Contents/MacOS/$MAC_APP_NAME")"
  else
    info "not built yet — run ./run.sh mac"
  fi
  hr
  if [ -f "$DB_PATH" ]; then
    local samples workouts
    samples="$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM sample" 2>/dev/null || echo '?')"
    workouts="$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM workout" 2>/dev/null || echo '?')"
    info "store: $samples samples, $workouts workouts"
  else
    info "store: not created yet"
  fi
  local paired
  paired="$(security find-generic-password -s "${KEYCHAIN_SERVICES[0]}" >/dev/null 2>&1 && echo yes || echo no)"
  info "paired iPhone: $paired"
  hr
}

cmd_logs() {
  local which="${1:-mac}"
  case "$which" in
    mac)
      step "Streaming $MAC_APP_NAME logs — Ctrl-C to stop…"
      log stream --style compact --level debug --predicate 'subsystem BEGINSWITH "org.fitnessexport."' ;;
    ios)
      step "Streaming $IOS_APP_NAME logs from the Simulator — Ctrl-C to stop…"
      xcrun simctl spawn booted log stream --style compact --level debug \
        --predicate "subsystem == \"$IOS_BUNDLE_ID\"" ;;
    *)
      err "Unknown target: $which"; info "Use: mac | ios"; exit 1 ;;
  esac
}

cmd_help() {
  cat <<EOF
${B}FitnessExport${X}
Usage: ./run.sh <command> [arguments] [options]

${B}Commands${X}
  build [mac|ios|kit|all]  Build targets (default: all)
  mac                      Build and launch the Mac companion
  install                  Install and launch the Release build
  iphone [name|udid]        Install and launch on a connected iPhone
  sim                      Run with synthetic workouts in the simulator
  devices                  List connected devices
  sims                     List available simulators
  test [kit|mac|ios|mcp]    Run tests (default: all)
  db ["SQL"]               Inspect the local archive (read-only)
  mcp [check|test]          Check the MCP server or run its tests
  status                   Show app, archive and pairing status
  logs [mac|ios]           Stream application logs
  unpair                   Remove pairing credentials; keep the archive
  reset-store              Delete the local database
  clean                    Remove build artifacts
  kill                     Stop the Mac companion

${B}Options${X}
  -r, --release            Build Release instead of Debug
  -y, --yes                Skip confirmation prompts
  -h, --help               Show help
  -V, --version            Show version
  --                       End option parsing

FITNESS_SIM_DEVICE selects the simulator; NO_COLOR disables color.
EOF
}

# Suggest commands by their longest shared prefix.
closest_command() {
  local typed="$1" best="" best_score=0 candidate score
  for candidate in mac iphone sim build install test db mcp status logs devices \
                   sims unpair reset-store clean kill help version; do
    score=0
    while [ "$score" -lt "${#typed}" ] && [ "$score" -lt "${#candidate}" ]; do
      [ "${typed:$score:1}" = "${candidate:$score:1}" ] || break
      score=$((score + 1))
    done
    if [ "$score" -gt "$best_score" ]; then
      best_score=$score
      best=$candidate
    fi
  done
  # Two shared characters is the floor: below that it is a guess, not a hint.
  [ "$best_score" -ge 2 ] && printf "%s" "$best"
}

# Parse options before dispatch so invalid input cannot trigger an action.
CONFIG="Debug"
ARGS=()
OPTIONS_ENDED=0
SHOW_HELP=0
SHOW_VERSION=0
for argument in "$@"; do
  if [ "$OPTIONS_ENDED" = "1" ]; then
    ARGS+=("$argument")
    continue
  fi
  case "$argument" in
    --) OPTIONS_ENDED=1 ;;
    -h|--help) SHOW_HELP=1 ;;
    -V|--version) SHOW_VERSION=1 ;;
    -y|--yes) ASSUME_YES=1 ;;
    -r|--release) CONFIG="Release" ;;
    -*) err "Unknown option: $argument"; info "Run ./run.sh --help."; exit 2 ;;
    *) ARGS+=("$argument") ;;
  esac
done
if [ "$SHOW_HELP" = "1" ]; then cmd_help; exit 0; fi
if [ "$SHOW_VERSION" = "1" ]; then printf 'FitnessExport dev toolbox %s\n' "$VERSION"; exit 0; fi
CMD="${ARGS[0]:-help}"
ARG1="${ARGS[1]:-}"
REST_SQL="$ARG1"
MAX_ARGUMENTS=1
case "$CMD" in
  build|iphone|device|test|db|mcp|logs) MAX_ARGUMENTS=2 ;;
esac
if [ "${#ARGS[@]}" -gt "$MAX_ARGUMENTS" ]; then
  err "Too many arguments for $CMD. Run ./run.sh --help."
  exit 2
fi

case "$CMD" in
  mac)
    quit_mac; purge_mac "$CONFIG"; build_mac "$CONFIG"
    if [ "$CONFIG" = "Release" ]; then
      install_mac "$CONFIG"; launch_mac "$CONFIG" "$INSTALLED_APP_PATH"
    else
      launch_mac "$CONFIG"
    fi ;;
  build)         cmd_build "${ARG1:-all}" ;;
  install)       cmd_install ;;
  iphone|device) cmd_iphone "$ARG1" ;;
  sim)           cmd_sim ;;
  sims)          cmd_sims ;;
  devices)       cmd_devices ;;
  test)          cmd_test "${ARG1:-all}" ;;
  db)            cmd_db "$REST_SQL" ;;
  mcp)           cmd_mcp "${ARG1:-check}" ;;
  status)        cmd_status ;;
  logs)          cmd_logs "${ARG1:-mac}" ;;
  unpair)        cmd_unpair ;;
  reset-store)   cmd_reset_store ;;
  clean)         cmd_clean ;;
  kill|stop)     quit_mac; ok "Stopped." ;;
  help)          cmd_help ;;
  version)       printf "%s %s\n" "FitnessExport dev toolbox" "$VERSION" ;;
  *)
    err "Unknown command: $CMD"
    suggestion="$(closest_command "$CMD" || true)"
    if [ -n "$suggestion" ]; then
      info "Did you mean: ./run.sh $suggestion"
    else
      info "Run ./run.sh help for the command list."
    fi
    exit 2 ;;
esac
