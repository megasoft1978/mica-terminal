# Mica Terminal

Mica is a lightweight macOS terminal for zsh, Claude Code, Codex, and other command line tools. It uses `libvterm` for terminal behavior and keeps scrollback allocated only as needed.

## Install and open

Requires macOS 13 or later, Xcode Command Line Tools, and Homebrew.

```sh
brew install libvterm pkg-config
make app
open build/Mica.app --args --cwd "$PWD"
```

Mica opens a zsh session in the selected folder. To open a terminal with a command ready to run:

```sh
open build/Mica.app --args --cwd "$PWD" --command "git status"
```

## Use tabs

Tabs are ordinary zsh sessions. A new tab opens in the current tab's folder. To run Claude Code, Codex, or another tool, put its command in a project layout tab.

| Shortcut | Action |
| --- | --- |
| `⌘1`–`⌘8` | Switch to tab 1–8 |
| `⌘9` | Switch to the last tab |
| `⌘T` / `⌘W` | Open / close a tab |
| `⌘⇧[` / `⌘⇧]` | Previous / next tab |
| `⌘⇧P` | Open the tab picker; use arrows or `1`–`9`, then `Esc` |
| `⌘⇧S` | Browse scrollback; use arrows or `j`/`k`, then `Esc` for live output |
| `⌘C` / `⌘V` | Copy selection / paste text or send an image to the active CLI |
| `⌘⌥F` | Fold selected scrollback lines; click the summary to expand |
| `⌘+` / `⌘-` | Change terminal text size |

Click a tab to switch to it, or press `⌘1`–`⌘9`. Tabs share the available width until they reach a minimum size; use the `…` menu to find tabs that no longer fit. Hover over a tab to see its full title. While Claude Code or Codex runs, the tab and footer show its latest visible action and update when terminal output changes. Hover shows the full title, command, folder, and recent agent action. The footer shows the selected tab's full folder path, shortening the beginning when space is limited, plus its current command or status. Its shortcuts are Dictate, numbered tabs, and New Tab.

To open a separate Mica process for the same project, choose **Mica → New Instance** or press `⌘⌥N`. Each project app created by the desktop-app setup has its own bundle identity, so different project apps can run side by side.

The mode badge appears only while **TAB PICKER** or **SCROLLBACK** is active. With no badge, keystrokes go to the normal shell. Press `Esc` to leave either mode. Codex keeps its own `Ctrl+T` transcript shortcut; Mica's picker and scrollback use `⌘⇧P` and `⌘⇧S` so they do not intercept Codex or shell keys.

Drop a file onto the terminal to insert its shell-quoted path at the prompt. Mica does not run the path; press Return when ready.

To compact long output in scrollback, select its lines and press `⌘⌥F`. Click the folded row to expand it again.

## Dictate into the shell

Dictation needs macOS 14 or later and a microphone. Hold the **left Option (⌥)** key to start, speak English or Italian, then release it to finish. The overlay shows the live transcript as it arrives. Mica inserts the transcript at the prompt and closes the overlay automatically; it does not press Return, so review it before running. Press `Esc` while recording to cancel.

Dictation uses FluidAudio's multilingual Parakeet Ultra model for English and Italian. The first use downloads about 630 MB; model files stay cached on disk and load only when you dictate. Mica shows an animated loading state and reports download or model-preparation progress when the helper provides it. Audio and recognition run locally. Mica inserts the raw transcript directly; no second language model or cleanup pass is run. The transcript is inserted into the tab that was active when recording began. Very short recordings with no recognized speech show a retry message; this is not a model crash.

The speech model is licensed CC BY 4.0 and attributed to Moondream and NVIDIA. FluidAudio is Apache 2.0. Full notices ship inside the app bundle and are listed in [`voice/THIRD_PARTY_NOTICES.md`](voice/THIRD_PARTY_NOTICES.md).

## Create a project instance

Run:

```sh
make new-instance
```

Mica asks for a name, project folder, and optional startup command. It creates a `.mica` layout in `~/.config/mica/layouts/` and a separate app in `~/Desktop/`. The command can be `claude`, `codex`, or any shell command; Mica places it at the prompt, and you press Return to run it. Leave it blank to open a plain zsh shell. This setup does not need a hand-written layout or launcher script.

## Edit a project layout

A layout contains one tab per line, with tab-separated name, folder, and optional command:

```text
Shell<TAB>/Users/me/Projects/work<TAB>
Claude<TAB>/Users/me/Projects/work<TAB>claude
Codex<TAB>/Users/me/Projects/work<TAB>codex
Git<TAB>/Users/me/Projects/work<TAB>lazygit
```

Replace each `<TAB>` with a tab character. Commands appear at the shell prompt and run when you press Return. Open a layout with:

```sh
open build/Mica.app --args --layout "$HOME/.config/mica/layouts/work.mica"
```

Each tab is a regular zsh session. In a Git tab, Mica puts `lazygit` at the prompt; press Return to start it. Install it with `brew install lazygit` if needed. Older layouts using `mica-git` are automatically changed to the `lazygit` command. Exiting a shell closes its tab, and the other tabs resize to share the available width.

`make desktop-apps` previews existing project launchers. `make install-desktop-apps` installs app bundles for them.

## zsh completion

Mica loads your existing zsh setup, including aliases and plugins. If it does not already enable completion, Mica initializes zsh's built-in context-aware completion for the session. The completion cache stays under your normal `ZDOTDIR`; Mica does not edit your startup files. Tab completion then uses the commands and completion definitions available on your system.

Optional plugins such as [zsh-autosuggestions](https://github.com/zsh-users/zsh-autosuggestions) and [fzf-tab](https://github.com/Aloxaf/fzf-tab) add history suggestions and searchable completion menus. Configure them in your own zsh setup; Mica does not install or configure plugins.

## Diagnostics

Mica writes a plain-text log for each launch to `~/Library/Logs/Mica/`. Choose **Help → Open Diagnostic Logs** to find it. Logs include the app revision, tab folders, shell start/exit results, and dictation progress, stage duration, helper exit status, and peak helper memory. Mica does not log shell command text, transcripts, or audio. Each log is capped at 1 MiB. macOS crash reports, if a process crashes before it can log an exit, are stored under `~/Library/Logs/DiagnosticReports/`.

## Build and check

```sh
make test       # PTY, UI, completion, memory limits, and local CLI stubs
make validate   # tests, app build, and bundle checks
make memory     # sample memory used by running Mica and agent processes
make test-voice # test local speech helper components
```

The optimized app build creates the native Mica app and its local speech helper. Project apps made by `make install-desktop-apps` include both. Tests use local fixtures and do not contact Claude or Codex. Scrollback is capped at 2 MiB per session and allocated as needed.

### Memory sample

On this Mac, revision 19's VSC-VPP app used about 35 MiB physical footprint after 28 seconds with seven idle zsh tabs. Its RSS was about 86 MiB, and peak footprint was 77 MiB. This sample excludes the dictation helper and running agent tools. The Ultra model cache measured 603 MiB on disk and loads only when dictation starts. Recent cached-model dictations loaded in 0.19–0.43 seconds. Recognition helper peak RSS was 77–87 MiB for 0.5–82 seconds of audio; recognition took 8.44 seconds for 8 seconds of audio, 25.84 seconds for 25 seconds, 49.10 seconds for 49 seconds, and 81.58 seconds for 82 seconds. A 0.5-second capture contained no recognized speech. Mica does not retain a second cleanup model in memory or send transcripts to one. FluidVoice was not running during these measurements, so there is no directly comparable FluidVoice process-memory sample here. Actual usage varies with window size, scrollback, and command-line tools.

Version `0.0.1`, revision `20`.
