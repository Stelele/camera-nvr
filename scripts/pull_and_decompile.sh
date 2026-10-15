#!/usr/bin/env bash
# Pull the camera app's APK off a USB-connected Android phone and decompile it.
#
# Prerequisites on the phone:
#   Settings > About > tap Build number 7x  -> enables Developer options
#   Settings > Developer options -> USB debugging ON
#   Then plug in over USB and accept the "Allow USB debugging" prompt
#
# Usage:
#   ./pull_and_decompile.sh                 # auto-detect the camera app
#   ./pull_and_decompile.sh com.example.app  # or name the package explicitly
#
# Output lands in ./jadx-out/ and ./summary.txt

set -uo pipefail
cd "$(dirname "$0")"

ADB="./tools/platform-tools/adb"
JADX="./tools/bin/jadx"
PKG="${1:-}"
mkdir -p apk jadx-out

say() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

# ---------------------------------------------------------------- device check
say "Checking for a connected device"
DEV=$("$ADB" devices | awk 'NR>1 && $2=="device" {print $1; exit}')
if [ -z "$DEV" ]; then
  echo "No device. Enable USB debugging on the phone, plug it in, and accept the prompt."
  echo "Then re-run this script."
  exit 1
fi
echo "Device: $DEV"

# ------------------------------------------------------------- pick the package
if [ -z "$PKG" ]; then
  say "Candidate camera / IPC apps installed"
  CAND=$("$ADB" shell pm list packages -3 2>/dev/null \
        | sed 's/^package://' \
        | grep -iE 'cam|ipc|view|security|smart|home|eye|icsee|xm|vstar|xiongmai|onvif' \
        | grep -viE 'launcher|keyboard|ime|wallpaper' || true)
  echo "${CAND:-<none matched>}"
  PKG=$(echo "$CAND" | head -1)
  [ -z "$PKG" ] && { echo "Could not auto-detect. Re-run with the package name."; exit 1; }
fi
echo "Package: $PKG"

# ------------------------------------------------------------------ pull the APK
say "Pulling APK"
APK_PATH=$("$ADB" shell pm path "$PKG" 2>/dev/null | tr -d '\r' | grep -m1 'base\.apk' | cut -d: -f2)
[ -z "$APK_PATH" ] && { echo "No base.apk found for $PKG"; exit 1; }
echo "Remote: $APK_PATH"

"$ADB" pull "$APK_PATH" "apk/$(basename "$PKG").apk" 2>&1 | tail -2
APK="apk/$(basename "$PKG").apk"
[ -s "$APK" ] || { echo "APK pull failed"; exit 1; }
ls -lh "$APK"

# --------------------------------------------------------------- decompile
say "Decompiling with jadx (this takes a few minutes)"
"$JADX" -d jadx-out --no-res "$APK" 2>&1 | tail -5

# ------------------------------------------------------------------- analyse
say "Grepping for the protocol"
SRCS=$(find jadx-out -name '*.java' | wc -l)
echo "Decompiled Java sources: $SRCS"

{
  echo "=== port 50000 ==="
  grep -rn --include=*.java -E '50000' jadx-out | head -20
  echo
  echo "=== rtsp ==="
  grep -rln --include=*.java -i 'rtsp' jadx-out | head -20
  echo
  echo "=== candidate stream paths ==="
  grep -rn --include=*.java -oE '"/[a-zA-Z0-9_/]{3,30}"' jadx-out \
    | grep -iE 'stream|ch[0-9]|live|video|media|h264|main|play' | head -30
  echo
  echo "=== app classes by package ==="
  find jadx-out -name '*.java' | sed 's#jadx-out/sources/##' | cut -d/ -f1-2 | sort -u | head -30
} > summary.txt 2>&1

cat summary.txt
say "Done - full summary in ./summary.txt, sources in ./jadx-out/"