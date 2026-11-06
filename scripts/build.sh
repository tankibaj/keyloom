#!/bin/zsh
# Build Keyloom.app (Release) into <repo>/.derived. Prints the .app path on stdout.
set -euo pipefail

ROOT="${0:A:h:h}"
DERIVED="$ROOT/.derived"
APP="$DERIVED/Build/Products/Release/Keyloom.app"

if ! command -v xcodebuild >/dev/null 2>&1; then
  print -u2 "build: xcodebuild not found"
  exit 1
fi

# xcodebuild chatter goes to stderr so stdout stays just the app path
xcodebuild \
  -project "$ROOT/Keyloom.xcodeproj" \
  -scheme Keyloom \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  build >&2

if [[ ! -d "$APP" ]]; then
  print -u2 "build: expected product missing: $APP"
  exit 1
fi

print -- "$APP"
