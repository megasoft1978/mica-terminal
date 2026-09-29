#!/bin/sh
# Compact reviewer view of a Codex cycle: the report, the diff summary and the check results, nothing else.
# Usage: scripts/review-cycle.sh <cycle-number>   (keeps the reviewing model's token use small)
set -eu
n=${1:?cycle number}
cd "$(dirname "$0")/.."
echo "== report =="; cat "build/codex-report-$n.md"
echo "== diff =="; git diff --stat | tail -15
echo "== checks (last line of each) =="
for check in "test" "sanitize FUZZ_SEEDS=2" "stress STRESS_SEEDS=3"; do
  if make $check > "build/review-$n.log" 2>&1; then echo "PASS make $check"; else echo "FAIL make $check"; grep -E "FAIL|rror|Assertion|SUMMARY" "build/review-$n.log" | head -5; fi
done
