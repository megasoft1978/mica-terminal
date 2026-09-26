# Mica Terminal

Mica is a small native macOS terminal workspace for the project sessions currently launched through Zellij. Its PTY/session manager and terminal integration are C; a compact AppKit view handles drawing and macOS input. Terminal escape parsing is provided by `libvterm`. The macOS app uses a Zellij-style tab strip and status bar with the active Alacritty dark palette, and includes an original Mica app icon.

The terminal defaults match the configured Alacritty foreground, background, and 16 ANSI colors. Indexed 256-color sequences use the xterm color cube and grayscale ramp, and 24-bit truecolor is supported. Mica starts with JetBrains Mono at 16 pt to match Alacritty, uses the system fallback if that font is unavailable, and groups emoji modifiers and joined glyphs for macOS emoji rendering.

## Build and run

Requires Xcode Command Line Tools, Homebrew `libvterm`, and a login shell (`zsh` by default).

```sh
brew install libvterm pkg-config
make validate
open build/Mica.app
```

To start Mica in a project directory:

```sh
open build/Mica.app --args --cwd /path/to/project
```

Mica imports the current tab-per-session part of Zellij layouts. Run `make import-layouts` to generate private launch files under `~/.config/mica/layouts` from `~/.config/zellij/layouts`; launch one with `open build/Mica.app --args --layout ~/.config/mica/layouts/traqly.mica`. The generated files stay in your user config and are not included in the public source repository. Each imported tab opens a login zsh with the original startup files and leaves its layout command at the prompt for review; press Return to run it. This preserves the behavior of your existing `prefill.sh` wrapper and keeps commands that stop containers or processes from running on launch. Agent tabs started from Mica's shortcuts still launch immediately.

The Desktop applets that currently launch one Zellij session per project can be replaced by native Mica apps while keeping their names and Desktop positions. `make desktop-apps` previews the detected launchers; `make install-desktop-apps` installs one Mica app bundle per project, updates the matching `launch-*.sh` scripts, and saves the original applets and scripts under `~/.local/share/mica/launcher-backups/`. Each bundle carries its own macOS application identity and project layout, so macOS can track it independently in the Dock, App Switcher, and Spaces. The project apps use the same Mica icon and hard-link the same executable when they are on one volume. This removes the separate Alacritty and Zellij processes from those launches while retaining distinct project windows. Re-running the install target updates the app bundles from a new Mica build. Use `make memory` to compare the live per-process footprint after opening the same project layouts in both versions.

## Controls

- `⌘T`: new shell tab; `⌥⌘C`: Claude Code tab; `⌥⌘X`: Codex tab. The Claude and Codex shortcuts use inline rendering so their transcripts stay in Mica scrollback; Codex also starts in its copy-friendly raw output mode (`Alt-R` toggles it).
- `⇧⌥⌘C`: continue the latest Claude Code session through the existing `yowork` alias; `⇧⌥⌘X`: resume the latest Codex session. Mica displays terminal titles from agent CLIs beside each tab name to make parallel sessions easier to distinguish.
- `⌘W`: close the active tab; `⌘⇧[` / `⌘⇧]`: switch tabs.
- `Ctrl-T` opens the Zellij-style tab mode: arrows or `h/j/k/l` move, `1`–`9` jump, `n` creates a shell, and `x` closes the current tab. `Ctrl-S` opens scroll mode; arrows or `j/k` move by line, arrows or `h/l` move by a screen, `Ctrl-B`/`Ctrl-F` page, and `u/d` move half a screen. `Ctrl-S`, `Ctrl-C`, or Escape returns to the live view.
- `⌘C` copies a selection, or sends Ctrl-C when there is no selection; `⌘V` pastes clipboard text. When the clipboard contains a PNG, TIFF, or JPEG image, `⌘V` forwards Ctrl-V to the foreground TUI so Claude Code can insert its image chip.
- Drag to select text. Use the mouse wheel or `⇧Page Up` / `⇧Page Down` for terminal scrollback. Press Escape to return to the live view. When an application such as Yazi or Lazygit enables mouse reporting, the wheel is sent to that app in normal mode; in `Ctrl-S` scroll mode the wheel always moves Mica's scrollback. Hold Option while clicking and dragging to select text instead. `⇧Return` keeps the existing Alacritty binding used for multiline agent input.
- `⌘+` / `⌘-` changes font size.
- Agent BEL and notification sequences mark a tab with `!`; Mica asks macOS for Dock attention when a background session needs you.

## Tests and agent loop

`make test` exercises a real PTY and libvterm with ANSI, 256-color and truecolor output; emoji, skin-tone, joined and flag Unicode sequences; scrollback limits; wide Unicode cells; text and image clipboard paste; alternate screen; SGR mouse-wheel events; notifications; focus reporting; Shift+Return; grid and pixel resizing; staged layout commands; and fake Claude/Codex launchers. These launch tests use local stubs and do not contact either service. The AppKit smoke test drives Zellij-style tab and scroll shortcuts, checks independent per-project layout and PTY startup, tests text and image clipboard routing, scrolls through older output from a fake Codex launch using Mica's inline command, changes the font, renders a window to `build/ui-smoke.png`, and checks that truecolor and emoji pixels appear. Its text report is `build/ui-smoke-report.txt`. `make validate` runs those tests, builds the app and icon, lints the app plist, and checks the diff for whitespace errors. Scrollback allocates only when needed and stays under 2 MiB per session; input that is waiting for a busy PTY is queued and released as it drains. `scripts/import-zellij-layouts.py` converts local KDL layouts. `scripts/memory-sample.sh` reports per-process RSS and Apple physical footprint for all Mica project apps, Zellij, and Alacritty where available; summed RSS can double-count shared pages.

To ask Codex to fix test/build issues in a bounded loop using GPT-6 Luna:

```sh
scripts/agent-loop.sh 3
```

This calls the configured Codex service through the local CLI, using workspace-write access to this project only. It sends the latest validation log, UI smoke report, and rendered smoke-test screenshot to each repair pass, then reruns `make validate`. The loop itself is covered by a test using local fake `make` and `codex` commands; the test never makes a model request. The loop does not publish or push changes. Set `MICA_AGENT_MODEL` to override the model name.

Use `scripts/check-agent-clis.sh` to verify that Claude Code and Codex are on `PATH` and report their installed versions. The automated PTY suite does not call either service or use account credentials.

For optional Claude Code notification hooks and Codex notification settings, see [`docs/AGENT-NOTIFICATIONS.md`](docs/AGENT-NOTIFICATIONS.md).

## Current baseline

The initial process snapshot is recorded in [`docs/MEMORY-BASELINE.md`](docs/MEMORY-BASELINE.md). Repeat the same project, tab count, scrollback, and workload with `make memory` before drawing conclusions about improvements.
