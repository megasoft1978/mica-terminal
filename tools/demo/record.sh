#!/bin/sh
# Records docs/assets/mica-demo.{mp4,gif,-poster.png}: a scripted, fictional demo in an isolated HOME using
# /Applications/Mica.app. Needs Screen Recording permission for the app running this script, and ~40 s with
# the demo window frontmost (do not type meanwhile). Capture is window-only (screencapture -l), so nothing else is recorded.
set -eu
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd); w=/tmp/mica-demo-rec
rm -rf "$w"; mkdir -p "$w/home" "$w/ws" "$w/ws2"
clang -fobjc-arc -framework Cocoa "$here/wl.m" -o "$w/wl"; clang -fobjc-arc -Wno-deprecated-declarations -framework Cocoa "$here/act.m" -o "$w/act"
sed "s|/tmp/demo|$w|g" "$here/typing.sh" > "$w/typing.sh"; chmod +x "$w/typing.sh"
for d in ws ws2; do (cd "$w/$d" && git init -q && git config user.name Demo && git config user.email demo@example.invalid && echo x > app.js && git add . && git commit -qm init); done
printf "PROMPT='fieldnote%% '\nRPROMPT=''\n[ \"\$PWD:A\" = \"/private$w/ws\" ] && [ -z \"\$MICA_DEMO_RUN\" ] && { export MICA_DEMO_RUN=1; $w/typing.sh; }\n" > "$w/home/.zshrc"
printf '# Mica project: Fieldnote\nShell\t%s/ws\nPreview\t%s/ws2\nAgent\t%s/ws2\n' "$w" "$w" "$w" > "$w/layout.mica"
open -n -a /Applications/Mica.app --env HOME="$w/home" --env ZDOTDIR="$w/home" --env MICA_ORIGINAL_ZDOTDIR="$w/home" --env PATH=/opt/homebrew/bin:/usr/bin:/bin --args --layout "$w/layout.mica" --project-name Fieldnote
sleep 3; pid=$(pgrep -f "layout $w/layout.mica" | head -1); "$w/act" "$pid" >/dev/null; sleep 1.5
id=$("$w/wl" | grep -i fieldnote | head -1 | cut -d'|' -f1)
screencapture -x -v -V 27 -l"$id" "$w/rec.mov" & sleep 1.2; touch "$w/go"; wait
kill "$pid" 2>/dev/null || true
# The window is inset in the recording; find its bounds from the brightness of one frame, then crop.
ffmpeg -v error -y -ss 5 -i "$w/rec.mov" -frames:v 1 "$w/full.png"
crop=$(python3 - "$w/full.png" <<'P'
import sys
from PIL import Image
im=Image.open(sys.argv[1]).convert('L'); W,H=im.size; px=im.load()
xs=[x for x in range(W) if sum(1 for y in range(0,H,8) if px[x,y]>=20)>H/8*0.6]
ys=[y for y in range(H) if sum(1 for x in range(0,W,8) if px[x,y]>=20)>W/8*0.6]
print(f"crop={max(xs)-min(xs)+1}:{max(ys)-min(ys)+1}:{min(xs)}:{min(ys)}")
P
)
a="$root/docs/assets"
ffmpeg -v error -y -ss 0.9 -t 23 -i "$w/rec.mov" -vf "$crop,scale=1280:-2,fps=30" -c:v libx264 -crf 26 -preset slow -pix_fmt yuv420p -movflags +faststart -an "$a/mica-demo.mp4"
ffmpeg -v error -y -ss 0.9 -t 23 -i "$w/rec.mov" -vf "$crop,scale=900:-2,fps=10,split[a][b];[a]palettegen=max_colors=64[p];[b][p]paletteuse=dither=none" "$a/mica-demo.gif"
ffmpeg -v error -y -ss 16 -i "$w/rec.mov" -frames:v 1 -vf "$crop,scale=1280:-2" "$a/mica-demo-poster.png"
echo "wrote $a/mica-demo.{mp4,gif} and mica-demo-poster.png"
