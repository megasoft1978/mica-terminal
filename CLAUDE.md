## Orchestration (yowork + codex)
- Verify: `make app && make test`; full gate `make validate`; after touching `src/session.c`, `src/mica_app.m` or vendored libvterm also `make sanitize` and `make stress`.
- Browser/UI test: n/a (AppKit UI smoke runs inside `make validate`; no browser).
- Push policy: no `git push`, tags or signing from automated loops (docs/IMPROVEMENT-PLAN.md); release steps in docs/RELEASING.md.
- Project overrides: terminal/session logic stays in C; `src/mica_app.m` stays a thin AppKit frontend; no nested claude/codex calls inside the implementation loop (AGENT_LOOP.md); PTY tests use stub executables only.
