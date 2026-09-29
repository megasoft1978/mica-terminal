#!/usr/bin/env python3
"""Checks the exact git command shape Mica's "New Worktree Tab…" runs, in a throwaway repository."""
import os
import subprocess
import tempfile
from pathlib import Path


def run(*args, cwd):
    return subprocess.run(args, cwd=cwd, check=True, text=True, capture_output=True,
                          env={**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
                               "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid"})


with tempfile.TemporaryDirectory(prefix="mica-worktree-") as temporary:
    root = Path(temporary)
    repo = root / "app"
    repo.mkdir()
    run("git", "init", "-q", "-b", "main", cwd=repo)
    (repo / "a.txt").write_text("hello\n")
    run("git", "add", "a.txt", cwd=repo)
    run("git", "commit", "-q", "-m", "first", cwd=repo)
    destination = root / "app-agent-fix-login"
    # Same arguments as MicaAppDelegate newWorktreeTab:
    run("git", "-C", str(repo), "worktree", "add", "-b", "agent/fix-login", str(destination), cwd=root)
    assert (destination / "a.txt").read_text() == "hello\n"
    # A linked worktree has a .git *file*; Mica reads the branch through it.
    pointer = (destination / ".git").read_text()
    assert pointer.startswith("gitdir:")
    gitdir = Path(pointer.split(":", 1)[1].strip())
    assert (gitdir / "HEAD").read_text().strip() == "ref: refs/heads/agent/fix-login"
print("worktree command tests passed")
