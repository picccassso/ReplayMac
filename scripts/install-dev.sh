#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="$ROOT_DIR/build-app.sh"
BUILT_APP="$ROOT_DIR/dist/ReplayMac.app"
INSTALLED_APP="/Applications/ReplayMac.app"
BUNDLE_ID="com.replaymac.app"

FRESH=false
LAUNCH=false
BUILD=true
ALLOW_ADHOC=false

usage() {
  cat <<'EOF'
Usage: ./scripts/install-dev.sh [options]

Build and install ReplayMac in /Applications without launching it.

Options:
  --fresh        Reset onboarding, app state, Screen Recording permission,
                 and Microphone permission. Saved recordings are untouched.
  --launch       Launch ReplayMac after installation.
  --no-build     Install the existing dist/ReplayMac.app without rebuilding.
  --allow-adhoc  Allow an ad-hoc-signed build. macOS may ask for permissions
                 again after later rebuilds.
  -h, --help     Show this help.

Examples:
  ./scripts/install-dev.sh
  ./scripts/install-dev.sh --fresh
  ./scripts/install-dev.sh --fresh --launch
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --fresh)
      FRESH=true
      ;;
    --launch)
      LAUNCH=true
      ;;
    --no-build)
      BUILD=false
      ;;
    --allow-adhoc)
      ALLOW_ADHOC=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Error: unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

is_running() {
  pgrep -x ReplayMac >/dev/null 2>&1 || pgrep -x ReplayCap >/dev/null 2>&1
}

quit_replaymac() {
  if ! is_running; then
    return
  fi

  printf 'Stopping ReplayMac...\n'
  osascript -e 'tell application id "com.replaymac.app" to quit' >/dev/null 2>&1 || true

  local attempt
  for attempt in {1..10}; do
    if ! is_running; then
      return
    fi
    sleep 0.5
  done

  pkill -TERM -x ReplayMac >/dev/null 2>&1 || true
  pkill -TERM -x ReplayCap >/dev/null 2>&1 || true
  sleep 1

  if is_running; then
    printf 'Error: ReplayMac is still running. Quit it and try again.\n' >&2
    exit 1
  fi
}

verify_app() {
  local app_path="$1"
  local bundle_id
  local signature_details

  if [ ! -d "$app_path" ]; then
    printf 'Error: app not found: %s\n' "$app_path" >&2
    exit 1
  fi

  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")"
  if [ "$bundle_id" != "$BUNDLE_ID" ]; then
    printf 'Error: expected bundle ID %s, found %s.\n' "$BUNDLE_ID" "$bundle_id" >&2
    exit 1
  fi

  codesign --verify --deep --strict "$app_path"
  signature_details="$(codesign -dv --verbose=4 "$app_path" 2>&1)"
  if printf '%s\n' "$signature_details" | grep -q '^Signature=adhoc$'; then
    if [ "$ALLOW_ADHOC" = false ]; then
      printf '%s\n' 'Error: the build is ad-hoc signed.' >&2
      printf '%s\n' 'Install a development signing certificate, or pass --allow-adhoc if repeated permission prompts are acceptable.' >&2
      exit 1
    fi
    printf '%s\n' 'Warning: installing an ad-hoc-signed build; macOS may ask for permissions again after later rebuilds.'
  fi
}

install_app() {
  local staged_app="/Applications/.ReplayMac.install.$$.app"
  local previous_app="/Applications/.ReplayMac.previous.$$.app"
  local had_previous=false

  if [ -e "$staged_app" ] || [ -e "$previous_app" ]; then
    printf 'Error: temporary installation path already exists.\n' >&2
    exit 1
  fi

  cleanup_install() {
    rm -rf "$staged_app"
    if [ -e "$previous_app" ]; then
      if [ ! -e "$INSTALLED_APP" ]; then
        mv "$previous_app" "$INSTALLED_APP"
      else
        rm -rf "$previous_app"
      fi
    fi
  }
  trap cleanup_install EXIT

  ditto "$BUILT_APP" "$staged_app"
  verify_app "$staged_app"

  if [ -e "$INSTALLED_APP" ]; then
    mv "$INSTALLED_APP" "$previous_app"
    had_previous=true
  fi

  if ! mv "$staged_app" "$INSTALLED_APP"; then
    if [ "$had_previous" = true ] && [ ! -e "$INSTALLED_APP" ]; then
      mv "$previous_app" "$INSTALLED_APP"
    fi
    printf 'Error: could not install ReplayMac in /Applications.\n' >&2
    exit 1
  fi

  verify_app "$INSTALLED_APP"
  if [ -e "$previous_app" ]; then
    rm -rf "$previous_app"
  fi
  trap - EXIT
}

reset_first_run_state() {
  local user_home="${HOME:?HOME is not set}"
  local standard_preferences="$user_home/Library/Preferences/$BUNDLE_ID.plist"
  local container="$user_home/Library/Containers/$BUNDLE_ID"
  local container_library="$container/Data/Library"
  local container_preferences="$container_library/Preferences/$BUNDLE_ID.plist"
  local standard_cache="$user_home/Library/Caches/$BUNDLE_ID"
  local standard_support="$user_home/Library/Application Support/$BUNDLE_ID"
  local standard_saved_state="$user_home/Library/Saved Application State/$BUNDLE_ID.savedState"

  case "$user_home" in
    /Users/*) ;;
    *)
      printf 'Error: refusing to reset state for unexpected home directory: %s\n' "$user_home" >&2
      exit 1
      ;;
  esac

  # The targeted sandbox locations should hold settings and caches, not
  # recordings. Stop instead of deleting state if that ever changes.
  if [ -d "$container" ] && find "$container" -type f \( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.m4v' \) -print -quit | grep -q .; then
    printf 'Error: a recording was found inside %s; refusing to delete app state.\n' "$container" >&2
    exit 1
  fi

  printf 'Resetting ReplayMac setup and privacy permissions...\n'
  killall cfprefsd >/dev/null 2>&1 || true

  rm -f "$standard_preferences"
  rm -f "$container_preferences"
  rm -rf \
    "$container_library/Caches" \
    "$container_library/HTTPStorages" \
    "$container_library/Logs" \
    "$container_library/Saved Application State" \
    "$container/Data/tmp" \
    "$standard_cache" \
    "$standard_support" \
    "$standard_saved_state"

  # Keep the legacy-install migration from treating existing recordings as a
  # completed setup while explicitly leaving onboarding incomplete.
  mkdir -p "$(dirname "$container_preferences")"
  plutil -create xml1 "$container_preferences"
  plutil -insert hasCompletedOnboarding -bool false "$container_preferences"
  plutil -insert didEvaluateLegacyOnboardingMigration -bool true "$container_preferences"
  plutil -insert hasPromptedForScreenCapture -bool false "$container_preferences"

  plutil -create xml1 "$standard_preferences"
  plutil -insert hasCompletedOnboarding -bool false "$standard_preferences"
  plutil -insert didEvaluateLegacyOnboardingMigration -bool true "$standard_preferences"
  plutil -insert hasPromptedForScreenCapture -bool false "$standard_preferences"

  tccutil reset ScreenCapture "$BUNDLE_ID"
  tccutil reset Microphone "$BUNDLE_ID"
  killall cfprefsd >/dev/null 2>&1 || true
}

if [ "$BUILD" = true ]; then
  printf 'Building ReplayMac...\n'
  "$BUILD_SCRIPT"
fi

verify_app "$BUILT_APP"
quit_replaymac

printf 'Installing %s...\n' "$INSTALLED_APP"
install_app

if [ "$FRESH" = true ]; then
  reset_first_run_state
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALLED_APP/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INSTALLED_APP/Contents/Info.plist")"
printf 'Installed ReplayMac %s (%s).\n' "$VERSION" "$BUILD_NUMBER"

if [ "$FRESH" = true ]; then
  printf '%s\n' 'Fresh setup is ready. Screen Recording and Microphone permissions were reset; saved recordings were untouched.'
fi

if [ "$LAUNCH" = true ]; then
  open "$INSTALLED_APP"
  printf '%s\n' 'ReplayMac launched.'
else
  printf '%s\n' 'ReplayMac was left closed.'
fi
