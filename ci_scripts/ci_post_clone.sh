#!/bin/sh
set -eu

# Xcode Cloud clones the repo fresh and builds the committed .xcodeproj
# without running xcodegen. This project's source of truth is project.yml,
# so regenerate the Xcode project before the build begins to avoid drift
# when files are added or removed.

cd "$CI_PRIMARY_REPOSITORY_PATH"

if ! command -v xcodegen >/dev/null 2>&1; then
    brew install xcodegen
fi

xcodegen generate
