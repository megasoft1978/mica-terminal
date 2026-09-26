#!/usr/bin/env python3
"""Keep memory reports scoped to executable processes, not matching command text."""

import importlib.util
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "mica_memory_processes", ROOT / "scripts" / "memory-processes.py"
)
assert SPEC and SPEC.loader
MEMORY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MEMORY)


def main() -> None:
    fixtures = [
        '101 2048 "/Users/test/Desktop/Project Alpha.app/Contents/MacOS/Mica" --layout /tmp/alpha.mica',
        "104 256 /Users/test/.local/bin/claude --continue",
        "105 768 /opt/homebrew/bin/codex --no-alt-screen",
        "106 4096 /bin/zsh -lc 'echo /Users/test/Mica.app/Contents/MacOS/Mica codex'",
        "107 8192 /Applications/Codex.app/Contents/MacOS/Codex",
        "108 1024 /opt/homebrew/bin/example-cli --interactive",
    ]
    expected = [
        (101, 2048, "Mica"),
        (104, 256, "Claude Code"),
        (105, 768, "Codex"),
    ]
    parsed = [MEMORY.parse_process_line(line) for line in fixtures]
    assert [process for process in parsed if process is not None] == expected

    sample = "\n".join(fixtures) + "\n"
    rss = subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "memory-processes.py")],
        input=sample, text=True, capture_output=True, check=True,
    ).stdout
    assert "101" in rss and "Mica" in rss
    assert "106" not in rss and "107" not in rss and "108" not in rss
    pids = subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "memory-processes.py"), "--pids"],
        input=sample, text=True, capture_output=True, check=True,
    ).stdout.splitlines()
    assert pids[0] == "101\tMica"
    assert all(not line.startswith(("106\t", "107\t", "108\t")) for line in pids)

    print("memory process classification tests passed")


if __name__ == "__main__":
    main()
