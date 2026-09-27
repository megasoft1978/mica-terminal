#!/bin/sh
set -eu

source_image=$1
target_icon=$2
temporary_root=${TMPDIR:-/tmp}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
temporary_dir=$(python3 -c 'import sys, tempfile; print(tempfile.mkdtemp(prefix="mica-icon-", dir=sys.argv[1]))' "$temporary_root")

mkdir -p "$(dirname "$target_icon")"
cleanup_temporary_dir() {
    python3 -c 'import shutil, sys; shutil.rmtree(sys.argv[1], ignore_errors=True)' "$temporary_dir"
}
trap cleanup_temporary_dir EXIT HUP INT TERM

sips -z 1024 1024 "$source_image" --out "$temporary_dir/icon.png" >/dev/null
python3 "$script_dir/png-to-icns.py" "$temporary_dir/icon.png" "$target_icon"
