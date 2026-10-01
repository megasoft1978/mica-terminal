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

Dictation adds a helper process only while you are dictating and it exits afterwards, so the idle number above stays the number you live with. While it recognizes speech the helper measures **about 30–37 MB**, so Mica plus a live dictation is roughly **95 MB** in total (see below).

These figures cover the shipped deterministic vocabulary correction, which runs in the app before transcript insertion. They do not include native speech-model vocabulary boosting: that feature and its extra model are not currently shipped, so there is no boosting memory or latency measurement to add. The correction latency and transcript-fixture results are recorded by the vocabulary checks in `make test`; they are not process-memory measurements.

## Memory while dictating

Measured with `scripts/measure-dictation-memory.py`, which starts the app's real helper, speaks a 7-second sentence into it in real time through macOS `say`, then adds 3 seconds of silence, sampling `phys_footprint` throughout. Three runs on 2026-09-29:

| Phase | Helper footprint |
| --- | ---: |
| Starting (models already compiled and cached) | 4–5 MB, ready in about 0.5 s |
| Listening and recognizing | 29–37 MB |
| Peak in any run | 37 MB |

The transcript was correct in every run apart from "Mica" written as "Micah". Add the app's own footprint (about 58 MB) and the microphone capture inside the app, and a dictation costs about 95 MB in total. An earlier figure of 76 MB came from the helper's peak *resident size*, which counts shared system pages; the footprint above is what Activity Monitor shows as Memory.

The status bar shows Mica's own number live at bottom right ("58 MB", or "58 + 36 MB" while the helper is running), taken from the same `phys_footprint` counter. While dictating, the app also writes a line per second to its diagnostic log (Help → Open Diagnostic Logs) so the total can be audited. Setting `MICA_DEBUG_DICTATE="5 10"` runs one real microphone dictation hold for measuring in place.

The one time memory is higher is the first dictation after an app update, when Core ML rebuilds its compiled model cache (peak resident size near 600 MB for about half a minute). Mica does that in the background shortly after launch.

## Several project windows

Project launchers and **New Window** now open another window inside the process that is already running, through a `mica://open?layout=…` URL that only accepts layouts from `~/.config/mica/layouts`. Opening the same project twice focuses the existing window.

Measured 2026-09-29 with three project windows (1100 × 700 each) opened by URL into one fresh process: **109 MB in total**, against roughly 165–180 MB for three separate processes (each about 55–60 MB before its window buffers). Each extra window costs about 25 MB, mostly its drawing buffers, instead of repeating the whole base.

## What makes the difference

- One process, no web view. Mica is AppKit and a C session core; there is no Chromium and no Node.
- Scrollback is allocated when output scrolls off screen. The default allowance is about 2 MiB per tab; Settings can raise it to 20,000 nominal 80-column lines. Compact cells and optional hyperlink storage share that tracked allowance. See [current history measurements](PERFORMANCE.md#repeatable-history-benchmark); it is not a cap on total process memory.
- The speech model is loaded only during dictation, and the recognizer runs in a short-lived helper.
- The focus timer is a few hundred bytes of state shared between windows through one small file.
- The Dock icon bitmap is 256 pt (it was 512 pt until this measurement showed it costing 6 MB), and the window is opaque (a translucent title bar cost about 8 MB, so it was removed).

## Where Mica does not win yet

- **Window size dominates.** Every app pays roughly 2–3 times the window's pixel area, four bytes per pixel, for its drawing buffers. A maximized window on a 5160 × 2160 display costs about 120 MB in any terminal. Mica processes running maximized on that display measure 140–190 MB each.
- **Older launchers use one process per window.** Launchers created before 2026-09-29, and layouts kept outside `~/.config/mica/layouts`, still start a separate Mica process per window, repeating the roughly 55 MB base. Re-run the launcher installer (or create the launcher again) to switch to shared windows.
- **First dictation after an update.** Core ML rebuilds its compiled model cache once per app build; that step peaks near 600 MB (resident size) for about half a minute. Mica now does it in the background shortly after launch instead of on the first key press.
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
