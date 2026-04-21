#!/usr/bin/env bash
set -euo pipefail

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

swift build

BIN_PATH="$(swift build --show-bin-path)/ReplayMac"

if [ "$SIGN_IDENTITY" = "-" ]; then
  printf 'Warning: No Apple Development certificate found; using ad-hoc signing.\n'
fi

codesign --force --sign "$SIGN_IDENTITY" --entitlements Resources/ReplayMac.dev.entitlements "$BIN_PATH"

LOG_DIR="${TMPDIR:-/tmp}/replaymac-dev"
mkdir -p "$LOG_DIR"

"$BIN_PATH" >"$LOG_DIR/replaymac.stdout.log" 2>"$LOG_DIR/replaymac.stderr.log" < /dev/null &
APP_PID=$!

disown "$APP_PID" 2>/dev/null || true

printf 'ReplayMac started (pid: %s). Logs: %s\n' "$APP_PID" "$LOG_DIR"
