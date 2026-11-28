#!/usr/bin/env bash
# Launches the app on a running emulator with mock data, opens each screen, checks the app is still
# running, and screenshots it: the Android counterpart of the iOS simulator job.
#
#   tools/screenshots.sh app-debug.apk shots phone
#
# Each shot is also printed as a small base64 JPEG between markers, so it can be read from the log.
# Every adb call has a time limit: when the emulator itself stops, the run says so and ends
# instead of waiting for a device that will never come back.
set -u
APK=$1
OUT=$2
KIND=$3
PACKAGE=community.reel.app
mkdir -p "$OUT"
a() { timeout 60 adb "$@"; }
alive() { [ "$(timeout 15 adb get-state 2>/dev/null)" = "device" ]; }
a install -r -g "$APK" >/dev/null || { echo "::error::$KIND: install failed"; exit 1; }
CRASHES=""
FIRST=1
for SCREEN in home setup detail sources player movies calendar library settings status; do
  if ! alive; then
    echo "::error::$KIND: the emulator stopped responding before the $SCREEN screen"
    CRASHES="$CRASHES $KIND/emulator"
    break
  fi
  a shell am force-stop $PACKAGE
  a logcat -c
  a shell am start -n $PACKAGE/.MainActivity --ez ReelMock true --es ReelShot "$SCREEN" >/dev/null
  if [ $FIRST = 1 ]; then sleep 30; FIRST=0; else sleep 14; fi
  if ! alive; then
    echo "::error::$KIND: the emulator stopped responding on the $SCREEN screen"
    CRASHES="$CRASHES $KIND/$SCREEN(emulator)"
    break
  fi
  if ! a shell pidof $PACKAGE >/dev/null; then
    echo "::error::$KIND: the app is not running on the $SCREEN screen (crashed?)"
    CRASHES="$CRASHES $KIND/$SCREEN"
    a logcat -d -b crash | tail -60
    a logcat -d | grep -E "AndroidRuntime|FATAL" -A 30 | head -80
  fi
  a exec-out screencap -p > "$OUT/$KIND-$SCREEN.png" || continue
  if python3 -c "import PIL" 2>/dev/null; then
    python3 - "$OUT/$KIND-$SCREEN.png" "$OUT/$KIND-$SCREEN-small.jpg" <<'PY'
import sys
from PIL import Image
image = Image.open(sys.argv[1]).convert("RGB")
image.thumbnail((480, 480))
image.save(sys.argv[2], quality=55)
PY
    echo "=== SHOT $KIND-$SCREEN ==="
    base64 -w0 "$OUT/$KIND-$SCREEN-small.jpg"; echo
    echo "=== END SHOT ==="
  fi
done
if [ -n "$CRASHES" ]; then echo "::error::The app stopped on:$CRASHES"; exit 1; fi
