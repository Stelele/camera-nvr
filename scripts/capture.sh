#!/usr/bin/env bash
# Pull a short clip from the camera once a working RTSP URL is known.
#
# Usage:
#   export CAM_USER='...' CAM_PASS='...'
#   ./capture.sh [rtsp-url] [seconds] [outfile]
#
# Example:
#   ./capture.sh 'rtsp://192.168.1.46:554/live/ch00_0' 10 sample.mp4
#
# With no URL argument it runs rtsp_probe.sh first and uses whatever it finds.

set -euo pipefail

SECONDS_TO_RECORD="${2:-10}"
OUT="${3:-sample-$(date +%Y%m%d-%H%M%S).mp4}"

if [ $# -ge 1 ]; then
  URL="$1"
else
  if ! PROBE_OUT=$(./rtsp_probe.sh 2>&1); then
    echo "$PROBE_OUT"
    echo
    echo "No RTSP URL found - cannot capture." >&2
    exit 1
  fi
  URL=$(echo "$PROBE_OUT" | awk '/^  HIT/ {print $4; exit}')
  echo "Using discovered URL: $URL"
fi

echo "Recording ${SECONDS_TO_RECORD}s from ${URL} -> ${OUT}"

ffmpeg -hide_banner -loglevel warning \
       -rtsp_transport tcp \
       -i "$URL" \
       -t "$SECONDS_TO_RECORD" \
       -c copy -y "$OUT"

echo
ls -lh "$OUT"
ffprobe -hide_banner -v error \
        -show_entries format=duration,size,bit_rate \
        -show_entries stream=codec_name,codec_type,width,height,avg_frame_rate \
        -of default=noprint_wrappers=1 "$OUT"