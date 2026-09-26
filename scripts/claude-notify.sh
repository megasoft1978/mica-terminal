#!/bin/sh
set -eu

command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
body=$(printf '%s' "$input" | jq -r '(.message // .notification_type // "Needs your attention") | gsub("[[:cntrl:]]"; " ")' 2>/dev/null || printf '%s' 'Needs your attention')
sequence=$(printf '\033]777;notify;Claude Code;%s\007' "$body")
jq -nc --arg sequence "$sequence" '{terminalSequence: $sequence}'
