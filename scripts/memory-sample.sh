#!/bin/sh
set -eu

echo "Per-process RSS sample (MiB):"
ps -axo pid=,rss=,args= | python3 "$(dirname "$0")/memory-processes.py"

if command -v footprint >/dev/null 2>&1; then
  printf '\nApple physical footprint samples:\n'
  ps -axo pid=,rss=,args= | python3 "$(dirname "$0")/memory-processes.py" --pids | while read -r pid group; do
    [ -n "$pid" ] || continue
    printf '%-10s ' "$group"
    footprint -p "$pid" 2>/dev/null | sed -n '2p'
  done
fi
