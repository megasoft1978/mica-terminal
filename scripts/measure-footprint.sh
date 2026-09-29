#!/bin/sh
# Sums Apple's "phys_footprint" (what Activity Monitor calls Memory) over every running process whose
# command line contains a substring. It does not launch or quit anything.
#
#   scripts/measure-footprint.sh "Mica.app/Contents/MacOS/Mica"
#   scripts/measure-footprint.sh "iTerm.app/Contents"
#   scripts/measure-footprint.sh "Wispr Flow"
#
# For a fair comparison start each app fresh with one window and its default settings, let it sit idle for
# ten seconds, then measure. Helper processes (Electron, XPC) are included because they are part of the cost.
set -eu
[ $# -eq 1 ] || { echo "usage: $0 <command-line substring>" >&2; exit 2; }
total=0
count=0
for pid in $(pgrep -f "$1"); do
    line=$(footprint -p "$pid" 2>/dev/null | awk '/phys_footprint:/ { print $2 " " $3; exit }') || continue
    [ -n "$line" ] || continue
    mb=$(echo "$line" | awk '{ if ($2 == "KB") print $1 / 1024; else if ($2 == "GB") print $1 * 1024; else print $1 }')
    total=$(echo "$total $mb" | awk '{ print $1 + $2 }')
    count=$((count + 1))
done
echo "$1: $(echo "$total" | awk '{ printf "%.0f", $1 }') MB footprint over $count process(es)"
