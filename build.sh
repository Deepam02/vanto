#!/bin/zsh
# Build dist/VoiceCommand.app: release build, bundle assembly, hardened-runtime signing.
#
# Signing identity, in order:
#   1. $SIGN_IDENTITY, if set
#   2. the first "Apple Development" or "Developer ID Application" identity in your keychain
#   3. "VoiceCommand Local Signing" (create it once with scripts/make-signing-identity.sh)
#   4. ad-hoc: works, but macOS forgets the Accessibility/Input Monitoring grants on every rebuild
#
# Usage: ./build.sh [--debug] [--open]
set -euo pipefail
cd "${0:A:h}"

CONFIG=release
OPEN=0
for arg in "$@"; do
  case $arg in
    --debug) CONFIG=debug ;;
    --open) OPEN=1 ;;
    *) echo "unknown option $arg"; exit 2 ;;
  esac
done

echo "==> swift build ($CONFIG)"
swift build -c $CONFIG --product VoiceCommand
BIN=$(swift build -c $CONFIG --show-bin-path)

APP=dist/VoiceCommand.app
echo "==> assembling $APP"
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp $BIN/VoiceCommand $APP/Contents/MacOS/VoiceCommand
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 1)
sed "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > $APP/Contents/Info.plist
# KeyboardShortcuts' localized strings (looked up in Contents/Resources, see Vendor patch 4).
# FluidAudio's only resource bundle is for text-to-speech, which this app never uses.
cp -R $BIN/KeyboardShortcuts_KeyboardShortcuts.bundle $APP/Contents/Resources/

IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z $IDENTITY ]]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -E '"(Apple Development|Developer ID Application)' | head -1 | sed -E 's/.*"(.*)"/\1/' || true)
fi
if [[ -z $IDENTITY ]] && security find-certificate -c "VoiceCommand Local Signing" >/dev/null 2>&1; then
  IDENTITY="VoiceCommand Local Signing"
fi
if [[ -z $IDENTITY ]]; then
  IDENTITY="-"
  echo "!!  No signing identity found: signing ad-hoc."
  echo "!!  macOS will ask for Accessibility and Input Monitoring again after every rebuild."
  echo "!!  Run scripts/make-signing-identity.sh once to get a stable identity."
fi

echo "==> codesign ($IDENTITY)"
codesign --force --options runtime --timestamp=none \
  --entitlements Resources/VoiceCommand.entitlements \
  --sign "$IDENTITY" $APP
codesign --verify --strict --verbose=1 $APP
echo "==> built $APP ($(du -sh $APP | cut -f1)), signed by: $IDENTITY"

if (( OPEN )); then
  pkill -x VoiceCommand 2>/dev/null || true
  for _ in {1..20}; do pgrep -x VoiceCommand >/dev/null || break; sleep 0.25; done
  open $APP
fi
