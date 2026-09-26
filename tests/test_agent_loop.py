#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import tempfile
from typing import List, Optional, Tuple


ROOT = Path(__file__).resolve().parent.parent


def run_scenario(
    make_success_after: Optional[int],
) -> Tuple[subprocess.CompletedProcess, List[str], str, int]:
    with tempfile.TemporaryDirectory(prefix="mica-agent-loop-") as temporary:
        temp = Path(temporary)
        bin_dir = temp / "bin"
        bin_dir.mkdir()
        make_count = temp / "make-count"
        args_file = temp / "codex-args.json"
        prompt_file = temp / "codex-prompt.txt"
        log_file = temp / "validation.log"
        threshold = "never" if make_success_after is None else str(make_success_after)

        make_stub = bin_dir / "make"
        make_stub.write_text(
            "#!/bin/sh\n"
            "count=0\n"
            "[ ! -f \"$MICA_LOOP_MAKE_COUNT\" ] || count=$(cat \"$MICA_LOOP_MAKE_COUNT\")\n"
            "count=$((count + 1))\n"
            "printf '%s' \"$count\" > \"$MICA_LOOP_MAKE_COUNT\"\n"
            "if [ \"$MICA_LOOP_MAKE_SUCCESS_AFTER\" != never ] && [ \"$count\" -ge \"$MICA_LOOP_MAKE_SUCCESS_AFTER\" ]; then\n"
            "  printf 'STUB_VALIDATION_PASSED\\n'\n"
            "  exit 0\n"
            "fi\n"
            "printf 'STUB_VALIDATION_FAILURE_%s\\n' \"$count\"\n"
            "exit 1\n",
            encoding="utf-8",
        )
        make_stub.chmod(0o755)

        codex_stub = bin_dir / "codex"
        codex_stub.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            "with open(os.environ['MICA_LOOP_CODEX_ARGS'], 'w') as f: json.dump(sys.argv[1:], f)\n"
            "with open(os.environ['MICA_LOOP_CODEX_PROMPT'], 'w') as f: f.write(sys.stdin.read())\n",
            encoding="utf-8",
        )
        codex_stub.chmod(0o755)

        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{bin_dir}{os.pathsep}{env['PATH']}",
                "MICA_AGENT_MODEL": "gpt-6-luna",
                "MICA_AGENT_LOOP_LOG": str(log_file),
                "MICA_LOOP_MAKE_COUNT": str(make_count),
                "MICA_LOOP_MAKE_SUCCESS_AFTER": threshold,
                "MICA_LOOP_CODEX_ARGS": str(args_file),
                "MICA_LOOP_CODEX_PROMPT": str(prompt_file),
            }
        )
        completed = subprocess.run(
            [str(ROOT / "scripts" / "agent-loop.sh"), "1"],
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        args = json.loads(args_file.read_text(encoding="utf-8"))
        prompt = prompt_file.read_text(encoding="utf-8")
        count = int(make_count.read_text(encoding="utf-8"))
        return completed, args, prompt, count


def main() -> None:
    passing, args, prompt, count = run_scenario(make_success_after=2)
    assert passing.returncode == 0, passing.stdout + passing.stderr
    assert count == 2, f"expected baseline and post-repair validation, saw {count} calls"
    assert "--model" in args and args[args.index("--model") + 1] == "gpt-6-luna"
    assert "--sandbox" in args and args[args.index("--sandbox") + 1] == "workspace-write"
    assert "-i" in args and args[args.index("-i") + 1] == str(ROOT / "build" / "ui-smoke.png")
    assert "Fix every failure" in prompt
    assert "STUB_VALIDATION_FAILURE_1" in prompt, "baseline failure was not fed back to Codex"
    assert "[PASS]" in prompt, "the AppKit report was not fed back to Codex"
    assert "passed after iteration 1" in passing.stdout

    bounded, _, _, bounded_count = run_scenario(make_success_after=None)
    assert bounded.returncode == 1, "the loop must fail if validation stays red"
    assert bounded_count == 2, f"one repair iteration should run two validations, saw {bounded_count}"
    assert "did not pass within 1 iteration" in bounded.stderr
    print("agent feedback loop tests passed")


if __name__ == "__main__":
    main()
