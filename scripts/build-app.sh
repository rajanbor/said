#!/usr/bin/env bash
# Builds build/Said.app (release, ad-hoc signed). Usage: ./scripts/build-app.sh [--open]
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Said"
APP="build/Said.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Said"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null

echo "Built $APP"
[[ "${1:-}" == "--open" ]] && open "$APP"
exit 0
