# Repository instructions

- Keep terminal/session management in C. Keep `src/mica_app.m` as a thin macOS AppKit frontend.
- Use `libvterm` for escape-sequence parsing; do not write a parallel terminal parser. It is vendored in `third_party/libvterm` with the patches listed in `third_party/libvterm/PATCHES.md`; keep new patches minimal and add a fuzz or unit test for each.
- Run `make sanitize` and `make stress` after touching `src/session.c`, `src/mica_app.m` or the vendored library.
- Build with `make app` and validate with `make test` after changes.
- Keep scrollback allocated on demand with a fixed maximum. Avoid per-tab full-capacity allocations.
- Test through the PTY harness before changing the public workflow. Preserve Claude Code, Codex, arbitrary command, and interactive shell sessions.
- Keep layout fixtures local to `examples/`; do not overwrite user configuration or shell startup files.
- Do not add external network calls or send prompts to agent CLIs from tests.
- One Mica process hosts every project window: each window is a `MicaAppDelegate` acting as a window controller (registry `MicaControllers()`), the first is also the NSApplication delegate, and the single menu bar retargets to the key window. Do not add state to globals that should be per window.
