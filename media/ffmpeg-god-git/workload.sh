#!/usr/bin/env bash
set -euo pipefail

FFMPEG_BIN="${1:-./ffmpeg}"
OUT_DIR="${2:-./workload-out}"
THREADS="${FFMPEG_THREADS:-$(nproc)}"
if (( THREADS > 16 )); then
  THREADS=16
fi

ffmpeg_dir="$(cd "$(dirname "$FFMPEG_BIN")" && pwd -P)"
if [[ -n "$ffmpeg_dir" ]]; then
  export LD_LIBRARY_PATH="$ffmpeg_dir/libavcodec:$ffmpeg_dir/libavformat:$ffmpeg_dir/libavutil:$ffmpeg_dir/libswresample:$ffmpeg_dir/libswscale:$ffmpeg_dir/libavfilter:$ffmpeg_dir/libavdevice${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

mkdir -p "$OUT_DIR"

run_cmd() {
  "$FFMPEG_BIN" -hide_banner -loglevel error -y "$@"
}

run_cmd -f lavfi -i "testsrc2=size=1280x720:rate=30" -t 6 \
  -c:v libx264 -preset veryfast -crf 23 -threads "$THREADS" \
  "$OUT_DIR"/h264.mp4

run_cmd -f lavfi -i "testsrc2=size=1280x720:rate=30" -t 6 \
  -c:v libx265 -preset medium -crf 28 -threads "$THREADS" \
  "$OUT_DIR"/h265.mp4

run_cmd -f lavfi -i "testsrc2=size=1280x720:rate=30" -t 6 \
  -c:v libvpx-vp9 -b:v 0 -crf 33 -threads "$THREADS" \
  "$OUT_DIR"/vp9.webm

run_cmd -f lavfi -i "testsrc2=size=1280x720:rate=30" -t 6 \
  -c:v libaom-av1 -cpu-used 6 -crf 30 -threads "$THREADS" \
  "$OUT_DIR"/av1.mp4

run_cmd -f lavfi -i "sine=frequency=1000:sample_rate=48000" -t 6 \
  -c:a aac "$OUT_DIR"/aac.m4a

run_cmd -f lavfi -i "sine=frequency=1000:sample_rate=48000" -t 6 \
  -c:a libopus "$OUT_DIR"/opus.ogg

run_cmd -i "$OUT_DIR"/h264.mp4 -c copy "$OUT_DIR"/remux.mkv
