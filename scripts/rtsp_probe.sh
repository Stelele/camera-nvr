#!/usr/bin/env bash
# Probe the camera's RTSP server for a usable stream URL.
#
# Usage:
#   export CAM_USER='...' CAM_PASS='...'
#   ./rtsp_probe.sh [host]
#
# Exits 0 if a working stream URL is found, 1 if none respond.
# Credentials are read from the environment - never stored in this file.

set -uo pipefail

HOST="${1:-192.168.1.46}"
PORT="${RTSP_PORT:-554}"

# XiongMai/XM SDK URL conventions plus the common ONVIF and generic variants.
PATHS=(
  # XM native
  /live/ch00_0 /live/ch00_1 /live/ch01_0 /live/ch01_1
  /livestream /livestream0 /livestream_0
  /bstream0 /bstream1 /record/ch00_0 /record/ch00_1
  /MediaChannel/video /MediaChannel/video0
  # Generic
  /stream0 /stream1 /stream2 /stream3 /main /sub /h264
  /live/ch0 /live/ch1 /ch0 /ch1 /video0 /video1
  /cam0 /channel0 /channel1 /preview /ipc /s0 /s1
  # ONVIF-style
  /Streaming/Channels/101 /Streaming/Channels/102
  # CONFIRMED WORKING on this unit
  /onvif1 /onvif2
  /cam/realmonitor
)

auth=()
[ -n "${CAM_USER:-}" ] && auth=(-u "${CAM_USER}:${CAM_PASS:-}")

describe() {
  local path="$1"
  curl -s -o /tmp/rtsp_sdp.$$ -w '%{http_code}' \
       --max-time 5 --request DESCRIBE -H 'Accept: application/sdp' \
       "${auth[@]}" "rtsp://${HOST}:${PORT}${path}" 2>/dev/null
}

echo "RTSP probe: ${HOST}:${PORT}"
[ ${#auth[@]} -eq 0 ] && echo "(no CAM_USER set - probing anonymously)"
echo

for p in "${PATHS[@]}"; do
  code=$(describe "$p")
  if [ "$code" != "405" ]; then
    echo "  HIT  $code  $p"
    head -c 400 /tmp/rtsp_sdp.$$ 2>/dev/null
    echo
    rm -f /tmp/rtsp_sdp.$$
    exit 0
  fi
done

rm -f /tmp/rtsp_sdp.$$
echo "  All ${#PATHS[@]} paths returned 405 (method not allowed)."
echo "  No usable RTSP stream on this device."
exit 1