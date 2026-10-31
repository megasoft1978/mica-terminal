# Memory

This page records a dated memory baseline for Mica and competing apps, how to repeat the measurements, and where Mica does not win. The measurements predate recent product changes.

## Idle footprint, one window, same Mac

Measured 2026-09-29 on an Apple silicon Mac (macOS 26.6). Each app was launched fresh with one window and default settings, left idle for ten seconds, then measured with `scripts/measure-footprint.sh`, which sums Apple's `phys_footprint` (the "Memory" column in Activity Monitor) over every process the app starts, including Electron and XPC helpers.

| App | What it covers | Footprint | Processes |
| --- | --- | ---: | ---: |
| **Mica** (3 tabs) | terminal and focus timer | **about 55–60 MB** | 1 |
| Alacritty | terminal only | 69 MB | 1 |
| kitty | terminal only | 80 MB | 2 |
| iTerm2 | terminal only | 126 MB | 2 |


These are historical measurements from September 2026 and do not describe current feature parity.

## Several project windows

Project launchers and **New Window** now open another window inside the process that is already running, through a `mica://open?layout=…` URL that only accepts layouts from `~/.config/mica/layouts`. Opening the same project twice focuses the existing window.

Measured 2026-09-29 with three project windows (1100 × 700 each) opened by URL into one fresh process: **109 MB in total**, against roughly 165–180 MB for three separate processes (each about 55–60 MB before its window buffers). Each extra window costs about 25 MB, mostly its drawing buffers, instead of repeating the whole base.

## What makes the difference

- One process, no web view. Mica is AppKit and a C session core; there is no Chromium and no Node.
- Scrollback is allocated when output scrolls off screen. The default allowance is about 2 MiB per tab; Settings can raise it to 20,000 nominal 80-column lines. Compact cells and optional hyperlink storage share that tracked allowance. See [current history measurements](PERFORMANCE.md#repeatable-history-benchmark); it is not a cap on total process memory.
- The focus timer is a few hundred bytes of state shared between windows through one small file.
- The Dock icon bitmap is 256 pt (it was 512 pt until this measurement showed it costing 6 MB), and the window is opaque (a translucent title bar cost about 8 MB, so it was removed).

## Where Mica does not win yet

- **Window size dominates.** Every app pays roughly 2–3 times the window's pixel area, four bytes per pixel, for its drawing buffers. A maximized window on a 5160 × 2160 display costs about 120 MB in any terminal. Mica processes running maximized on that display measure 140–190 MB each.
- **Older launchers use one process per window.** Launchers created before 2026-09-29, and layouts kept outside `~/.config/mica/layouts`, still start a separate Mica process per window, repeating the roughly 55 MB base. Re-run the launcher installer (or create the launcher again) to switch to shared windows.
- **Terminal-only apps are close.** Alacritty and kitty are within 15–25 MB of Mica.

## Repeating the measurement

```sh
scripts/measure-footprint.sh "Mica.app/Contents/MacOS/Mica"
scripts/measure-footprint.sh "iTerm.app/Contents"
scripts/measure-footprint.sh "Wispr Flow"
```

Start each app fresh with a single window, wait ten seconds, then run the command. `make memory` prints a per-process RSS summary for Mica, Claude Code and Codex. Numbers vary with window size, shell startup files and macOS version; compare like with like.

## Earlier comparison with Zellij

On 2026-09-29, before the changes above, Terminal.app running Zellij (server plus client) measured about 64 MB against Mica's 77 MB for three idle tabs. Zellij is a multiplexer that needs a host terminal, so it is not a like-for-like replacement, and neither covers Mica’s focus timer. Mica has since dropped to about 55–60 MB.
