<p align="center">
  <img src="docs/icon-180.png" width="96" height="96" alt="Mica app icon">
</p>

<h1 align="center">Mica</h1>

<p align="center">
  <strong>Your terminal, voice typing and focus timer in one light Mac app.</strong><br>
  Every project gets its own window, and the whole thing idles around 55–60 MB,<br>
  where a terminal plus a dictation app on the same Mac takes about 770 MB.
</p>

<p align="center">
  <a href="https://github.com/megasoft1978/mica-terminal/releases/tag/v0.1.0-alpha.11"><img src="https://img.shields.io/badge/release-0.1.0--alpha.11-blue" alt="Release 0.1.0 alpha 11"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B%20%C2%B7%20Apple%20silicon-555" alt="macOS 14 or later, Apple silicon">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT license"></a>
</p>

<p align="center">
  <a href="https://megasoft1978.github.io/mica-terminal/">Website</a> ·
  <a href="https://github.com/megasoft1978/mica-terminal/releases/download/v0.1.0-alpha.11/Mica.zip"><strong>Download</strong></a> ·
  <a href="https://github.com/megasoft1978/mica-terminal/releases/tag/v0.1.0-alpha.11">Release notes</a> ·
  <a href="LICENSE">MIT license</a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: light)" srcset="docs/assets/mica-light.png">
    <img src="docs/assets/mica-dark.png" alt="Mica window with project tabs, a git log and passing tests, a focus timer and shortcut hints" width="900">
  </picture>
</p>

<p align="center"><sub>The real Mica view, rendered from a sample project.</sub></p>

<details>
<summary>Watch the animated demo (19 seconds)</summary>

<p align="center">
  <img src="docs/assets/mica-demo.gif" alt="Mica's status strip clearly shows focus, break and paused timer states with labeled controls, alongside terminal output and dark and light themes" width="900">
</p>

A fresh offscreen capture of the current native Mica view (October 1, 2026). The GIF shows Quick Select and the Command Palette; the linked MP4 also shows local commands, timer states, scrollback search and theme changes. It does not invoke a coding agent. The memory readout belongs to the capture process. Close this section to hide the animation, or [watch the MP4 with playback controls](https://megasoft1978.github.io/mica-terminal/#demo).

</details>

## Why it is light

Most people run a terminal, a voice-typing app and a timer as separate programs, and the voice app alone is often a web browser in disguise. Mica builds them into one native process with no web view.

| Idle, one window, same Mac | Covers | Memory |
| --- | --- | ---: |
| **Mica** (3 tabs) | terminal, dictation, focus timer | **about 55–60 MB** |
| Alacritty | terminal | 69 MB |
| kitty | terminal | 80 MB |
| iTerm2 | terminal | 126 MB |
| Wispr Flow | dictation | 645 MB |

iTerm2 plus Wispr Flow is about 770 MB before you add a timer. Dictation adds a helper of about 35 MB only while you talk (about 95 MB in total), then it exits. Mica also shows its own memory live, bottom right. Project windows share one process, so extra windows cost about 25 MB each rather than a whole app. Method, caveats and the places Mica does not win (very large windows) are in [docs/MEMORY-BASELINE.md](docs/MEMORY-BASELINE.md).

## What you get

- **A window per project.** Named tabs, folders and project windows reopen after quitting, including when you launch another project; restored tabs start fresh shells. Project launchers keep their configured layouts. The Dock icon shows the mark of the project in front. The status bar shows the git branch, and **Session → New Worktree Tab…** gives an agent its own checkout.
- **Agents stay ordinary programs.** Run Codex, Claude Code, `lazygit` or anything else in a normal `zsh` tab. Mica reads the visible screen for signs of work or a question and shows it on the tab. Background notifications distinguish waiting from finished work, make no sound and can be muted per tab.
- **Find actions and tabs quickly.** The Command Palette (<kbd>⌘⇧P</kbd>) searches menu actions and project tabs, showing each action's shortcut and each tab's folder, branch and activity. Quick Select (<kbd>⌘⇧U</kbd>) labels visible URLs, existing file paths and git hashes; type a label to copy, or hold <kbd>⌥</kbd> to open or reveal it. Per-tab agent notifications can be muted from the tab menu or palette.
- **See command phase metadata.** Mica's zsh integration emits OSC 133 prompt and command phase markers; the session retains the latest phase and command exit status. Per-prompt navigation is not implemented yet.
- **Good dictation that stays on your Mac.** Hold left <kbd>⌥</kbd>, speak, edit the text, press Return. It uses NVIDIA’s Parakeet speech model through Core ML; Mica downloads the 630 MB model in the background on first launch, with progress in the status bar, so dictation is ready when you need it. An optional local deterministic corrector uses project vocabulary; the vocabulary file and terminal-derived terms stay on your Mac. Nothing you say is sent anywhere.
- Dictation can use Hold or Toggle for left <kbd>⌥</kbd> in Settings. **Edit → Undo Last Dictation** removes the latest inserted transcript while you have not typed since.
- **A focus timer that follows you.** One timer shared by every Mica window. The status strip clearly labels **FOCUS**, **BREAK**, or **PAUSED · FOCUS/BREAK**, keeps the countdown in view, and gives you a labeled **Start**, **Pause**, or **Resume** control. Focus and break use separate colors and a progress ring. When a phase ends, macOS tells you whether to pause work or return to focus. End a phase from the **Focus** menu or VoiceOver actions; completed sessions remain in the menu and accessibility label.
- **Still a real terminal.** Choose how much scrollback to keep (650 lines by default, up to 20,000 with its memory cost shown in Settings), search Unicode output and keep your reading position while retained history receives new output, Command-click links, drag tabs, choose a cursor and a dark, light or system-following theme. If a program over SSH asks to set your clipboard, Mica asks you first.

## Install

1. [Download Mica.zip](https://github.com/megasoft1978/mica-terminal/releases/download/v0.1.0-alpha.11/Mica.zip) (Apple silicon, macOS 14 or later), extract it, and move Mica to Applications.
2. Alpha builds may change quickly. Check the release page for signing status and checksums when the alpha 11 package is published.
3. Mica asks for the microphone only when you start dictation.

### Build from source

You need Xcode’s command line tools (Swift 6). The terminal parsing library is in the repository; the first build also fetches the speech package over the network.

```sh
git clone https://github.com/megasoft1978/mica-terminal.git
cd mica-terminal
make app && open build/Mica.app
```

### Dictation, live

<p align="center"><img src="docs/assets/crop-dictation-dark.png" alt="The status bar while dictating: microphone level, elapsed time and the last few words you said" width="620"></p>

The microphone starts recording the moment you hold <kbd>⌥</kbd>, so nothing you say is lost while the model loads. The strip shows a live level, the time, and the last few words as they are recognized. If macOS blocks microphone access, choose **Open Microphone Settings** in the strip to enable it.

## Privacy and questions

- **What leaves my Mac?** Mica processes dictation locally through Core ML and has no accounts, analytics or telemetry. Setting up dictation downloads the 630 MB speech model. Programs you run in the terminal, including coding agents, follow their own network and privacy policies.
- **Microphone permission?** Asked once, when you first dictate. Audio is processed in memory and not saved.
- **Project vocabulary?** Dictation correction is enabled by default and uses names from your project plus `~/Library/Application Support/Mica/vocabulary.txt`. Use **Edit → Improve Dictation with Project Vocabulary** to switch it off, or **Edit → Edit Vocabulary…** to add terms and `spoken form => Canonical spelling` aliases. These terms stay on your Mac.
- **Is the download safe?** Check the release page for the build's signing status and verify its checksum manifest with `shasum -a 256 -c SHA256SUMS.txt`.
- **Intel Macs?** Not yet; this alpha is built and tested on Apple silicon.
- **Codex, Claude Code, lazygit?** Ordinary programs in a zsh tab. Mica shows on the tab when an agent is working or waiting for you.

## Keys worth knowing

| | |
| --- | --- |
| Switch tabs | <kbd>⌘1</kbd>–<kbd>⌘9</kbd> |
| Search menu actions or switch tabs | <kbd>⌘⇧P</kbd> |
| New tab, close tab, new window | <kbd>⌘T</kbd> · <kbd>⌘W</kbd> · <kbd>⌘N</kbd> |
| Dictate | hold left <kbd>⌥</kbd> |
| Stop Toggle dictation | press left <kbd>⌥</kbd> again |
| Choose Hold or Toggle dictation | Settings → Dictation |
| Undo latest dictation | **Edit → Undo Last Dictation** (when no later prompt text was typed) |
| Quick Select visible URLs, paths and hashes | <kbd>⌘⇧U</kbd> |
| Navigate OSC 133 prompts | Not available yet; OSC 133 phase and exit status are tracked |
| Find, next, previous | <kbd>⌘F</kbd> · <kbd>⌘G</kbd> · <kbd>⇧⌘G</kbd> |
| Text size, reset | <kbd>⌘+</kbd> <kbd>⌘−</kbd> · <kbd>⌘0</kbd> |
| Light or dark theme | <kbd>⌥⌘L</kbd> |
| Bring Mica forward from any app (opt in under Settings) | <kbd>⌃⌥Space</kbd> |
| Clear scrollback | <kbd>⌘K</kbd> |
| All shortcuts | <kbd>⌘/</kbd> |

## Project launchers

Choose **Mica → New Project Launcher…**, or run `make new-instance`. For a script, skip the prompts:

```sh
python3 scripts/install-desktop-apps.py --new-instance \
  --name "My Project" --folder ~/code/my-project --command codex
```

Edit a project’s tabs later with **Project → Project Settings…**. A `.mica` layout file can define named tabs, folders and optional commands.

When `/Applications/Mica.app` is installed, project launchers created from a source checkout use that installed copy. This keeps macOS folder permissions tied to the stable app while `make app` rebuilds the development copy. To update existing launchers to use the installed app, run `make install-desktop-apps` once.

## Under the hood

A C session core owns the shells and scrollback, a vendored, patched [libvterm](third_party/libvterm) parses escape sequences, and a thin AppKit layer draws everything. Memory and speed notes: [measurements](docs/MEMORY-BASELINE.md), [performance](docs/PERFORMANCE.md).

```sh
make test       # PTY, UI, launcher and fixture checks; never sends prompts to agent CLIs
make sanitize   # session tests and a fuzzer under AddressSanitizer and UBSan
make stress     # thousands of random UI actions under the sanitizers
make validate   # tests, build, helper build and bundle checks
make demo-assets # refresh the website MP4 and README GIF (requires ffmpeg)
make dmg        # ad-hoc sign, build Mica.dmg, Mica.zip and checksums (SIGN_ID="Developer ID Application: …" to override)
```

More: [what is left](docs/ROADMAP.md) · [how it compares](docs/COMPETITORS.md) · [stability testing](docs/STABILITY.md) · [UI plan](docs/UI-REVIEW.md) · [releasing](docs/RELEASING.md) · [agent notifications](docs/AGENT-NOTIFICATIONS.md) · [contributing](CONTRIBUTING.md) · [security](SECURITY.md)

## Credits

Mica is released under the [MIT License](LICENSE). It uses [libvterm](https://github.com/neovim/libvterm) (MIT), [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) (SIL OFL 1.1), and for local dictation [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0), Apple Core ML, and [Parakeet Ultra by Moondream](https://huggingface.co/moondream/parakeet-ultra), based on NVIDIA Parakeet TDT 0.6B v3 (CC BY 4.0). Full notices: [voice/THIRD_PARTY_NOTICES.md](voice/THIRD_PARTY_NOTICES.md).
