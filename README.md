# Mica Terminal

Mica is a small native macOS terminal workspace for the project sessions currently launched through Zellij. Its PTY/session manager and terminal integration are C; a compact AppKit view handles drawing and macOS input. Terminal escape parsing is provided by `libvterm`.

## Build and run

Requires Xcode Command Line Tools, Homebrew `libvterm`, and a login shell (`zsh` by default).

```sh
brew install libvterm pkg-config
make test
make app
open build/Mica.app
```

To start Mica in a project directory:

```sh
open build/Mica.app --args --cwd /path/to/project
```

Mica imports the current tab-per-session part of Zellij layouts. Run `make import-layouts` to generate private launch files under `~/.config/mica/layouts` from `~/.config/zellij/layouts`; launch one with `open build/Mica.app --args --layout ~/.config/mica/layouts/traqly.mica`. The generated files stay in your user config and are not included in the public source repository. Imported commands start automatically in login, interactive zsh after `.zshrc` is loaded, so aliases such as `yowork` remain available.

## Controls

- `⌘T`: new shell tab; `⌥⌘C`: Claude Code tab; `⌥⌘X`: Codex tab.
- `⇧⌥⌘C`: continue the latest Claude Code session through the existing `yowork` alias; `⇧⌥⌘X`: resume the latest Codex session.
- `⌘W`: close the active tab; `⌘⇧[` / `⌘⇧]`: switch tabs.
- `⌘C` copies a selection, or sends Ctrl-C when there is no selection; `⌘V` pastes.
- Drag to select text. Use the mouse wheel or `⇧Page Up` / `⇧Page Down` for terminal scrollback. When an application enables mouse reporting, the wheel is sent to that app.
- `⌘+` / `⌘-` changes font size.
- Agent BEL and notification sequences mark a tab with `!`; Mica asks macOS for Dock attention when a background session needs you.

## Tests and agent loop

`make test` exercises a real PTY and libvterm with scrollback, ANSI colors, wide Unicode cells, large clipboard pastes, alternate screen, mouse mode, notification sequences, focus reporting, and terminal resizing. Scrollback allocates only when needed and stays under 2 MiB per session; input that is waiting for a busy PTY is queued and released as it drains. `make app` builds the macOS bundle. `scripts/import-zellij-layouts.py` converts local KDL layouts. `scripts/memory-sample.sh` reports RSS and Mica's Apple physical footprint where available; summed RSS can double-count shared pages.

To ask Codex to fix test/build issues in a bounded loop using GPT-6 Luna:

```sh
scripts/agent-loop.sh 3
```

This calls the local Codex CLI with workspace-write access to this project only. It does not send Claude/Codex API requests or publish changes. Set `MICA_AGENT_MODEL` to override the model name.

Use `scripts/check-agent-clis.sh` to verify that Claude Code and Codex are on `PATH` and report their installed versions. The automated PTY suite does not call either service or use account credentials.

For optional Claude Code notification hooks and Codex notification settings, see [`docs/AGENT-NOTIFICATIONS.md`](docs/AGENT-NOTIFICATIONS.md).

## Current baseline

The initial process snapshot is recorded in [`docs/MEMORY-BASELINE.md`](docs/MEMORY-BASELINE.md). Repeat the same project, tab count, scrollback, and workload with `make memory` before drawing conclusions about improvements.
