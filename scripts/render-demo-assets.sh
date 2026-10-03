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
    -c:v libx264 -crf 24 -preset slow -pix_fmt yuv420p -movflags +faststart -an "$work_dir/base.mp4"
# Hold feature stills long enough to read; both are captures of the current native UI.
ffmpeg -v error -y -i "$work_dir/base.mp4" -loop 1 -t 2 -i "$work_dir/frames/quick-select-demo.png" \
    -loop 1 -t 2 -i "$work_dir/frames/command-palette-demo.png" \
    -loop 1 -t 2 -i "$work_dir/frames/prompt-navigation-demo.png" \
    -loop 1 -t 2 -i "$work_dir/frames/vocabulary-correction-demo.png" \
    -loop 1 -t 3 -i "$work_dir/frames/ssh-profiles-demo.png" \
    -filter_complex '[0:v]setpts=PTS-STARTPTS,scale=1280:564:force_original_aspect_ratio=decrease,pad=1280:564:(ow-iw)/2:(oh-ih)/2,setsar=1[a];[1:v]fps=10,scale=1280:564:force_original_aspect_ratio=decrease,pad=1280:564:(ow-iw)/2:(oh-ih)/2,setsar=1[b];[2:v]fps=10,scale=1280:564:force_original_aspect_ratio=decrease,pad=1280:564:(ow-iw)/2:(oh-ih)/2,setsar=1[c];[3:v]fps=10,scale=1280:564:force_original_aspect_ratio=decrease,pad=1280:564:(ow-iw)/2:(oh-ih)/2,setsar=1[d];[4:v]fps=10,scale=1280:564:force_original_aspect_ratio=decrease,pad=1280:564:(ow-iw)/2:(oh-ih)/2,setsar=1[e];[5:v]fps=10,scale=1280:564:force_original_aspect_ratio=decrease,pad=1280:564:(ow-iw)/2:(oh-ih)/2,setsar=1[f];[a][b][c][d][e][f]concat=n=6:v=1:a=0[out]' \
    -map '[out]' -c:v libx264 -crf 24 -preset slow -pix_fmt yuv420p -movflags +faststart -an "$work_dir/mica-demo.mp4"
ffmpeg -v error -y -framerate 10 -i "$work_dir/frames/frame-%04d.png" -loop 1 -t 1.5 -i "$work_dir/frames/quick-select-demo.png" \
    -loop 1 -t 1.5 -i "$work_dir/frames/command-palette-demo.png" \
    -loop 1 -t 1.5 -i "$work_dir/frames/prompt-navigation-demo.png" \
    -loop 1 -t 1.5 -i "$work_dir/frames/vocabulary-correction-demo.png" \
    -loop 1 -t 2 -i "$work_dir/frames/ssh-profiles-demo.png" \
    -filter_complex '[0:v]fps=8,scale=800:352:force_original_aspect_ratio=decrease,pad=800:352:(ow-iw)/2:(oh-ih)/2,setsar=1[base];[1:v]fps=8,scale=800:352:force_original_aspect_ratio=decrease,pad=800:352:(ow-iw)/2:(oh-ih)/2,setsar=1[q];[2:v]fps=8,scale=800:352:force_original_aspect_ratio=decrease,pad=800:352:(ow-iw)/2:(oh-ih)/2,setsar=1[p];[3:v]fps=8,scale=800:352:force_original_aspect_ratio=decrease,pad=800:352:(ow-iw)/2:(oh-ih)/2,setsar=1[n];[4:v]fps=8,scale=800:352:force_original_aspect_ratio=decrease,pad=800:352:(ow-iw)/2:(oh-ih)/2,setsar=1[v];[5:v]fps=8,scale=800:352:force_original_aspect_ratio=decrease,pad=800:352:(ow-iw)/2:(oh-ih)/2,setsar=1[s];[base][q][p][n][v][s]concat=n=6:v=1:a=0,split[a][b];[a]palettegen=max_colors=18[pal];[b][pal]paletteuse=dither=none[out]' \
    -map '[out]' -frames:v 250 -loop 0 "$work_dir/mica-demo.gif"
ffmpeg -v error -y -i "$work_dir/frames/frame-0090.png" -frames:v 1 -vf 'scale=1280:-2' "$work_dir/mica-demo-poster.png"
cp "$work_dir/mica-demo.mp4" "$work_dir/mica-demo.gif" "$work_dir/mica-demo-poster.png" docs/assets/
cp "$work_dir/frames/quick-select-demo.png" docs/assets/quick-select-demo.png
cp "$work_dir/frames/command-palette-demo.png" docs/assets/command-palette-demo.png
cp "$work_dir/frames/prompt-navigation-demo.png" docs/assets/prompt-navigation-demo.png
cp "$work_dir/frames/vocabulary-correction-demo.png" docs/assets/vocabulary-correction-demo.png
cp "$work_dir/frames/ssh-profiles-demo.png" docs/assets/ssh-profiles-demo.png
printf 'Created latest-UI MP4, GIF, poster and feature captures, including SSH profiles. Source frames: %s/frames\n' "$work_dir"
