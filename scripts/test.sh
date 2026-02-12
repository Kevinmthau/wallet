#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/Wallet.xcodeproj"
SCHEME="Wallet"
DEFAULT_DESTINATION="platform=iOS Simulator,name=iPhone 16 Pro,OS=latest"
DESTINATION="${DESTINATION:-}"
DESTINATION_TIMEOUT="${DESTINATION_TIMEOUT:-20}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/.build/DerivedData}"
RESULT_BUNDLE_PATH="${RESULT_BUNDLE_PATH:-$ROOT_DIR/.build/TestResults/WalletTests-$(date +%Y%m%d-%H%M%S).xcresult}"

if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

if command -v xcodegen >/dev/null 2>&1 && [[ -f "$ROOT_DIR/project.yml" ]]; then
  if [[ ! -f "$PROJECT_PATH/project.pbxproj" || "$ROOT_DIR/project.yml" -nt "$PROJECT_PATH/project.pbxproj" ]]; then
    echo "Regenerating Xcode project from project.yml..."
    (cd "$ROOT_DIR" && xcodegen generate)
  fi
fi

if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "Missing Xcode project at $PROJECT_PATH" >&2
  exit 1
fi

if [[ -z "$DESTINATION" ]]; then
  discovered_id="$(xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME" -showdestinations 2>/dev/null \
    | sed -n 's/.*platform:iOS Simulator, id:\([^,]*\),.*/\1/p' \
    | grep -v "dvtdevice-DVTiOSDeviceSimulatorPlaceholder-iphonesimulator:placeholder" \
    | head -n 1 || true)"

  if [[ -n "$discovered_id" ]]; then
    DESTINATION="id=$discovered_id"
  else
    echo "No runnable iOS Simulator found for scheme '$SCHEME'." >&2
    echo "Install an iOS simulator runtime in Xcode (Settings > Platforms), then re-run this command." >&2
    echo "You can also override manually with: DESTINATION=\"$DEFAULT_DESTINATION\" ./scripts/test.sh" >&2
    exit 1
  fi
fi

mkdir -p "$DERIVED_DATA_PATH" "$(dirname "$RESULT_BUNDLE_PATH")"

echo "Running tests with destination: $DESTINATION"
echo "DerivedData path: $DERIVED_DATA_PATH"
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -destination-timeout "$DESTINATION_TIMEOUT" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -resultBundlePath "$RESULT_BUNDLE_PATH" \
  test
