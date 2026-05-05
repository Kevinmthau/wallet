#!/bin/sh
set -u

if [ -z "${CI_APP_STORE_SIGNED_APP_PATH:-}" ] || [ ! -e "$CI_APP_STORE_SIGNED_APP_PATH" ]; then
    echo "No App Store signed app found; skipping TestFlight notes."
    exit 0
fi

REPO_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
TESTFLIGHT_DIR="$REPO_ROOT/TestFlight"
NOTES_FILE="$TESTFLIGHT_DIR/WhatToTest.en-US.txt"
COMMIT_COUNT="${TESTFLIGHT_CHANGELOG_COMMIT_COUNT:-8}"

case "$COMMIT_COUNT" in
    ''|*[!0-9]*)
        COMMIT_COUNT=8
        ;;
esac

cd "$REPO_ROOT" || exit 0
mkdir -p "$TESTFLIGHT_DIR"

# Xcode Cloud can use a shallow clone; deepen it when possible so the notes
# include more than the triggering commit.
git fetch --deepen "$COMMIT_COUNT" --quiet >/dev/null 2>&1 || true

CHANGE_LINES="$(git log --no-merges --pretty=format:'- %s' -n "$COMMIT_COUNT" 2>/dev/null || true)"

if [ -z "$CHANGE_LINES" ]; then
    CHANGE_LINES="$(git log --pretty=format:'- %s' -n "$COMMIT_COUNT" 2>/dev/null || true)"
fi

if [ -z "$CHANGE_LINES" ]; then
    CHANGE_LINES="- Build updates and fixes."
fi

{
    if [ -n "${CI_BUILD_NUMBER:-}" ]; then
        printf 'Build %s\n\n' "$CI_BUILD_NUMBER"
    fi

    printf 'What changed:\n%s\n' "$CHANGE_LINES"
} > "$NOTES_FILE"

echo "Wrote TestFlight notes to $NOTES_FILE"
