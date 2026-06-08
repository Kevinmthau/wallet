#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_FILE="$ROOT_DIR/Wallet.xcodeproj/project.pbxproj"

if [[ ! -f "$PROJECT_FILE" ]]; then
  echo "Missing Xcode project file at $PROJECT_FILE" >&2
  exit 1
fi

duplicate_basenames="$(
  find "$ROOT_DIR/Wallet" -name '*.swift' -type f -print \
    | awk -F/ '{ print $NF }' \
    | sort \
    | uniq -d
)"

if [[ -n "$duplicate_basenames" ]]; then
  echo "Cannot verify app target membership with duplicate Swift filenames:" >&2
  echo "$duplicate_basenames" >&2
  exit 1
fi

missing_files=()
while IFS= read -r swift_file; do
  filename="${swift_file##*/}"
  if ! grep -Fq "/* $filename in Sources */" "$PROJECT_FILE"; then
    missing_files+=("${swift_file#$ROOT_DIR/}")
  fi
done < <(find "$ROOT_DIR/Wallet" -name '*.swift' -type f -print | sort)

if (( ${#missing_files[@]} > 0 )); then
  echo "Swift files missing from the Wallet app target:" >&2
  printf '  %s\n' "${missing_files[@]}" >&2
  echo "Add each file to Wallet.xcodeproj or regenerate the project from project.yml." >&2
  exit 1
fi

echo "Verified Wallet app target membership for Swift sources."
