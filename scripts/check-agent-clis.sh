#!/bin/sh
set -eu
for name in claude codex; do
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "$name: not found on PATH" >&2
    exit 1
  fi
  printf '%s: ' "$name"
  "$name" --version
 done
