# Mica Terminal

Mica is a small native macOS terminal workspace for the project sessions currently launched through Zellij. Its PTY/session manager and terminal integration are C; a compact AppKit view handles drawing and macOS input. Terminal escape parsing is provided by `libvterm`. The macOS app uses a Zellij-style tab strip and status bar with the active Alacritty dark palette, and includes an original Mica app icon.

The terminal defaults match the configured Alacritty foreground, background, and 16 ANSI colors. Indexed 256-color sequences use the xterm color cube and grayscale ramp, and 24-bit truecolor is supported. Mica starts with JetBrains Mono at 16 pt to match Alacritty, uses the system fallback if that font is unavailable, and groups emoji modifiers and joined glyphs for macOS emoji rendering.

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

Mica imports the current tab-per-session part of Zellij layouts. Run `make import-layouts` to generate private launch files under `~/.config/mica/layouts` from `~/.config/zellij/layouts`; launch one with `open build/Mica.app --args --layout ~/.config/mica/layouts/traqly.mica`. The generated files stay in your user config and are not included in the public source repository. Each imported tab opens a login zsh with the original startup files and leaves its layout command at the prompt for review; press Return to run it. This preserves the behavior of your existing `prefill.sh` wrapper and keeps commands that stop containers or processes from running on launch. Agent tabs started from Mica's shortcuts still launch immediately.

## Controls

- `⌘T`: new shell tab; `⌥⌘C`: Claude Code tab; `⌥⌘X`: Codex tab. The Claude and Codex shortcuts use inline rendering so their transcripts stay in Mica scrollback; Codex also starts in its copy-friendly raw output mode (`Alt-R` toggles it).
- `⇧⌥⌘C`: continue the latest Claude Code session through the existing `yowork` alias; `⇧⌥⌘X`: resume the latest Codex session. Mica displays terminal titles from agent CLIs beside each tab name to make parallel sessions easier to distinguish.
- `⌘W`: close the active tab; `⌘⇧[` / `⌘⇧]`: switch tabs.
- `Ctrl-T` opens the Zellij-style tab mode: arrows or `h/j/k/l` move, `1`–`9` jump, `n` creates a shell, and `x` closes the current tab. `Ctrl-S` opens scroll mode; arrows or `j/k` move by line, Page Up/Down move by a screen, and `Ctrl-S`, `Ctrl-C`, or Escape returns to the live view.
- `⌘C` copies a selection, or sends Ctrl-C when there is no selection; `⌘V` pastes.
- Drag to select text. Use the mouse wheel or `⇧Page Up` / `⇧Page Down` for terminal scrollback. Press Escape to return to the live view. When an application such as Yazi or Lazygit enables mouse reporting, the wheel is sent to that app; hold Option while clicking and dragging to select text instead. `⇧Return` keeps the existing Alacritty binding used for multiline agent input.
- `⌘+` / `⌘-` changes font size.
- Agent BEL and notification sequences mark a tab with `!`; Mica asks macOS for Dock attention when a background session needs you.

## Tests and agent loop

`make test` exercises a real PTY and libvterm with ANSI, 256-color and truecolor output; emoji, skin-tone, joined and flag Unicode sequences; scrollback limits; wide Unicode cells; large clipboard pastes; alternate screen; SGR mouse-wheel events; notifications; focus reporting; Shift+Return; grid and pixel resizing; staged layout commands; and fake Claude/Codex launchers. These launch tests use local stubs and do not contact either service. Scrollback allocates only when needed and stays under 2 MiB per session; input that is waiting for a busy PTY is queued and released as it drains. `make app` builds the macOS bundle and generates its `.icns` file from `assets/mica-icon.png`. `scripts/import-zellij-layouts.py` converts local KDL layouts. `scripts/memory-sample.sh` reports per-process RSS and Apple physical footprint for Mica, Zellij, and Alacritty where available; summed RSS can double-count shared pages.

To ask Codex to fix test/build issues in a bounded loop using GPT-6 Luna:

```sh
scripts/agent-loop.sh 3
```

This calls the configured Codex service through the local CLI, using workspace-write access to this project only. The test suite itself makes no model requests, and the loop does not publish or push changes. Set `MICA_AGENT_MODEL` to override the model name.

Use `scripts/check-agent-clis.sh` to verify that Claude Code and Codex are on `PATH` and report their installed versions. The automated PTY suite does not call either service or use account credentials.

For optional Claude Code notification hooks and Codex notification settings, see [`docs/AGENT-NOTIFICATIONS.md`](docs/AGENT-NOTIFICATIONS.md).

## Current baseline

The initial process snapshot is recorded in [`docs/MEMORY-BASELINE.md`](docs/MEMORY-BASELINE.md). Repeat the same project, tab count, scrollback, and workload with `make memory` before drawing conclusions about improvements.
