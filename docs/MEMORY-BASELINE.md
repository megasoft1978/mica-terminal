# Memory

Mica exists to be one light app instead of several heavy ones: a terminal, on-device dictation and a focus timer in a single native process. This page has the measurements behind that claim, how to repeat them, and where Mica does not win.

## Idle footprint, one window, same Mac

Measured 2026-09-29 on an Apple silicon Mac (macOS 26.6). Each app was launched fresh with one window and default settings, left idle for ten seconds, then measured with `scripts/measure-footprint.sh`, which sums Apple's `phys_footprint` (the "Memory" column in Activity Monitor) over every process the app starts, including Electron and XPC helpers.

| App | What it covers | Footprint | Processes |
| --- | --- | ---: | ---: |
| **Mica** (3 tabs) | terminal, dictation, focus timer | **about 55–60 MB** | 1 |
| Alacritty | terminal only | 69 MB | 1 |
| kitty | terminal only | 80 MB | 2 |
| iTerm2 | terminal only | 126 MB | 2 |
| Wispr Flow | dictation only | 645 MB | 11 |

The stack this replaces on the same Mac: **iTerm2 + Wispr Flow ≈ 770 MB**, before any timer app. Mica covers all three jobs in less than a tenth of that.

Dictation adds a helper process only while you are dictating (about 76 MB) and it exits afterwards, so the idle number above stays the number you live with.

## What makes the difference

- One process, no web view. Mica is AppKit and a C session core; there is no Chromium and no Node.
- Scrollback is allocated when output scrolls off screen and capped at 2 MiB per tab.
- The speech model is loaded only during dictation, and the recognizer runs in a short-lived helper.
- The focus timer is a few hundred bytes of state shared between windows through one small file.
- The Dock icon bitmap is 256 pt (it was 512 pt until this measurement showed it costing 6 MB), and the window is opaque (a translucent title bar cost about 8 MB, so it was removed).

## Where Mica does not win yet

- **Window size dominates.** Every app pays roughly 2–3 times the window's pixel area, four bytes per pixel, for its drawing buffers. A maximized window on a 5160 × 2160 display costs about 120 MB in any terminal. Mica processes running maximized on that display measure 140–190 MB each.
- **One process per project window.** A project launcher starts its own Mica process, so each extra window repeats the roughly 55 MB base that iTerm2 pays once. With several windows open, iTerm2 plus its windows can be smaller than several Mica processes. Sharing one process between project windows is the largest remaining memory saving.
- **First dictation after an update.** Core ML rebuilds its compiled model cache once per app build; that step peaks near 600 MB for about half a minute. Mica now does it in the background shortly after launch instead of on the first key press.
- **Terminal-only apps are close.** Alacritty and kitty are within 15–25 MB of Mica and do not include dictation or a timer.

## Repeating the measurement

```sh
scripts/measure-footprint.sh "Mica.app/Contents/MacOS/Mica"
scripts/measure-footprint.sh "iTerm.app/Contents"
scripts/measure-footprint.sh "Wispr Flow"
```

Start each app fresh with a single window, wait ten seconds, then run the command. `make memory` prints a per-process RSS summary for Mica, Claude Code and Codex. Numbers vary with window size, shell startup files and macOS version; compare like with like.

## Earlier comparison with Zellij

On 2026-09-29, before the changes above, Terminal.app running Zellij (server plus client) measured about 64 MB against Mica's 77 MB for three idle tabs. Zellij is a multiplexer that needs a host terminal, so it is not a like-for-like replacement, and neither covers dictation or a timer. Mica has since dropped to about 55–60 MB.
