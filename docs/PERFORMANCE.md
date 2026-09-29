# Performance notes

Snapshot measurements on one Apple Silicon Mac (macOS 26, 2026-09-29). They are not a controlled benchmark.

| Check | Result |
| --- | --- |
| Idle CPU, one window, three idle tabs | About 0.6–0.8 % (idle timer backs off to 50 ms after 5 s without output) |
| Output throughput, 18 MB of scrolling text (`seq 1 400000 \| sed …`) on a 40×120 screen | About 4.6 s (≈ 4 MB/s) through the session core, parsing and scrolling only, no drawing |

## Where the time goes

Sampling the throughput run shows about three quarters of the time in libvterm's screen layer, in `vterm_scroll_rect` → `moverect_internal` → `memmove`. libvterm 0.3.3 stores the screen as one flat cell array and moves the whole array for every scrolled line, so heavy scrolling output costs roughly one screen-sized copy per line. Mica's own history push and link tracking are a small fraction.

Reducing this would mean changing how the screen buffer stores rows (for example a ring of row pointers) rather than tuning Mica code, which conflicts with the "use libvterm for escape parsing" rule in `AGENTS.md`. Interactive use and agent output are not affected in practice; only bulk output such as `cat huge.log` is.

To repeat the measurement, build a small program against `src/session.c` that runs the command in a `MicaSession` and polls until a marker line appears.

## Scrollback capacity (open)

History remains capped at 2 MiB. `history_push` stores complete `VTermScreenCell` rows, while `mica_session_get_cell` reads those cells for rendering and hyperlink ids; resize/reflow and history growth copy rows, `find_row_text` reads them for search, and fold bookkeeping tracks history row positions. Increasing capacity safely needs a separate measurement and storage pass.

Staged design for a later high-effort cycle:

1. Measure actual used columns and per-line cell/attribute distributions on agent output, and record idle plus worst-case history memory.
2. Trim trailing blank cells per history line while preserving cursor, search, resize/reflow and rendering semantics.
3. Add an attribute table if measured cell attributes still dominate, with explicit limits and tests for hyperlink ids, folds, search and resize.
