#!/bin/sh
set -eu

source_image=$1
target_icon=$2
temporary_root=${TMPDIR:-/tmp}
iconset_dir=$(python3 -c 'import sys, tempfile; print(tempfile.mkdtemp(prefix="mica-icon-", suffix=".iconset", dir=sys.argv[1]))' "$temporary_root")

mkdir -p "$(dirname "$target_icon")"
cleanup_iconset() {
    python3 -c 'import shutil, sys; shutil.rmtree(sys.argv[1], ignore_errors=True)' "$iconset_dir"
}
trap cleanup_iconset EXIT HUP INT TERM

sips -z 16 16 "$source_image" --out "$iconset_dir/icon_16x16.png" >/dev/null
sips -z 32 32 "$source_image" --out "$iconset_dir/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$source_image" --out "$iconset_dir/icon_32x32.png" >/dev/null
sips -z 64 64 "$source_image" --out "$iconset_dir/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$source_image" --out "$iconset_dir/icon_128x128.png" >/dev/null
sips -z 256 256 "$source_image" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$source_image" --out "$iconset_dir/icon_256x256.png" >/dev/null
sips -z 512 512 "$source_image" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$source_image" --out "$iconset_dir/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$source_image" --out "$iconset_dir/icon_512x512@2x.png" >/dev/null

iconutil --convert icns --output "$target_icon" "$iconset_dir"
