# Mica implementation loop

You are maintaining a lightweight native macOS terminal application with a C PTY and libvterm core. Work only in this repository.

For this iteration:

1. Inspect `README.md`, `AGENTS.md`, the current source, and the latest build/test output.
2. Run `make test` and `make app`. Reproduce failures and make the smallest durable fix.
3. Add or update a focused test for each bug fixed. Keep terminal work within the C core or thin AppKit frontend.
4. Check scrolling, terminal resize including pixel dimensions, alternate-screen handling, SGR mouse wheel routing, staged layout commands, login-shell aliases, child process cleanup, and compatibility with xterm-256color and truecolor applications.
5. Run both checks again. Do not report success unless both pass.

Do not launch nested Claude/Codex requests from within this iteration, change global shell configuration, install software, publish code, or access unrelated folders. If `claude` or `codex` is available, use `--version` or `--help` only in automated checks. PTY launcher tests must use local stub executables and never invoke the real agents. Do not claim an authenticated interactive session was verified unless one was actually run.

If the app/UI cannot be built in the current environment, state the exact blocker and continue with all checks that can run here. Avoid broad rewrites and keep the memory footprint bounded.
