<p align="center">
  <img src="docs/icon-180.png" width="96" height="96" alt="Mica app icon">
</p>

<h1 align="center">Mica</h1>

<p align="center">
  <strong>Every project gets its own terminal.</strong><br>
  A native Mac terminal that keeps a project’s shells and coding agents together,<br>
  and shows you when one of them needs you.
</p>

<p align="center">
  <a href="https://megasoft1978.github.io/mica-terminal/">Website</a> ·
  <a href="#build-it">Build it</a> ·
  <a href="https://github.com/megasoft1978/mica-terminal/releases">Releases</a> ·
  <a href="LICENSE">MIT license</a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: light)" srcset="docs/assets/mica-light.png">
    <img src="docs/assets/mica-dark.png" alt="Mica window with project tabs, a git log and passing tests, a focus timer and shortcut hints" width="900">
  </picture>
</p>

<p align="center"><sub>The real Mica view, rendered from a sample project. macOS 14 or later.</sub></p>

## What you get

- **A window per project.** Named tabs, folders and startup commands, reopened from a Desktop launcher. The Dock icon carries a short mark of the project name.
- **Agents stay ordinary programs.** Run Codex, Claude Code, `lazygit` or anything else in a normal `zsh` tab. Mica shows when one is working and when it is waiting for you.
- **Dictation that stays on your Mac.** Hold left <kbd>⌥</kbd>, speak, edit the text, press Return. The first use downloads a 630 MB speech model; nothing is sent anywhere.
- **A focus timer that follows you.** One timer shared by every Mica window, with a notification when a period ends.
- **Still a real terminal.** Search scrollback, open links, drag tabs, choose a cursor and a light or dark theme. If a program over SSH asks to set your clipboard, Mica asks you first.

## Build it

You need Xcode’s command line tools and [Homebrew](https://brew.sh).

```sh
brew install libvterm pkg-config
git clone https://github.com/megasoft1978/mica-terminal.git
cd mica-terminal
make app && open build/Mica.app
```

There is no packaged download yet. A build from `make dist` is ad-hoc signed, so on another Mac Control-click the app and choose Open once. Mica asks for the microphone only when you start dictation.

## Keys worth knowing

| | |
| --- | --- |
| Switch tabs | <kbd>⌘1</kbd>–<kbd>⌘9</kbd> |
| New tab, close tab, new window | <kbd>⌘T</kbd> · <kbd>⌘W</kbd> · <kbd>⌘N</kbd> |
| Dictate | hold left <kbd>⌥</kbd> |
| Find, next, previous | <kbd>⌘F</kbd> · <kbd>⌘G</kbd> · <kbd>⇧⌘G</kbd> |
| Text size, reset | <kbd>⌘+</kbd> <kbd>⌘−</kbd> · <kbd>⌘0</kbd> |
| Light or dark theme | <kbd>⌥⌘L</kbd> |
| Clear scrollback | <kbd>⌘K</kbd> |
| All shortcuts | <kbd>⌘/</kbd> |

## Project launchers

Choose **Mica → New Project Launcher…**, or run `make new-instance`. For a script, skip the prompts:

```sh
python3 scripts/install-desktop-apps.py --new-instance \
  --name "My Project" --folder ~/code/my-project --command codex
```

Edit a project’s tabs later with **Project → Project Settings…**. A `.mica` layout file can define named tabs, folders and optional commands.

## Under the hood

A C session core owns the shells and scrollback, [libvterm](https://github.com/neovim/libvterm) parses escape sequences, and a thin AppKit layer draws everything. Three idle tabs use about 77 MB ([measurements](docs/MEMORY-BASELINE.md), [performance](docs/PERFORMANCE.md)); Mica is an integrated app, not a memory saver.

```sh
make test       # PTY, UI, launcher and fixture checks; never sends prompts to agent CLIs
make validate   # tests, build, helper build and bundle checks
make dist       # ad-hoc sign and zip (SIGN_ID="Developer ID Application: …" to override)
```

More: [UI plan](docs/UI-REVIEW.md) · [releasing](docs/RELEASING.md) · [agent notifications](docs/AGENT-NOTIFICATIONS.md) · [contributing](CONTRIBUTING.md) · [security](SECURITY.md)

## Credits

Mica is released under the [MIT License](LICENSE). It uses [libvterm](https://github.com/neovim/libvterm) (MIT), [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) (SIL OFL 1.1), and for local dictation [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0), Apple Core ML, and [Parakeet Ultra by Moondream](https://huggingface.co/moondream/parakeet-ultra), based on NVIDIA Parakeet TDT 0.6B v3 (CC BY 4.0). Full notices: [voice/THIRD_PARTY_NOTICES.md](voice/THIRD_PARTY_NOTICES.md).
