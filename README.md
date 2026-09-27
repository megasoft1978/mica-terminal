# Mica Terminal

Mica is a native macOS terminal for working across project folders and command-line tools such as Claude Code, Codex, and zsh. Each tab is a regular zsh session. Mica uses `libvterm` to render terminal output and keeps scrollback in memory only as it is needed.

## Install and open

Mica requires macOS 13 or later for terminal use. Dictation requires macOS 14 or later and a microphone. To build from source, install Xcode Command Line Tools and Homebrew, then run:

```sh
brew install libvterm pkg-config
make app
open build/Mica.app --args --cwd "$PWD"
```

This opens a shell in the current folder. `--command` runs the given command as the session starts:

```sh
open build/Mica.app --args --cwd "$PWD" --command "git status"
```

For commands you want to inspect before running, use a project layout or create a project instance below. Those commands are placed at the prompt; press Return to run them.

## Everyday use

- Click a tab or use `⌘1`–`⌘8` to switch tabs. `⌘9` selects the last tab.
- `⌘T` opens a zsh tab in the selected tab's folder. `⌘W` closes the selected tab.
- `⌘⇧P` opens the tab picker. Use arrows or `1`–`9`, then Return to select.
- `⌘⇧S` opens scrollback navigation. Use arrows or `j`/`k`; press Esc to return to live output.
- `⌘C` copies selected text; `⌘V` pastes. Dropping a file into the terminal inserts its shell-quoted path without running it.
- Select long output and press `⌘⌥F` to fold it. Click the folded row to expand it.
- `⌘+` and `⌘-` change the terminal text size.

The tab bar shares the window width across tabs and offers a menu for tabs that do not fit. Hover over a tab to see its full title, command, folder, and recent activity. Claude Code and Codex titles follow their current visible action. The footer shows the selected tab's folder and current activity. Hold the left Option key to dictate; the footer also shows the numbered-tab and new-tab shortcuts.

## Set up a project

Run `make new-instance` to create a project layout and a separate Mica app in `~/Desktop/`. The setup asks for a project name, folder, and optional startup command. Leave the command blank for a plain shell; otherwise it appears at the prompt for review before you press Return. Each project app can run alongside other Mica instances.

You can also create a tab layout by adding one tab per line to a `.mica` file. Separate the tab name, folder, and optional command with tab characters:

```text
Shell<TAB>/Users/me/Projects/work<TAB>
Claude<TAB>/Users/me/Projects/work<TAB>claude
Codex<TAB>/Users/me/Projects/work<TAB>codex
Git<TAB>/Users/me/Projects/work<TAB>lazygit
```

Open it with:

```sh
open build/Mica.app --args --layout "$HOME/.config/mica/layouts/work.mica"
```

Layout commands are prefilled at their shell prompts and wait for Return. The Git tab uses [lazygit](https://github.com/jesseduffield/lazygit); install it with `brew install lazygit`. Exiting a shell closes its tab and the remaining tabs resize to fill the window.

Mica loads your zsh setup, aliases, and plugins. If completion is not already enabled in that setup, Mica enables zsh's built-in context-aware completion for its sessions without editing your shell startup files.

## Dictation

Hold the **left Option (⌥)** key, speak in English or Italian, and release it to finish. Mica displays the live transcript, then inserts the raw result into the shell that was selected when dictation began. It does not press Return, so you can review or edit the text before running it. Press Esc to cancel.

Speech recognition runs locally with FluidAudio's multilingual Parakeet Ultra model. The first use downloads about 630 MB; the model stays cached on disk and loads only when dictation starts. No separate AI cleanup model runs on the transcript. Audio is processed locally. The speech model is licensed CC BY 4.0 and attributed to Moondream and NVIDIA; FluidAudio is Apache 2.0. Notices are included in the app and listed in [`voice/THIRD_PARTY_NOTICES.md`](voice/THIRD_PARTY_NOTICES.md).

## Logs and memory

Choose **Help → Open Diagnostic Logs** to open `~/Library/Logs/Mica/`. The plain-text launch log records the app revision, tab folders, shell start and exit results, dictation stages, helper exit status, and peak helper memory. It does not record shell command text, transcripts, or audio. Logs are capped at 1 MiB. macOS crash reports are in `~/Library/Logs/DiagnosticReports/`.

Mica caps scrollback at 2 MiB per session and allocates it as needed. The speech model is not loaded until dictation starts. Use `make memory` to sample the memory used by a running Mica instance and its child processes; results depend on the number of tabs, window size, scrollback, and running commands.

## Build and checks

```sh
make test       # PTY, UI, project-app, memory-limit, and local CLI-fixture checks
make app        # build Mica and its local speech helper
make validate   # run tests, build the app, and check the app bundle
make test-voice # build the speech helper
make memory     # sample memory use for running Mica processes
```

Tests use local fixtures and do not send prompts to Claude Code or Codex. The macOS CI workflow runs `make validate` and uploads the UI smoke report and screenshot.

Version `0.0.1`, revision `21`.
