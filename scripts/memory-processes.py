#!/usr/bin/env python3
"""Summarize Mica and configured coding-agent process memory."""

from __future__ import annotations

import argparse
import os
import re
import shlex
import sys


def classify(executable: str) -> str | None:
    normalized = executable.lower().replace("\\", "/")
    name = os.path.basename(normalized)
    if re.search(r"\.app/contents/macos/mica$", normalized):
        return "Mica"
    if name == "claude":
        return "Claude Code"
    if name == "codex" and ".app/contents/macos/" not in normalized:
        return "Codex"
    return None


def parse_process_line(line: str) -> tuple[int, int, str] | None:
    fields = line.strip().split(None, 2)
    if len(fields) != 3 or not fields[0].isdigit() or not fields[1].isdigit():
        return None
    try:
        argv = shlex.split(fields[2])
    except ValueError:
        return None
    if not argv:
        return None
    group = classify(argv[0])
    if group is None:
        return None
    return int(fields[0]), int(fields[1]), group


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pids", action="store_true", help="emit only PID and group for footprint sampling")
    args = parser.parse_args()

    totals: dict[str, float] = {}
    counts: dict[str, int] = {}
    for line in sys.stdin:
        process = parse_process_line(line)
        if process is None:
            continue
        pid, value, group = process
        if args.pids:
            print(f"{pid}\t{group}")
            continue
        rss_mib = value / 1024
        totals[group] = totals.get(group, 0) + rss_mib
        counts[group] = counts.get(group, 0) + 1
        print(f"{rss_mib:7.1f} MiB  pid {pid:<7}  {group}")

    if not args.pids:
        print("Totals (sum of process RSS; shared pages may be double-counted):")
        for group in sorted(totals):
            print(f"{totals[group]:7.1f} MiB  {counts[group]:2d} process(es)  {group}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
