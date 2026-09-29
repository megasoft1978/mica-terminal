# Contributing

1. `brew install libvterm pkg-config`
2. `make test` before and after your change; `make validate` before opening a pull request.
3. Follow [AGENTS.md](AGENTS.md): keep session management in C, keep `src/mica_app.m` a thin AppKit frontend, use `libvterm` for escape sequences, and keep scrollback bounded.
4. Add or update a test in `tests/` for behavior changes. Tests must not touch user configuration or call the network.
5. Keep commits small and messages concise.

Contributions are accepted under the project’s [MIT License](LICENSE).
