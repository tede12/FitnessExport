#!/bin/zsh
# Capture synthetic UI fixtures using the screenshot test suite.
set -euo pipefail
SIMULATOR="${1:-iPhone 17 Pro}"
APPEARANCE="${2:-light}"
OUTPUT="${3:-screenshots/$APPEARANCE}"
cd "$(dirname "$0")/.."

UDID=$(xcrun simctl list devices available | grep -F "$SIMULATOR (" | head -1 | sed -E 's/.*\(([0-9A-F-]+)\).*/\1/')
[[ -n "$UDID" ]] || { echo "Simulator not found: $SIMULATOR" >&2; exit 1; }
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl ui "$UDID" appearance "$APPEARANCE"
mkdir -p "$OUTPUT"
TEST_RUNNER_SCREENSHOT_DIR="$(cd "$OUTPUT" && pwd)" xcodebuild \
  -workspace FitnessExport.xcworkspace -scheme FitnessExport \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath .derivedData \
  -parallel-testing-enabled NO -configuration Debug test \
  -only-testing:FitnessExportUITests/ScreenshotTests
