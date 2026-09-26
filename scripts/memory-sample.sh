#!/bin/sh
set -eu

echo "Per-process RSS sample (MiB):"
ps -axo pid,rss,comm,args | awk '
NR == 1 { next }
tolower($3) ~ /\/(ps|awk)$/ { next }
/(Mica\.app\/Contents\/MacOS\/Mica|\/zellij([[:space:]]|$)| zellij([[:space:]]|$)|[Aa]lacritty\.app\/Contents\/MacOS\/alacritty|\/bin\/alacritty([[:space:]]|$)|\/claude([[:space:]]|$)|\/codex([[:space:]]|$))/ {
  rss = $2 / 1024
  if ($0 ~ /Mica\.app\/Contents\/MacOS\/Mica/) group = "Mica"
  else if ($0 ~ /[Aa]lacritty\.app\/Contents\/MacOS\/alacritty|\/bin\/alacritty([[:space:]]|$)/) group = "Alacritty"
  else if ($0 ~ /zellij/) group = "Zellij"
  else if ($0 ~ /claude/) group = "Claude Code"
  else if ($0 ~ /codex/) group = "Codex"
  else next
  count[group]++
  total[group] += rss
  printf "%7.1f MiB  pid %-7s  %s\n", rss, $1, group
}
END {
  print "Totals (sum of process RSS; shared pages may be double-counted):"
  for (group in total) printf "%7.1f MiB  %2d process(es)  %s\n", total[group], count[group], group
}'

if command -v footprint >/dev/null 2>&1; then
  printf '\nApple physical footprint samples:\n'
  ps -axo pid,comm,args | awk '
    NR == 1 || tolower($2) ~ /\/(ps|awk)$/ { next }
    /Mica\.app\/Contents\/MacOS\/Mica/ { print $1, "Mica"; next }
    /[Aa]lacritty\.app\/Contents\/MacOS\/alacritty|\/bin\/alacritty([[:space:]]|$)/ { print $1, "Alacritty"; next }
    /zellij/ { print $1, "Zellij" }
  ' | while read -r pid group; do
    [ -n "$pid" ] || continue
    printf '%-10s ' "$group"
    footprint -p "$pid" 2>/dev/null | sed -n '2p'
  done
fi
