#!/bin/zsh
# Rebuilds the app and captures every review screenshot on the "Dawri Build" simulator.
#
#     ios/Tools/shoot.sh <outdir>
#
# It builds into a temp folder, so nothing lands under ios/. It uses only Dawri Build, and
# leaves that simulator as it found it. Accessibility sizes come from launch arguments, so the
# simulator's own settings stay untouched. The screens need no server and no network.
set -euo pipefail

UDID=B55FEAC2-08EB-460D-9261-E28A60F4B5CC
BUNDLE=com.jaber.dawri
AX3=(-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXL)

if [[ $# -ne 1 ]]; then
  print -u2 "usage: shoot.sh <outdir>"
  exit 2
fi
OUT=${1:A}
ROOT=${0:A:h:h}
case $OUT/ in
  "$ROOT"/*) print -u2 "shoot.sh: the output folder must be outside ios/"; exit 2 ;;
esac
mkdir -p "$OUT"
DERIVED=$(mktemp -d "${TMPDIR:-/private/tmp}/dawri-shoot.XXXXXX")

simulator_state() {
  xcrun simctl list devices | grep "$UDID" | sed -E 's/.*\((Booted|Shutdown|Shutting Down|Booting)\).*/\1/'
}

WAS=$(simulator_state)
cleanup() {
  xcrun simctl status_bar "$UDID" clear 2>/dev/null || true
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  if [[ $WAS == Shutdown ]]; then
    xcrun simctl shutdown "$UDID" 2>/dev/null || true
  fi
  rm -rf "$DERIVED"
}
trap cleanup EXIT

print "Building..."
xcodebuild build -project "$ROOT/Dawri.xcodeproj" -scheme Dawri \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DERIVED" -quiet

if [[ $WAS != Booted ]]; then
  xcrun simctl boot "$UDID"
fi
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl install "$UDID" "$DERIVED/Build/Products/Debug-iphonesimulator/Dawri.app"
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 \
  --cellularBars 4 --wifiBars 3 --dataNetwork wifi

# shoot <name> <seconds to settle> <launch arguments...>
shoot() {
  local name=$1 settle=$2
  shift 2
  xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE" "$@" >/dev/null
  sleep "$settle"
  xcrun simctl io "$UDID" screenshot --type=png "$OUT/$name.png" >/dev/null 2>&1
  print "  $name.png"
}

print "Capturing to $OUT"
for lang in ar en; do
  for theme in light dark; do
    shoot "s01-$lang-$theme" 2.5 -demoScreen s01 -demoLang $lang -demoTheme $theme
    for page in 1 2 3 4 5 6 7 8 9; do
      shoot "gallery$page-$lang-$theme" 2.5 -demoScreen gallery -demoPage $page -demoLang $lang -demoTheme $theme
    done
  done
  shoot "s01-ax3-$lang-light" 2.5 -demoScreen s01 -demoLang $lang -demoTheme light $AX3
  shoot "s01-ax3-$lang-dark" 2.5 -demoScreen s01 -demoLang $lang -demoTheme dark $AX3
  for page in 3 6 8; do
    shoot "gallery$page-ax3-$lang" 2.5 -demoScreen gallery -demoPage $page -demoLang $lang -demoTheme light $AX3
  done
  shoot "pushed-s02-$lang-light" 2.5 -demoScreen s02 -demoLang $lang -demoTheme light
  shoot "pushed-s02-$lang-dark" 2.5 -demoScreen s02 -demoLang $lang -demoTheme dark
  shoot "pushed-s09-$lang-light" 2.5 -demoScreen s09 -demoLang $lang -demoTheme light
  shoot "pushed-s10-$lang-light" 2.5 -demoScreen s10 -demoLang $lang -demoTheme light
  # No theme argument: this screen sets its own, for the white status bar.
  shoot "emergency-$lang" 2.5 -demoScreen s06 -demoLang $lang
done

# Live switches: started in English, and the timed hook switches to Arabic with no restart.
shoot "live-switch-s01-en-to-ar" 3.5 -demoScreen s01 -demoLang en -demoSwitchTo ar -demoTheme light
shoot "live-switch-pushed-en-to-ar" 3.5 -demoScreen s02 -demoLang en -demoSwitchTo ar -demoTheme light
shoot "live-switch-pushed-ar-to-en" 3.5 -demoScreen s02 -demoLang ar -demoSwitchTo en -demoTheme light

print "Done: $(ls "$OUT" | wc -l | tr -d ' ') images in $OUT"
