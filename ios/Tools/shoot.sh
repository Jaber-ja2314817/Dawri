#!/bin/zsh
# Rebuilds the app and captures the review screenshots on the "Dawri Build" simulator.
#
#     ios/Tools/shoot.sh [--only <glob>] [--derived <folder>] <outdir>
#
# Rows live in ios/Tools/shots/*.tsv, one file per builder. Blank lines and lines starting with
# # are skipped. Columns, separated by tabs:
#
#     name    settle seconds    flags    launch arguments
#
# Each row shoots ar and en, light and dark, as <name>-<lang>-<theme>[-ax3].png.
# Flags, comma separated, or - for none:
#     ax3      also shoots all four at AX3
#     switch   starts in the other language, and -demoSwitchTo lands on this row's language
#     island   after the settle, opens Settings (com.apple.Preferences) over the app, waits 2 s,
#              shoots, then quits Settings. The app is then in the background with its Live
#              Activity running, so the shot holds the real compact Dynamic Island. The shot takes
#              --mask=black, because the default screenshot leaves out the Island's region and
#              with it the activity drawn there. The Island is always black and takes no theme,
#              so these rows shoot light only, as <name>-<lang>-light.png: a dark shot would be
#              the same picture
#
# --only keeps the rows whose name matches the glob. --derived reuses a build folder, which must
# be outside ios/, and keeps it. Otherwise the build goes to a temp folder that is removed.
#
# It uses only Dawri Build, and leaves that simulator as it found it. Accessibility sizes come
# from launch arguments, so the simulator's own settings stay untouched. The screens need no
# server and no network.
set -euo pipefail

UDID=B55FEAC2-08EB-460D-9261-E28A60F4B5CC
BUNDLE=com.jaber.dawri
PREFERENCES=com.apple.Preferences
AX3=(-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXL)
ROOT=${0:A:h:h}

usage() {
  print -u2 "usage: shoot.sh [--only <glob>] [--derived <folder>] <outdir>"
  exit 2
}

ONLY='*'
DERIVED=''
while [[ $# -gt 0 ]]; do
  case $1 in
    --only) [[ $# -ge 2 ]] || usage; ONLY=$2; shift 2 ;;
    --derived) [[ $# -ge 2 ]] || usage; DERIVED=${2:A}; shift 2 ;;
    --*) usage ;;
    *) break ;;
  esac
done
[[ $# -eq 1 ]] || usage
OUT=${1:A}

refuse_inside_ios() {
  case $1/ in
    "$ROOT"/*) print -u2 "shoot.sh: the $2 folder must be outside ios/"; exit 2 ;;
  esac
}
refuse_inside_ios "$OUT" output
KEEP_DERIVED=1
if [[ -z $DERIVED ]]; then
  DERIVED=$(mktemp -d "${TMPDIR:-/private/tmp}/dawri-shoot.XXXXXX")
  KEEP_DERIVED=0
fi
refuse_inside_ios "$DERIVED" build
mkdir -p "$OUT"

simulator_state() {
  xcrun simctl list devices | grep "$UDID" | sed -E 's/.*\((Booted|Shutdown|Shutting Down|Booting)\).*/\1/'
}

WAS=$(simulator_state)
cleanup() {
  xcrun simctl status_bar "$UDID" clear 2>/dev/null || true
  xcrun simctl terminate "$UDID" "$PREFERENCES" 2>/dev/null || true
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  if [[ $WAS == Shutdown ]]; then
    xcrun simctl shutdown "$UDID" 2>/dev/null || true
  fi
  if [[ $KEEP_DERIVED == 0 ]]; then
    rm -rf "$DERIVED"
  fi
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

# The first launch after a boot or an install is cold and slow, and once drew S01 in place of the
# first row's screen. One launch that is thrown away warms the app up before the first shot.
xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE" -demoLang en -demoScreen settings >/dev/null
sleep 8
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true

# shoot <file name> <seconds to settle> <island: 0 or 1> <launch arguments...>
shoot() {
  local name=$1 settle=$2 island=$3
  shift 3
  xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE" "$@" >/dev/null
  sleep "$settle"
  if [[ $island == 1 ]]; then
    xcrun simctl launch "$UDID" "$PREFERENCES" >/dev/null
    sleep 2
  fi
  local -a mask
  [[ $island == 1 ]] && mask=(--mask=black)
  xcrun simctl io "$UDID" screenshot --type=png "${mask[@]}" "$OUT/$name.png" >/dev/null 2>&1
  if [[ $island == 1 ]]; then
    xcrun simctl terminate "$UDID" "$PREFERENCES" 2>/dev/null || true
  fi
  print "  $name.png"
}

# row <name> <settle> <flags> <launch arguments as one string>
row() {
  local name=$1 settle=$2 flags=$3 line=$4
  local -a args language themes
  args=(${(z)line})
  args=(${(Q)args})
  local island=0
  themes=(light dark)
  if [[ ,$flags, == *,island,* ]]; then
    island=1
    themes=(light)
  fi
  for lang in ar en; do
    if [[ ,$flags, == *,switch,* ]]; then
      local other=en
      [[ $lang == en ]] && other=ar
      language=(-demoLang $other -demoSwitchTo $lang)
    else
      language=(-demoLang $lang)
    fi
    for theme in $themes; do
      shoot "$name-$lang-$theme" "$settle" $island "${args[@]}" "${language[@]}" -demoTheme $theme
      if [[ ,$flags, == *,ax3,* ]]; then
        shoot "$name-$lang-$theme-ax3" "$settle" $island "${args[@]}" "${language[@]}" -demoTheme $theme "${AX3[@]}"
      fi
    done
  done
}

print "Capturing to $OUT"
matched=0
for table in "$ROOT"/Tools/shots/*.tsv(N); do
  while IFS=$'\t' read -r name settle flags line || [[ -n ${name:-} ]]; do
    [[ -z ${name:-} || $name == \#* ]] && continue
    [[ $name == ${~ONLY} ]] || continue
    matched=$((matched + 1))
    row "$name" "$settle" "$flags" "$line"
  done < "$table"
done
if [[ $matched == 0 ]]; then
  print -u2 "shoot.sh: no row matches '$ONLY'"
  exit 1
fi

print "Done: $matched rows, $(ls "$OUT" | wc -l | tr -d ' ') images in $OUT"
