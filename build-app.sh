#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_NAME="ReplayCap" # SwiftPM product name, shared by both variants
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
ENTITLEMENTS="$ROOT_DIR/Resources/ReplayCap.dev.entitlements"
ICON_PATH="$ROOT_DIR/Resources/ReplayCap.icns"

# Direct/GitHub builds are branded ReplayMac; --appstore builds keep the
# canonical ReplayCap identity (App Review Guideline 5.2.5 forbids "Mac"
# in App Store app names).
#
# --appstore: Mac App Store variant — compiles out the GitHub update checker
# (-DAPPSTORE) and signs with the App Store entitlements (no network client).
# Local testing only; the actual MAS submission still needs Distribution
# signing and a provisioning profile via Xcode/Transporter.
APP_NAME="ReplayMac"
APPSTORE_FLAG=""
# Universal (arm64 + x86_64) so the app runs on Intel Macs too. Rosetta does
# not help here — it translates Intel to ARM, not the reverse — so an Intel
# Mac needs a real x86_64 slice. Multi-arch builds land in
# .build/apple/Products/Release rather than the per-arch directory.
ARCH_FLAGS="--arch arm64 --arch x86_64"
if [ "${1:-}" = "--appstore" ]; then
  APP_NAME="ReplayCap"
  APPSTORE_FLAG="-Xswiftc -DAPPSTORE"
  ENTITLEMENTS="$ROOT_DIR/Resources/ReplayCap.appstore.entitlements"
  printf 'Building Mac App Store variant (update checker disabled).\n'
fi
APP_DIR="$ROOT_DIR/dist/${APP_NAME}.app"

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

# Build once so SPM generates resource bundle accessors
# shellcheck disable=SC2086  # APPSTORE_FLAG/ARCH_FLAGS intentionally word-split
swift build -c release --package-path "$ROOT_DIR" $ARCH_FLAGS $APPSTORE_FLAG

# Patch generated accessors to load bundles from Contents/Resources
# instead of the app root, which avoids breaking code signing.
#
# This is a no-op while ARCH_FLAGS is set: passing --arch switches SwiftPM to
# the Xcode build system, whose generated accessor already searches
# Bundle.main.resourceURL (= Contents/Resources) before falling back to the
# bundle root, and which builds under .build/apple/ rather than the per-arch
# directories globbed below. Kept as a guard for thin builds (empty
# ARCH_FLAGS), where the native build system emits the naive
# Bundle.main.bundleURL form that does need patching.
for accessor in "$ROOT_DIR"/.build/*-apple-macosx/release/*.build/DerivedSources/resource_bundle_accessor.swift; do
  if [ -f "$accessor" ]; then
    sed -i '' 's|Bundle.main.bundleURL.appendingPathComponent("\(.*\)_\1.bundle")|Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\1_\1.bundle")|g' "$accessor"
  fi
done

# Rebuild so the patched accessors are compiled in
# shellcheck disable=SC2086
swift build -c release --package-path "$ROOT_DIR" $ARCH_FLAGS $APPSTORE_FLAG

# ARCH_FLAGS must be repeated here: without them SwiftPM reports the per-arch
# path and we would ship a thin binary out of a universal build.
# shellcheck disable=SC2086
BIN_DIR="$(swift build -c release --show-bin-path --package-path "$ROOT_DIR" $ARCH_FLAGS)"
BIN_PATH="$BIN_DIR/$BIN_NAME"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$INFO_PLIST" "$APP_DIR/Contents/Info.plist"
# Rebrand the canonical (ReplayCap) plist for the direct build: bundle name,
# executable, icon file, and user-facing usage descriptions. The bundle
# identifier (com.replaymac.app) contains no "ReplayCap" and is untouched.
if [ "$APP_NAME" != "ReplayCap" ]; then
  sed -i '' "s/ReplayCap/${APP_NAME}/g" "$APP_DIR/Contents/Info.plist"
fi
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

if [ -f "$ICON_PATH" ]; then
  cp "$ICON_PATH" "$APP_DIR/Contents/Resources/${APP_NAME}.icns"
fi

# Copy SPM resource bundles into Contents/Resources so they are sealed by codesign
for bundle in "$BIN_DIR"/*.bundle; do
  if [ -d "$bundle" ]; then
    cp -R "$bundle" "$APP_DIR/Contents/Resources/"
  fi
done

# Hardened runtime + secure timestamp are required for notarization.
# Ad-hoc signatures support neither, so only add them for real identities.
HARDENING_FLAGS=""
if [ "$SIGN_IDENTITY" != "-" ]; then
  HARDENING_FLAGS="--options runtime --timestamp"
fi

# shellcheck disable=SC2086  # HARDENING_FLAGS intentionally word-splits
codesign --force --deep $HARDENING_FLAGS --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

printf "Built app: %s\n" "$APP_DIR"
