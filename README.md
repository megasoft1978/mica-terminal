# Mica Terminal

**One native macOS workspace for project shells, coding agents, and the tools around them.**

Mica keeps each project in its own set of terminal tabs. Run Codex, Claude Code, Git tools, or a regular shell side by side, with live agent activity, project launchers, local voice dictation, and a shared focus timer.

> macOS 14 or later · Native AppKit · C PTY core · `libvterm`

## Get Mica

**[Project website](https://megasoft1978.github.io/mica-terminal/)** · **[Releases](https://github.com/megasoft1978/mica-terminal/releases)** · **[Source](https://github.com/megasoft1978/mica-terminal)**

There isn’t a packaged release yet. To build Mica locally, install Xcode Command Line Tools and Homebrew, then run:

```sh
brew install libvterm pkg-config
git clone https://github.com/megasoft1978/mica-terminal.git
cd mica-terminal
make app
open build/Mica.app
```

The first dictation use downloads the local speech model (about 630 MB). Mica requests microphone access only when you start dictation.

## Why Mica

- **Stay with the project.** Give a project its own named tabs, folders, and ready-to-review startup commands.
- **Keep your terminal yours.** Mica runs ordinary interactive `zsh` sessions. Use Codex, Claude Code, `lazygit`, or any command; Mica doesn’t take over your shell configuration.
- **See what agents are doing.** Agent tabs show activity and when they need input. Scrollback, text selection, and normal terminal input stay close at hand.
- **Speak a command.** Hold left Option, dictate, then review or edit the inserted text before pressing Return. Recognition runs locally after the initial model download.
- **Keep a little focus.** A shared focus timer follows you across Mica windows and can notify you when a focus or break period ends.

## A few shortcuts

| Action | Shortcut |
| --- | --- |
| Switch tabs | `⌘1`–`⌘8`, `⌘9` |
| New tab / close tab | `⌘T` / `⌘W` |
| Choose a tab / browse scrollback | `⌘⇧P` / `⌘⇧S` |
| Dictate | Hold left `⌥` |
| Resize terminal text | `⌘+` / `⌘−` |

Run `make new-instance` to create a project launcher. Use **Project → Settings…** to edit its name and tabs. A `.mica` layout can also define named tabs, folders, and optional commands.

## Build and contribute

```sh
make app       # build Mica.app and its local speech helper
make test      # run the PTY, UI, launcher, and fixture checks
make validate  # run tests, build, and check the app bundle
```

Tests use local fixtures and never send prompts to agent CLIs. See [memory notes](docs/MEMORY-BASELINE.md), [agent notifications](docs/AGENT-NOTIFICATIONS.md), and [all workflows](https://github.com/megasoft1978/mica-terminal/actions).
