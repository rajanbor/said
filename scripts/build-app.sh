#!/usr/bin/env bash
# Builds build/Said.app (release). Usage: ./scripts/build-app.sh [--open]
#
# Signing: the app is signed with a local, self-signed certificate kept in its own
# keychain (~/.said/signing). That gives Said a stable identity across rebuilds and
# updates, so macOS remembers the microphone permission. The login keychain is not touched.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Said"
APP="build/Said.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Said"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

SIGN_DIR="$HOME/.said/signing"
KC="$SIGN_DIR/said-signing.keychain-db"
KC_PW="said-local-signing"   # protects only this local, self-signed signing key
ID_NAME="Said Local Signing"

make_identity() {
  local tmp; tmp="$(mktemp -d)"
  cat > "$tmp/cert.cnf" <<CNF
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
  # /usr/bin/openssl (LibreSSL) writes a PKCS#12 that macOS `security` can import.
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$tmp/cert.cnf" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
    -out "$tmp/id.p12" -passout pass:"$KC_PW" -name "$ID_NAME"
  mkdir -p "$SIGN_DIR"
  security create-keychain -p "$KC_PW" "$KC"
  security set-keychain-settings "$KC"   # no auto-lock
  security unlock-keychain -p "$KC_PW" "$KC"
  security import "$tmp/id.p12" -k "$KC" -P "$KC_PW" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -s -k "$KC_PW" "$KC" >/dev/null
  rm -rf "$tmp"
}

sign_stable() {
  [[ -f "$KC" ]] || make_identity
  security unlock-keychain -p "$KC_PW" "$KC"
  codesign --force --keychain "$KC" --sign "$ID_NAME" "$APP"
}

if sign_stable >/dev/null 2>&1; then
  echo "Signed with $ID_NAME"
else
  echo "warning: stable signing failed, falling back to ad-hoc (macOS may ask for the microphone again)" >&2
  codesign --force --sign - "$APP" >/dev/null
fi

echo "Built $APP"
[[ "${1:-}" == "--open" ]] && open "$APP"
exit 0
