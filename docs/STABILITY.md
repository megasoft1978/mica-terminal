# Stability testing

Mica runs shells whose output it does not control, so the parser, the session core and the AppKit view are tested with hostile input as well as with fixtures.

## What runs

| Command | What it does |
| --- | --- |
| `make test` | Fast checks: session core, timer, launcher, memory tools, 75 AppKit checks, agent loop. |
| `make sanitize` | The session tests plus a fuzzer, built with AddressSanitizer and UBSan. |
| `make fuzz FUZZ_SEEDS=12` | Only the fuzzer. Each seed prints its number so a failure can be replayed with `build/fuzz-session-san <seed>`. |
| `make stress STRESS_SEEDS=8` | The real AppKit view driven by 1,500 random user actions per seed (tabs, keys, mouse, resize, find, clear, theme, settings, paste), under the sanitizers. |

CI runs `make validate`, then `make sanitize FUZZ_SEEDS=3` and `make stress STRESS_SEEDS=3`.

## What the fuzzer feeds the terminal

- 600 KB of random bytes.
- 40,000 random escape sequences (CSI, OSC, DCS, APC, PM, SOS) with parameters up to 70,000.
- Thousands of lines mixing emoji sequences, combining marks, CJK and invalid UTF-8.
- Repeated toggling of the alternate screen, mouse, bracketed paste, synchronized output, scroll regions, OSC 52 and OSC 8.

Between reads it resizes the terminal (including tiny and huge sizes), scrolls, searches, folds lines, clears scrollback, pastes random bytes, and sends keys and mouse events, then reads every cell.

## What it found

The first run crashed immediately. Fixing the causes:

- **Four libvterm crashes** (a heap overflow in resize reflow, an `abort()` when the cursor could not be placed, a NULL dereference for wide characters at the last column, and an out-of-range cursor restored after a resize). libvterm 0.3.3 is now vendored in `third_party/libvterm` with patches for each; see `third_party/libvterm/PATCHES.md`.
- **A heap overflow in Mica's own history code** that copied hyperlink marks using the widest window size ever used, after the window had been narrowed.
- **A double release of the main window** when it closed.

## Known limits

- The fuzzer uses a plain zsh as the child and never starts an agent CLI or touches the network.
- Upstream libvterm may still contain out-of-range states that random resizing can reach; the fuzzer is the tool for finding them.
- The stress test cannot see rendering mistakes. Screenshots from `make screenshots` and the offscreen render in `make test` cover the layout.
