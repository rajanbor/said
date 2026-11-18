#!/usr/bin/env bash
# Builds build/Said.app (release). Usage: ./scripts/build-app.sh [--open]
#
# Signing: the app is signed with a local, self-signed certificate kept in its own
# keychain (~/.said/signing). That gives Said a stable identity across rebuilds and
# updates, so macOS remembers the microphone permission. The login keychain is not touched.
set -euo pipefail
cd "$(dirname "$0")/.."

# --disable-keychain: the prebuilt llama.cpp download is public; don't ask the keychain for GitHub logins.
swift build -c release --disable-keychain
BIN_DIR="$(swift build -c release --disable-keychain --show-bin-path)"
BIN="$BIN_DIR/Said"
APP="build/Said.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Said"
cp -R "$BIN_DIR/llama.framework" "$APP/Contents/Frameworks/"   # local summaries (llama.cpp)
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/*.lproj "$APP/Contents/Resources/"   # translations (en, pl)
chmod -R u+rwX,go+rX,go-w "$APP"   # even when called with a strict umask

SIGN_DIR="$HOME/.said/signing"
KC="$SIGN_DIR/said-signing.keychain-db"
PW_FILE="$SIGN_DIR/keychain-password"     # random, created once, readable by you only (0600)
LEGACY_PW="said-local-signing"            # fixed password used by Said <= 0.4.0
ID_NAME="Said Local Signing"

# Anything created here is private to this user, and temp files go away on any exit.
umask 077
TMP_DIR=""
trap '[[ -n "$TMP_DIR" ]] && rm -rf "$TMP_DIR"' EXIT

random_password() { /usr/bin/openssl rand -hex 32; }

make_identity() {
  TMP_DIR="$(mktemp -d)"
  local kc_pw; kc_pw="$(random_password)"
  cat > "$TMP_DIR/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $ID_NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
  # The unencrypted key exists only inside TMP_DIR (0700) and is removed by the trap.
  # /usr/bin/openssl (LibreSSL) writes a PKCS#12 that macOS `security` can import.
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$TMP_DIR/cert.cnf" \
    -keyout "$TMP_DIR/key.pem" -out "$TMP_DIR/cert.pem" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$TMP_DIR/key.pem" -in "$TMP_DIR/cert.pem" \
    -out "$TMP_DIR/id.p12" -passout pass:"$kc_pw" -name "$ID_NAME"
  mkdir -p "$SIGN_DIR"
  chmod 700 "$SIGN_DIR"
  security create-keychain -p "$kc_pw" "$KC"
  security set-keychain-settings "$KC"   # no auto-lock
  security unlock-keychain -p "$kc_pw" "$KC"
  security import "$TMP_DIR/id.p12" -k "$KC" -P "$kc_pw" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -s -k "$kc_pw" "$KC" >/dev/null
  printf '%s' "$kc_pw" > "$PW_FILE"
  chmod 600 "$PW_FILE" "$KC"
  rm -rf "$TMP_DIR"; TMP_DIR=""
}

# Keychains made by Said <= 0.4.0 used a fixed password: switch them to a random one.
migrate_password() {
  [[ -f "$KC" && ! -f "$PW_FILE" ]] || return 0
  local kc_pw; kc_pw="$(random_password)"
  security set-keychain-password -o "$LEGACY_PW" -p "$kc_pw" "$KC"
  printf '%s' "$kc_pw" > "$PW_FILE"
  chmod 600 "$PW_FILE" "$KC"
  chmod 700 "$SIGN_DIR"
}

sign_stable() {
  [[ -f "$KC" ]] || make_identity
  migrate_password
  chmod 700 "$SIGN_DIR"; chmod 600 "$KC" "$PW_FILE"
  security unlock-keychain -p "$(cat "$PW_FILE")" "$KC"
  codesign --force --keychain "$KC" --sign "$ID_NAME" "$APP/Contents/Frameworks/llama.framework"
  codesign --force --keychain "$KC" --sign "$ID_NAME" "$APP"
}

if sign_stable >/dev/null 2>&1; then
  echo "Signed with $ID_NAME"
else
  echo "warning: stable signing failed, falling back to ad-hoc (macOS may ask for the microphone again)" >&2
  codesign --force --sign - "$APP/Contents/Frameworks/llama.framework" >/dev/null
  codesign --force --sign - "$APP" >/dev/null
fi

echo "Built $APP"
[[ "${1:-}" == "--open" ]] && open "$APP"
exit 0
