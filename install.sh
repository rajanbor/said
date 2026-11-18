#!/usr/bin/env bash
# Said installer — builds the app from source on your Mac and puts it in Applications.
#
#   curl -fsSL https://raw.githubusercontent.com/rajanbor/said/main/install.sh | bash
#
# Run it again to update. Uninstall: rm -rf /Applications/Said.app ~/.said
set -euo pipefail

REPO="${SAID_REPO:-https://github.com/rajanbor/said.git}"
SRC="${SAID_SRC:-$HOME/.said/src}"

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "Said działa tylko na macOS."
major="$(sw_vers -productVersion | cut -d. -f1)"
(( major >= 14 )) || fail "Wymagany macOS 14 lub nowszy (masz $(sw_vers -productVersion))."

if ! xcrun --find swift >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  say "Brak narzędzi Xcode Command Line Tools — otwieram instalator Apple."
  xcode-select --install >/dev/null 2>&1 || true
  fail "Po zakończeniu instalacji narzędzi uruchom tę komendę ponownie."
fi

if [[ -d "$SRC/.git" ]]; then
  say "Aktualizuję kod w $SRC"
  git -C "$SRC" fetch --quiet --depth 1 origin main
  git -C "$SRC" reset --quiet --hard FETCH_HEAD
else
  say "Pobieram kod do $SRC"
  rm -rf "$SRC"
  mkdir -p "$(dirname "$SRC")"
  git clone --quiet --depth 1 "$REPO" "$SRC"
fi

say "Buduję Said (pierwszy raz może potrwać kilka minut)…"
LOG="$HOME/.said/build.log"
if ! ( cd "$SRC" && ./scripts/build-app.sh ) >"$LOG" 2>&1; then
  tail -n 30 "$LOG" >&2
  fail "Budowanie nie powiodło się. Pełny log: $LOG"
fi

DEST="/Applications"
[[ -w "$DEST" ]] || DEST="$HOME/Applications"
mkdir -p "$DEST"

pkill -x Said >/dev/null 2>&1 || true
rm -rf "$DEST/Said.app"
cp -R "$SRC/build/Said.app" "$DEST/Said.app"

say "Zainstalowano: $DEST/Said.app"
open "$DEST/Said.app"
say "Said działa — szukaj ikony w pasku menu (prawy górny róg)."
