#!/bin/sh
# Capture the current native view with local PTY commands, then encode website/README assets.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
command -v ffmpeg >/dev/null || { echo 'ffmpeg is required to encode demo assets' >&2; exit 1; }
make build/render-demo
work_dir=$(mktemp -d "$repo_root/build/demo-export.XXXXXX")
build/render-demo "$work_dir/frames"
ffmpeg -v error -y -framerate 10 -i "$work_dir/frames/frame-%04d.png" -frames:v 160 \
    -vf 'scale=1280:-2' -c:v libx264 -crf 24 -preset slow -pix_fmt yuv420p -movflags +faststart -an "$work_dir/mica-demo.mp4"
ffmpeg -v error -y -framerate 10 -i "$work_dir/frames/frame-%04d.png" -frames:v 160 \
    -vf 'scale=900:-2,split[a][b];[a]palettegen=max_colors=128[p];[b][p]paletteuse=dither=none' -loop 0 "$work_dir/mica-demo.gif"
ffmpeg -v error -y -i "$work_dir/frames/frame-0115.png" -frames:v 1 -vf 'scale=1280:-2' "$work_dir/mica-demo-poster.png"
cp "$work_dir/mica-demo.mp4" "$work_dir/mica-demo.gif" "$work_dir/mica-demo-poster.png" docs/assets/
printf 'Created latest-UI MP4, GIF and poster. Source frames: %s/frames\n' "$work_dir"
