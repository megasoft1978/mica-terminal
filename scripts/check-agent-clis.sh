#!/bin/sh
set -eu

if [ "$#" -eq 0 ]; then
  echo "usage: $0 command [command ...]" >&2
  exit 2
fi

if [ ! -x /bin/zsh ]; then
  echo "zsh: /bin/zsh is not available" >&2
  exit 1
fi

/bin/zsh -lic '
  for name in "$@"; do
    if ! command -v "$name" >/dev/null 2>&1; then
      print -u2 "$name: not found in the login shell PATH"
      exit 1
    fi
    printf "%s: " "$name"
    "$name" --version || exit $?
  done
' mica "$@"
