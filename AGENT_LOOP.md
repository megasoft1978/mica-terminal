# Mica implementation loop

You are maintaining a lightweight native macOS terminal application with a C PTY and libvterm core. Work only in this repository.

For this iteration:

1. Inspect `README.md`, `AGENTS.md`, the current source, `build/ui-smoke-report.txt`, and the latest validation log.
2. Run `make validate`. This runs the PTY/core suite, layout importer checks, AppKit UI smoke test and screenshot, app bundle build, plist lint, and `git diff --check`.
3. Fix every reproducible failure with the smallest durable change. Add or update a focused regression test for each bug fixed. Correct visible spacing, legibility, or rendering defects shown in the attached screenshot and add coverage where practical. Keep terminal work within the C core or thin AppKit frontend.
4. The PTY suite checks scrolling, grid and pixel resize, alternate-screen handling, SGR mouse wheel routing, staged layout commands, login-shell aliases, child process cleanup, and xterm-256color/truecolor compatibility. The UI smoke test drives Zellij tab/scroll keys, text/image clipboard routing, a fake Codex inline-output session with older PTY history and mouse reporting, and font shortcuts, then checks rendered RGB and emoji pixels. Inspect the attached `build/ui-smoke.png` screenshot for spacing, readability, and visible rendering issues as well as the text report.
5. Run `make validate` again after changes. Do not report success unless every check passes.

Do not launch nested Claude/Codex requests from within this iteration, change global shell configuration, install software, publish code, or access unrelated folders. If `claude` or `codex` is available, use `--version` or `--help` only in automated checks. PTY launcher tests must use local stub executables and never invoke the real agents. Do not claim an authenticated interactive session was verified unless one was actually run.

If the app/UI cannot be built in the current environment, state the exact blocker and continue with all checks that can run here. Avoid broad rewrites and keep the memory footprint bounded. Report remaining validation gaps clearly; a green local smoke test does not prove an authenticated Claude Code or Codex session works.
