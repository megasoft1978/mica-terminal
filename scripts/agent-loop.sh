#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ITERATIONS=${1:-3}
MODEL=${MICA_AGENT_MODEL:-gpt-6-luna}
PROMPT_FILE="$ROOT/AGENT_LOOP.md"
LOG_FILE="$ROOT/build/agent-loop.log"
mkdir -p "$ROOT/build"
: > "$LOG_FILE"

case "$ITERATIONS" in
  ''|*[!0-9]*) echo "usage: $0 [max-iterations]" >&2; exit 2 ;;
esac
if [ "$ITERATIONS" -lt 1 ]; then echo "iterations must be at least 1" >&2; exit 2; fi
command -v codex >/dev/null 2>&1 || { echo "codex CLI is required" >&2; exit 127; }

if ! make -C "$ROOT" test > "$LOG_FILE" 2>&1 || ! make -C "$ROOT" app >> "$LOG_FILE" 2>&1; then
  cat "$LOG_FILE" >&2
  echo "Baseline checks must pass before the agent loop starts." >&2
  exit 1
fi

for iteration in $(seq 1 "$ITERATIONS"); do
  echo "Mica agent iteration $iteration/$ITERATIONS (model: $MODEL)"
  {
    cat "$PROMPT_FILE"
    if [ -s "$LOG_FILE" ]; then
      printf '\nPrevious build/test output follows. Fix any failures before adding more work:\n'
      tail -n 120 "$LOG_FILE"
    fi
  } | codex exec --model "$MODEL" -c model_reasoning_effort=medium --sandbox workspace-write --ignore-user-config --ephemeral -C "$ROOT" - || \
    echo "Codex iteration returned a non-zero status; running project checks anyway." >&2
  if make -C "$ROOT" test > "$LOG_FILE" 2>&1 && make -C "$ROOT" app >> "$LOG_FILE" 2>&1; then
    cat "$LOG_FILE"
    echo "Mica checks passed after iteration $iteration."
    exit 0
  fi
  cat "$LOG_FILE" >&2
  echo "Checks still fail; the next bounded iteration will inspect and repair them." >&2
done

echo "Mica checks did not pass within $ITERATIONS iteration(s)." >&2
exit 1
