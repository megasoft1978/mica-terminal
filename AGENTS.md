# Repository instructions

- Keep terminal/session management in C. Keep `src/mica_app.m` as a thin macOS AppKit frontend.
- Use `libvterm` for escape-sequence parsing; do not write a parallel terminal parser.
- Build with `make app` and validate with `make test` after changes.
- Keep scrollback allocated on demand with a fixed maximum. Avoid per-tab full-capacity allocations.
- Test through the PTY harness before changing the public workflow. Preserve Claude Code, Codex, arbitrary command, and interactive shell sessions.
- Keep layout fixtures local to `examples/`; do not overwrite user configuration or shell startup files.
- Do not add external network calls or send prompts to agent CLIs from tests.
