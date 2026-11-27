#!/usr/bin/env bash
# Launches the app on a running emulator with mock data, opens each screen, checks the app is still
# running, and screenshots it: the Android counterpart of the iOS simulator job.
#
#   tools/screenshots.sh app-debug.apk shots phone
#
# Each shot is also printed as a small base64 JPEG between markers, so it can be read from the log.
set -u
APK=$1
OUT=$2
KIND=$3
PACKAGE=community.reel.app
mkdir -p "$OUT"
adb install -r -g "$APK" >/dev/null || { echo "::error::$KIND: install failed"; exit 1; }
CRASHES=""
FIRST=1
for SCREEN in home setup detail sources player movies calendar library settings status; do
  adb shell am force-stop $PACKAGE
  adb logcat -c
  adb shell am start -n $PACKAGE/.MainActivity --ez ReelMock true --es ReelShot "$SCREEN" >/dev/null
  if [ $FIRST = 1 ]; then sleep 30; FIRST=0; else sleep 14; fi
  if ! adb shell pidof $PACKAGE >/dev/null; then
    echo "::error::$KIND: the app is not running on the $SCREEN screen (crashed?)"
    CRASHES="$CRASHES $KIND/$SCREEN"
    adb logcat -d -b crash | tail -60
    adb logcat -d | grep -E "AndroidRuntime|FATAL" -A 30 | head -80
  fi
  adb exec-out screencap -p > "$OUT/$KIND-$SCREEN.png"
  if command -v convert >/dev/null; then
    convert "$OUT/$KIND-$SCREEN.png" -resize 360x -quality 55 "$OUT/$KIND-$SCREEN-small.jpg"
    echo "=== SHOT $KIND-$SCREEN ==="
    base64 -w0 "$OUT/$KIND-$SCREEN-small.jpg"; echo
    echo "=== END SHOT ==="
  fi
done
if [ -n "$CRASHES" ]; then echo "::error::The app stopped on:$CRASHES"; exit 1; fi
