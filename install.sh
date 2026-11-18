#!/usr/bin/env bash
# Said installer — builds the app from source on your Mac and puts it in Applications.
#
#   curl -fsSL https://raw.githubusercontent.com/rajanbor/said/main/install.sh | bash
#
# Run it again to update. Uninstall: rm -rf /Applications/Said.app ~/.said
set -euo pipefail
umask 077   # ~/.said and everything in it is private to you

REPO="${SAID_REPO:-https://github.com/rajanbor/said.git}"
SRC="${SAID_SRC:-$HOME/.said/src}"
# Installs the newest release tag (vX.Y.Z). Set SAID_VERSION=main for the latest code, or e.g. v0.1.0.
REF="${SAID_VERSION:-}"

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "Said only runs on macOS."
major="$(sw_vers -productVersion | cut -d. -f1)"
(( major >= 14 )) || fail "Said needs macOS 14 or newer (you have $(sw_vers -productVersion))."

if ! xcrun --find swift >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  say "Xcode Command Line Tools are missing, opening the Apple installer."
  xcode-select --install >/dev/null 2>&1 || true
  fail "When the tools are installed, run this command again."
fi

if [[ -z "$REF" ]]; then
  REF="$(git ls-remote --tags --refs "$REPO" 'v*' | awk -F/ '{print $3}' | sort -V | tail -n 1)"
  REF="${REF:-main}"
fi

if [[ ! -d "$SRC/.git" ]]; then
  say "Downloading Said ($REF) to $SRC"
  rm -rf "$SRC"
  mkdir -p "$SRC"
  git -C "$SRC" init --quiet
  git -C "$SRC" remote add origin "$REPO"
else
  say "Updating Said to $REF"
fi
git -C "$SRC" fetch --quiet --depth 1 --force origin "$REF"
COMMIT="$(git -C "$SRC" rev-parse "FETCH_HEAD^{commit}")"

# Trust on first use: remember which commit each release tag pointed to. If a tag that was
# already installed on this Mac later points somewhere else, someone rewrote the release: stop.
KNOWN="$HOME/.said/known-releases"
if [[ "$REF" == v* ]]; then
  mkdir -p "$(dirname "$KNOWN")"; touch "$KNOWN"; chmod 600 "$KNOWN"
  seen="$(awk -v t="$REF" '$1 == t { print $2 }' "$KNOWN")"
  if [[ -n "$seen" && "$seen" != "$COMMIT" ]]; then
    fail "Release $REF now points to $COMMIT, but it was $seen when you installed it. Not installing. Check https://github.com/rajanbor/said before trying again."
  fi
  [[ -n "$seen" ]] || printf '%s %s\n' "$REF" "$COMMIT" >> "$KNOWN"
fi

git -C "$SRC" reset --quiet --hard FETCH_HEAD
say "Building $REF (commit ${COMMIT:0:12})"

say "This can take a few minutes the first time…"
LOG="$HOME/.said/build.log"
mkdir -p "$(dirname "$LOG")"
if ! ( cd "$SRC" && ./scripts/build-app.sh ) >"$LOG" 2>&1; then
  tail -n 30 "$LOG" >&2
  fail "Build failed. Full log: $LOG"
fi

DEST="/Applications"
[[ -w "$DEST" ]] || DEST="$HOME/Applications"
mkdir -p "$DEST"

umask 022   # the app itself is installed with normal permissions
pkill -x Said >/dev/null 2>&1 || true
rm -rf "$DEST/Said.app"
cp -R "$SRC/build/Said.app" "$DEST/Said.app"

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$DEST/Said.app/Contents/Info.plist")"
say "Installed Said $VERSION: $DEST/Said.app"
open "$DEST/Said.app"
say "Said is running. Look for its icon in the menu bar (top right)."
