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
XCODEBUILD_LOG_PATH="${XCODEBUILD_LOG_PATH:-$RESULT_BUNDLE_PATH.log}"

SIMULATOR_FAILURE_PATTERN="CoreSimulatorService connection became invalid|CoreSimulatorService.*unavailable|Mach error -308|Application failed preflight checks|Simulator device failed to launch|simdiskimaged.*crashed|simdiskimaged.*not responding"

print_simulator_recovery_message() {
  echo "" >&2
  echo "CoreSimulator could not launch the Wallet test runner." >&2
  echo "Recommended recovery:" >&2
  echo "  1. Quit Simulator and Xcode." >&2
  echo "  2. Run: /Applications/Xcode.app/Contents/Developer/usr/bin/simctl shutdown all" >&2
  echo "  3. Re-run: ./scripts/test.sh" >&2
  echo "If CoreSimulatorService is unavailable or Mach error -308 repeats, reboot macOS and retry." >&2
  echo "You can also pin a different simulator with: DESTINATION=\"id=<simulator-id>\" ./scripts/test.sh" >&2
}

contains_simulator_failure() {
  grep -Eq "$SIMULATOR_FAILURE_PATTERN" "$1"
}

if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  export PATH="$DEVELOPER_DIR/usr/bin:$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH"
fi

if [[ -n "${DEVELOPER_DIR:-}" && -x "$DEVELOPER_DIR/usr/bin/simctl" ]]; then
  SIMCTL=("$DEVELOPER_DIR/usr/bin/simctl")
else
  SIMCTL=(xcrun simctl)
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

bash "$ROOT_DIR/scripts/verify_project_membership.sh"

if [[ -z "$DESTINATION" ]]; then
  destination_discovery_log="$(mktemp "${TMPDIR:-/tmp}/wallet-destinations.log.XXXXXX")"
  xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME" -showdestinations >"$destination_discovery_log" 2>&1 || true
  if contains_simulator_failure "$destination_discovery_log"; then
    cat "$destination_discovery_log" >&2
    print_simulator_recovery_message
    exit 1
  fi

  discovered_id="$(sed -n 's/.*platform:iOS Simulator, id:\([^,]*\),.*/\1/p' "$destination_discovery_log" \
    | grep -v "dvtdevice-DVTiOSDeviceSimulatorPlaceholder-iphonesimulator:placeholder" \
    | head -n 1 || true)"

  if [[ -z "$discovered_id" ]]; then
    simctl_discovery_log="$(mktemp "${TMPDIR:-/tmp}/wallet-simctl.log.XXXXXX")"
    "${SIMCTL[@]}" list devices available >"$simctl_discovery_log" 2>&1 || true
    if contains_simulator_failure "$simctl_discovery_log"; then
      cat "$simctl_discovery_log" >&2
      print_simulator_recovery_message
      exit 1
    fi

    discovered_id="$(awk -F '[()]' '/(Shutdown|Booted)/ { print $2; exit }' "$simctl_discovery_log" \
      | head -n 1 || true)"
  fi

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

if [[ "${SIMULATOR_PRETEST_SHUTDOWN:-1}" == "1" && "$DESTINATION" =~ ^id=([A-Fa-f0-9-]+)$ ]]; then
  simulator_id="${BASH_REMATCH[1]}"
  echo "Resetting simulator launch state for: $simulator_id"
  "${SIMCTL[@]}" shutdown "$simulator_id" >/dev/null 2>&1 || true
fi

echo "Running tests with destination: $DESTINATION"
echo "DerivedData path: $DERIVED_DATA_PATH"
echo "xcodebuild log: $XCODEBUILD_LOG_PATH"
set +e
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -destination-timeout "$DESTINATION_TIMEOUT" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -resultBundlePath "$RESULT_BUNDLE_PATH" \
  test 2>&1 | tee "$XCODEBUILD_LOG_PATH"
xcodebuild_status="${PIPESTATUS[0]}"
set -e

if [[ "$xcodebuild_status" -ne 0 ]]; then
  if contains_simulator_failure "$XCODEBUILD_LOG_PATH"; then
    print_simulator_recovery_message
  fi
  exit "$xcodebuild_status"
fi
