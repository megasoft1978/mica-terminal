#!/bin/zsh
# Scripted, fictional demo: types commands like a person and prints sample output.
type_cmd() { print -n "fieldnote% "; sleep 0.5; for ((i=1;i<=${#1};i++)); do print -n -- "${1[i]}"; sleep 0.045; done; sleep 0.35; print; }
while [ ! -f /tmp/mica-demo-rec/go ]; do sleep 0.1; done; rm -f /tmp/mica-demo-rec/go; sleep 0.8
type_cmd "git log --oneline -3"
print -P "%F{yellow}3f9c1a2%f Sync filter buttons with aria-pressed\n%F{yellow}8be07d4%f Add project board drag handles\n%F{yellow}1a4d6e9%f Keep card order after reload"
sleep 1.0
type_cmd "make test"
sleep 0.6
for t in "filters keep aria-pressed in sync" "cards keep their order after reload" "drag handles are keyboard reachable"; do print -P "%F{green}✓%f $t"; sleep 0.7; done
print -P "%B3 passed%b in 0.42s"
sleep 1.4
type_cmd "codex 'add a dark mode toggle'"
sleep 0.5
for l in "Reading app.js and styles.css…" "Editing styles.css (+18 lines)" "Editing app.js (+11 lines)" "Running tests… 3 passed"; do print -P "%F{cyan}•%f $l"; sleep 0.9; done
print -P "%F{green}Done.%f Dark mode toggle added."
sleep 3
