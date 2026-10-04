#!/bin/sh
# Capture the current native view with local PTY commands, then encode website/README assets.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
command -v ffmpeg >/dev/null || { echo 'ffmpeg is required to encode demo assets' >&2; exit 1; }
make build/render-demo
work_dir=$(mktemp -d "$repo_root/build/demo-export.XXXXXX")
build/render-demo "$work_dir/frames"
# A focused project-switching clip: identify the window, choose from the Dock menu titles,
# then show the second named project window.
ffmpeg -v error -y \
    -loop 1 -framerate 10 -t 2.4 -i "$work_dir/frames/project-switch-fieldnote.png" \
    -loop 1 -framerate 10 -t 2.4 -i "$work_dir/frames/project-switch-menu.png" \
    -loop 1 -framerate 10 -t 1.8 -i "$work_dir/frames/project-switch-menu-select.png" \
    -loop 1 -framerate 10 -t 2.4 -i "$work_dir/frames/project-switch-northstar.png" \
    -filter_complex '[0:v]fps=10,format=yuv420p,setpts=PTS-STARTPTS[a];[1:v]fps=10,format=yuv420p,setpts=PTS-STARTPTS[b];[2:v]fps=10,format=yuv420p,setpts=PTS-STARTPTS[c];[3:v]fps=10,format=yuv420p,setpts=PTS-STARTPTS[d];[a][b]xfade=transition=fade:duration=0.2:offset=2.2[ab];[ab][c]xfade=transition=fade:duration=0.2:offset=4.4[abc];[abc][d]xfade=transition=fade:duration=0.2:offset=6.0[out]' \
    -map '[out]' -c:v libx264 -crf 23 -preset slow -pix_fmt yuv420p -movflags +faststart -an "$work_dir/project-switching-demo.mp4"
ffmpeg -v error -y -i "$work_dir/project-switching-demo.mp4" \
    -vf 'fps=8,scale=800:352:flags=lanczos,split[a][b];[a]palettegen=max_colors=64[pal];[b][pal]paletteuse=dither=bayer' \
    -loop 0 "$work_dir/project-switching-demo.gif"
cp "$work_dir/frames/project-switch-menu.png" "$work_dir/project-switching-demo-poster.png"
ffmpeg -v error -y -i "$work_dir/project-switching-demo-poster.png" -frames:v 1 -q:v 2 \
    "$work_dir/project-switching-demo-poster.jpg"
# A captioned feature tour with readable holds. The first scenes establish project identity,
# followed by the terminal, palette, Quick Select, local dictation, timer and SSH profiles.
ffmpeg -v error -y \
    -loop 1 -framerate 10 -t 2.0 -i "$work_dir/frames/project-switch-fieldnote.png" \
    -loop 1 -framerate 10 -t 2.0 -i "$work_dir/frames/project-switch-menu.png" \
    -loop 1 -framerate 10 -t 2.0 -i "$work_dir/frames/project-switch-northstar.png" \
    -loop 1 -framerate 10 -t 1.8 -i "$work_dir/frames/feature-tabs.png" \
    -loop 1 -framerate 10 -t 2.2 -i "$work_dir/frames/feature-palette.png" \
    -loop 1 -framerate 10 -t 2.2 -i "$work_dir/frames/feature-quick-select.png" \
    -loop 1 -framerate 10 -t 2.2 -i "$work_dir/frames/feature-dictation.png" \
    -loop 1 -framerate 10 -t 2.0 -i "$work_dir/frames/feature-focus-timer.png" \
    -loop 1 -framerate 10 -t 2.0 -i "$work_dir/frames/feature-ssh.png" \
    -filter_complex '[0:v]fps=10,scale=1280:564:force_original_aspect_ratio=decrease,pad=1280:564:(ow-iw)/2:(oh-ih)/2,setsar=1,format=yuv420p[a];[1:v]fps=10,scale=1280:564:force_original_aspect_ratio=decrease,pad=1280:564:(ow-iw)/2:(oh-ih)/2,setsar=1,format=yuv420p[b];[2:v]fps=10,scale=1280:564:force_original_aspect_ratio=decrease,pad=1280:564:(ow-iw)/2:(oh-ih)/2,setsar=1,format=yuv420p[c];[3:v]fps=10,scale=1280:564:force_original_aspect_ratio=decrease,pad=1280:564:(ow-iw)/2:(oh-ih)/2,setsar=1,format=yuv420p[d];[4:v]fps=10,scale=1280:564:force_original_aspect_ratio=decrease,pad=1280:564:(ow-iw)/2:(oh-ih)/2,setsar=1,format=yuv420p[e];[5:v]fps=10,scale=1280:564:force_original_aspect_ratio=decrease,pad=1280:564:(ow-iw)/2:(oh-ih)/2,setsar=1,format=yuv420p[f];[6:v]fps=10,scale=1280:564:force_original_aspect_ratio=decrease,pad=1280:564:(ow-iw)/2:(oh-ih)/2,setsar=1,format=yuv420p[g];[7:v]fps=10,scale=1280:564:force_original_aspect_ratio=decrease,pad=1280:564:(ow-iw)/2:(oh-ih)/2,setsar=1,format=yuv420p[h];[8:v]fps=10,scale=1280:564:force_original_aspect_ratio=decrease,pad=1280:564:(ow-iw)/2:(oh-ih)/2,setsar=1,format=yuv420p[i];[a][b][c][d][e][f][g][h][i]concat=n=9:v=1:a=0[out]' \
    -map '[out]' -c:v libx264 -crf 23 -preset slow -pix_fmt yuv420p -movflags +faststart -an "$work_dir/mica-demo.mp4"
ffmpeg -v error -y -i "$work_dir/mica-demo.mp4" \
    -vf 'fps=6,scale=800:352:flags=lanczos,split[a][b];[a]palettegen=max_colors=64[pal];[b][pal]paletteuse=dither=bayer' \
    -loop 0 "$work_dir/mica-demo.gif"
cp "$work_dir/frames/project-switch-fieldnote.png" "$work_dir/mica-demo-poster.png"
cp "$work_dir/mica-demo.mp4" "$work_dir/mica-demo.gif" "$work_dir/mica-demo-poster.png" docs/assets/
cp "$work_dir/project-switching-demo.mp4" "$work_dir/project-switching-demo.gif" "$work_dir/project-switching-demo-poster.jpg" docs/assets/
cp "$work_dir/frames/quick-select-demo.png" docs/assets/quick-select-demo.png
cp "$work_dir/frames/command-palette-demo.png" docs/assets/command-palette-demo.png
cp "$work_dir/frames/prompt-navigation-demo.png" docs/assets/prompt-navigation-demo.png
cp "$work_dir/frames/vocabulary-correction-demo.png" docs/assets/vocabulary-correction-demo.png
cp "$work_dir/frames/ssh-profiles-demo.png" docs/assets/ssh-profiles-demo.png
cp "$work_dir/frames/timer-menu-bar-demo.png" docs/assets/timer-menu-bar-demo.png
printf 'Created project-switching and feature-tour MP4/GIF assets, posters and feature captures. Source frames: %s/frames\n' "$work_dir"
