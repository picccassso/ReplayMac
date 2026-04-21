#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$ROOT_DIR/dist/ReplayMac.app"
BIN_NAME="ReplayMac"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
ENTITLEMENTS="$ROOT_DIR/Resources/ReplayMac.dev.entitlements"

resolve_signing_identity() {
  if [ -n "${SIGNING_IDENTITY:-}" ]; then
    printf '%s\n' "$SIGNING_IDENTITY"
    return
  fi

  local line
  while IFS= read -r line; do
    case "$line" in
      *"Apple Development:"*)
        local identity
        identity="${line#*\"}"
        identity="${identity%\"*}"
        printf '%s\n' "$identity"
        return
        ;;
    esac
  done < <(security find-identity -v -p codesigning 2>/dev/null || true)

  printf '%s\n' "-"
}

SIGN_IDENTITY="$(resolve_signing_identity)"

if [ "$SIGN_IDENTITY" = "-" ]; then
  printf 'Warning: No Apple Development certificate found; using ad-hoc signing. macOS may ask for screen/audio permission repeatedly after rebuilds.\n'
else
  printf 'Using signing identity: %s\n' "$SIGN_IDENTITY"
fi

swift build -c release --package-path "$ROOT_DIR"

BIN_DIR="$(swift build -c release --show-bin-path --package-path "$ROOT_DIR")"
BIN_PATH="$BIN_DIR/$BIN_NAME"
SPARKLE_FRAMEWORK_PATH="$BIN_DIR/Sparkle.framework"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Frameworks"

cp "$INFO_PLIST" "$APP_DIR/Contents/Info.plist"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$BIN_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$BIN_NAME"

if [ -d "$SPARKLE_FRAMEWORK_PATH" ]; then
  cp -R "$SPARKLE_FRAMEWORK_PATH" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
fi

if ! /usr/bin/otool -l "$APP_DIR/Contents/MacOS/$BIN_NAME" | /usr/bin/grep -q "@executable_path/../Frameworks"; then
  /usr/bin/install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_DIR/Contents/MacOS/$BIN_NAME"
fi

codesign --force --deep --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

printf "Built app: %s\n" "$APP_DIR"
