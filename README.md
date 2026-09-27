# Mica Terminal

**A macOS terminal for keeping project shells, coding agents, and tools together.**

Each tab is a normal interactive `zsh` session. Run Codex, Claude Code, `lazygit`, or any other command in the folder you choose. Mica uses `libvterm` to render terminal interfaces and grows scrollback only as output needs it.

## Get started

Mica requires macOS 14 or later. Install Xcode Command Line Tools and Homebrew, then:

```sh
brew install libvterm pkg-config
make app
open build/Mica.app --args --cwd "$PWD"
```

This opens a shell in the current directory. To run a command immediately and return to a shell when it exits:

```sh
open build/Mica.app --args --cwd "$PWD" --command "git status"
```

Use a project layout when you want commands ready at their prompts for review before you press Return.

## Work across tabs

| Action | Shortcut |
| --- | --- |
| Switch to tab 1–8 | `⌘1`–`⌘8` |
| Switch to the last tab | `⌘9` |
| Open a shell in this tab’s folder | `⌘T` |
| Close the current tab | `⌘W` |
| Choose a tab | `⌘⇧P` |
| Browse scrollback | `⌘⇧S` |
| Copy and paste | `⌘C` / `⌘V` |
| Fold selected output | `⌘⌥F`, then click to expand |
| Resize terminal text | `⌘+` / `⌘−` |

Click a tab to select it. Tabs share the available window width; when there are more tabs than fit, use the overflow menu. Hover over a tab for its full title and details. Codex and Claude Code tabs show their current activity. The status bar shows the selected tab’s folder or current task. Drag a file into the terminal to insert its quoted path without running it.

## Create a project app

To make a separate Mica app for a project, run:

```sh
make new-instance
```

The prompts ask for a name, project folder, and optional startup command. Mica creates a project layout and app on your Desktop. An optional command is placed at the shell prompt; press Return when you are ready to run it. You can open several project apps at once.

The **Mica → New Instance** menu item opens another general Mica window. `make new-instance` creates a named project app; these are different actions.

You can also define tabs in a `.mica` layout file, with one tab per line and tab-separated fields for name, folder, and optional command:

```text
Shell	/Users/me/Projects/work
Claude Code	/Users/me/Projects/work	claude
Codex	/Users/me/Projects/work	codex
Git	/Users/me/Projects/work	lazygit
```

Open the layout with:

```sh
open build/Mica.app --args --layout "$HOME/.config/mica/layouts/work.mica"
```

Layout commands wait at their prompts until you press Return. The Git example uses [lazygit](https://github.com/jesseduffield/lazygit), which you can install with `brew install lazygit`. When a shell exits, Mica closes that tab and resizes the remaining tabs.

Mica loads your zsh configuration, aliases, and plugins. It enables zsh’s built-in completion when your configuration has not already enabled completion; it does not edit your shell startup files.

## Dictate into the current shell

Hold the **left Option (⌥)** key while speaking, then release it. Mica shows the live transcript and inserts the final text into the shell that was active when you started. It does not press Return, so you can review or edit the text before running it. Press `Esc` to cancel.

Speech recognition runs locally using FluidAudio and the multilingual Parakeet Ultra model. The first use downloads about 630 MB and requires an internet connection; Mica loads the cached model only when dictation starts. Transcripts are inserted as recognized, with no separate text-cleanup model. Dictation requires microphone access. Model and library license details are in [`voice/THIRD_PARTY_NOTICES.md`](voice/THIRD_PARTY_NOTICES.md), bundled with the app.

## Troubleshooting and memory

Choose **Help → Open Diagnostic Logs** to open `~/Library/Logs/Mica/`. Logs include the app revision, tab folders, session start and exit, and dictation stages and memory measurements. They do not include recorded audio or transcript text. Logs are capped at 1 MiB. macOS crash reports are in `~/Library/Logs/DiagnosticReports/`.

Mica’s terminal and dictation require macOS 14 or later. Scrollback is allocated as needed and capped at 2 MiB per session. The speech model stays unloaded until dictation starts. Run `make memory` to sample Mica and child-process memory; results depend on your tabs, window size, terminal history, shell setup, and running commands. [`docs/MEMORY-BASELINE.md`](docs/MEMORY-BASELINE.md) describes the available snapshots and their limits.

## Build and validate

```sh
make test       # PTY, UI, project-app, memory-limit, and local CLI-fixture checks
make app        # build the app and local speech helper
make validate   # run tests, build, and check the app bundle
make memory     # sample memory use for running Mica processes
```

Tests use local fixtures and never send prompts to Codex or Claude Code. To run the macOS CI checks, open **Actions → macOS build → Run workflow**. The workflow runs `make validate` and uploads the UI smoke report when available.

Version `0.0.1`, revision `23`.
