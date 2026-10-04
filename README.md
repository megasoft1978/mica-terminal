<p align="center">
  <img src="docs/icon-180.png" width="96" height="96" alt="Mica app icon">
</p>

<h1 align="center">Mica</h1>

<p align="center">
  <strong>Every project gets its own named window.</strong><br>
  See where you are, then switch from Mica’s Dock menu. Terminal, on-device voice typing and a focus timer share one light Mac app.
</p>

<p align="center">
  <a href="https://github.com/megasoft1978/mica-terminal/releases/tag/v0.1.0-alpha.16"><img src="https://img.shields.io/badge/release-0.1.0--alpha.16-blue" alt="Release 0.1.0 alpha 16"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B%20%C2%B7%20Apple%20silicon-555" alt="macOS 14 or later, Apple silicon">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT license"></a>
</p>

<p align="center"><strong>Free · Apple silicon · macOS 14 or later · 10.6 MB download</strong></p>

<p align="center">
  <a href="https://megasoft1978.github.io/mica-terminal/">Website</a> ·
  <a href="https://github.com/megasoft1978/mica-terminal/releases/download/v0.1.0-alpha.16/Mica.zip"><strong>Download</strong></a> ·
  <a href="https://github.com/megasoft1978/mica-terminal/releases/tag/v0.1.0-alpha.16">Release notes</a> ·
  <a href="LICENSE">MIT license</a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: light)" srcset="docs/assets/mica-light.png">
    <img src="docs/assets/mica-dark.png" alt="Mica’s Fieldnote project window with its name visible at the right end of the tab strip, plus terminal output and a live memory readout." width="900">
  </picture>
</p>

<p align="center"><sub>A real Mica window, rendered from a fictional sample project.</sub></p>

<p align="center">
  <img src="docs/assets/project-switching-demo.gif" alt="Eight-second demo: see the Fieldnote project name in its window, open Mica’s Dock menu with Fieldnote and Northstar listed, then switch to Northstar." width="900">
</p>
<p align="center"><sub>One Dock icon lists open projects by name. <a href="docs/assets/project-switching-demo.mp4">Watch the 8-second MP4</a> · <a href="docs/assets/mica-demo.mp4">Watch the longer feature tour</a>.</sub></p>

<details>
<summary>See the longer feature tour (30 seconds)</summary>

<p align="center">
  <img src="docs/assets/mica-demo.gif" alt="Mica shows a project name in the top-right window badge, terminal features, and saved SSH profiles for fictional hosts" width="900">
</p>

A fresh capture of the current native Mica view. It shows local commands, Quick Select, the Command Palette, prompt navigation, vocabulary correction from a fake transcript (no microphone), saved SSH profiles, and the compact menu bar focus timer with its controls. The Mac Studio and Linux VPN destinations are fictional; no SSH connection is made. It does not invoke a coding agent. The memory readout belongs to the capture process.

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

- **A window per project.** The project name stays visible in the top-right badge and window title; hover over the badge to read the full name. Mica uses one Dock icon for the shared process: its mark follows the front project, and right-clicking it lists each open project with its active tab. Named tabs and folders reopen after quitting, project launchers keep their layouts, the status bar shows the Git branch, and **Session → New Worktree Tab…** gives an agent its own checkout.
- **Agents stay ordinary programs.** Run Codex, Claude Code, `lazygit` or anything else in a normal `zsh` tab. Mica shows a short agent name and activity in the tab title, with the full state and recent activity in its tooltip. Background notifications distinguish waiting from finished work, make no sound and can be muted per tab.
- **Find actions and tabs quickly.** The Command Palette (<kbd>⌘⇧P</kbd>) searches menu actions and project tabs, showing each action's shortcut and each tab's folder, branch and activity. Quick Select (<kbd>⌘⇧U</kbd>) labels visible URLs, existing file paths and git hashes; type a label to copy, or hold <kbd>⌥</kbd> to open or reveal it. Per-tab agent notifications can be muted from the tab menu or palette.
- **Navigate commands.** Mica marks OSC 133 prompts and failed commands. Use <kbd>⌘↑</kbd>/<kbd>⌘↓</kbd> at a prompt to move between landmarks, and Edit → Select Last Command Output or Copy Last Command Output to review the latest result.
- **Good dictation that stays on your Mac.** Hold left <kbd>⌥</kbd> or click the microphone in the status bar to start dictation; click again to finish. Speak, edit the transcript and press Return. NVIDIA’s Parakeet model runs locally through Core ML; the 630 MB model downloads in the background on first launch. Choose Hold or Toggle in Settings. Local vocabulary correction is enabled by default, and **Edit → Undo Last Dictation** restores the raw transcript while no later prompt text has been typed. Nothing you say is sent anywhere.
- **A focus timer that follows you.** One timer shared by every Mica window. A compact macOS menu bar item shows the current phase and countdown, and opens controls to start, pause, resume, or move to the next phase. The terminal status strip stays focused on folder, command, and memory context. When a phase ends, macOS tells you whether to pause work or return to focus. You can also control the timer from the **Focus** menu, and VoiceOver reads the phase, time, session label, and completed focus count.
- **Still a real terminal.** Choose how much scrollback to keep (650 lines by default, up to 20,000 with its memory cost shown in Settings), search Unicode output and keep your reading position while retained history receives new output, Command-click links, drag tabs, choose a cursor and a dark, light or system-following theme. If a program over SSH asks to set your clipboard, Mica asks you first.
- **Saved SSH connections.** Use Session → SSH Connections… to save a friendly name, OpenSSH host or `~/.ssh/config` alias, and optional remote starting folder. Mica opens it as an interactive terminal tab through macOS OpenSSH; keys, agent, host-key checks, jump hosts and VPN routing stay in your existing SSH setup. Mica stores no SSH credentials. SSH tabs restore as new connections, and Project Settings can add one to a project launcher. On a Mac you want to reach, enable System Settings → General → Sharing → Remote Login and limit access to the users who need it.

## Install

1. [Download Mica.zip](https://github.com/megasoft1978/mica-terminal/releases/download/v0.1.0-alpha.16/Mica.zip) (Apple silicon, macOS 14 or later), extract it, and move Mica to Applications.
2. This build is Developer ID signed and notarized. Verify it with the [published SHA-256 manifest](https://github.com/megasoft1978/mica-terminal/releases/download/v0.1.0-alpha.16/SHA256SUMS.txt).
3. Mica asks for the microphone only when you start dictation.

### Build from source

You need Xcode’s command line tools (Swift 6). The terminal parsing library is in the repository; the first build also fetches the speech package over the network.

```sh
git clone https://github.com/megasoft1978/mica-terminal.git
cd mica-terminal
make app && open build/Mica.app
```

### Dictation preview

Live dictation appears in a reserved area above the terminal, with a multiline transcript preview and clear insert or cancel hints. The terminal stays visible and resizes for the preview; speech-to-text controls no longer compete with command status in the bottom strip. If macOS blocks microphone access, Mica offers a direct link to Microphone settings.

## Privacy and questions

- **What leaves my Mac?** Mica processes dictation locally through Core ML and has no accounts, analytics or telemetry. Setting up dictation downloads the 630 MB speech model. Programs you run in the terminal, including coding agents, follow their own network and privacy policies.
- **Microphone permission?** Asked once, when you first dictate. Audio is processed in memory and not saved.
- **Project vocabulary?** Local deterministic correction is enabled by default. It uses the project name, Git branch and tracked file names, recent visible terminal text, and `~/Library/Application Support/Mica/vocabulary.txt`. Use **Edit → Improve Dictation with Project Vocabulary** to switch it off, or **Edit → Edit Vocabulary…** to add terms and `spoken form => Canonical spelling` aliases. These terms stay on your Mac. The fixed 40-prompt text fixture scored 24/40 raw and 34/40 after deterministic correction; it is not an audio recognition benchmark.
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
| Previous/next prompt at a prompt | <kbd>⌘↑</kbd> · <kbd>⌘↓</kbd> |
| Copy selection; without a selection, send Ctrl-C to the program | <kbd>⌘C</kbd> |
| Select/copy latest command output | Edit → Select Last Command Output / Copy Last Command Output |
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

Edit a project’s tabs later with **Project → Project Settings…**. A `.mica` layout file can define named tabs, local folders, optional commands, and saved SSH profiles. In Project Settings, choose **Add SSH Profile…** to include a connection when that project opens.

When `/Applications/Mica.app` is installed, project launchers created from a source checkout use that installed copy. This keeps macOS folder permissions tied to the stable app while `make app` rebuilds the development copy. To update existing launchers to use the installed app, run `make install-desktop-apps` once.

## SSH connections

Create or edit profiles from **Session → SSH Connections…**. Give each connection a name, destination, and optional remote starting folder. Set the destination to an OpenSSH host alias, `user@host`, hostname or IP address. Put authentication choices, identity files, jump hosts, ports and VPN-specific proxy commands in `~/.ssh/config`; Mica uses the normal `ssh` client and does not save passwords or private keys. A remote starting folder is entered as a POSIX path (`~/…` starts from the remote user's home) and opened in an interactive login shell. New or changed host keys continue to use OpenSSH's normal confirmation and `known_hosts` behavior. Profiles can be restored as fresh connections or included in a project launcher.

<p align="center"><img src="docs/assets/ssh-profiles-demo.png" alt="Fictional Mac Studio and Linux VPN SSH profiles, with each machine's remote starting folder." width="780"></p>

For a Mac on the same home network, enable **System Settings → General → Sharing → Remote Login** on the remote Mac. Linux machines use their normal SSH server. Connecting from outside the home network requires a reachable route such as a VPN/overlay, reachable IPv6, or an eligible public IP service; Starlink's default IPv4 service uses CGNAT, so inbound IPv4 usually needs an overlay VPN or another reachable route. Mica does not turn a VPN on or change router settings.

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
