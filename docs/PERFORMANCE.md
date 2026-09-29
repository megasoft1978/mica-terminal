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

## Scrollback capacity

Settings → Scrollback chooses how much history a session may keep. Memory is allocated only as output arrives, so idle memory does not change; the choice caps the worst case for a tab that has produced a lot of output. Measured on this Mac (80 columns, 60,000 lines of output, growth in phys_footprint per busy tab):

| Setting | Lines kept | Extra memory per busy tab |
| --- | ---: | ---: |
| 650 lines (default) | 650 | about 5 MB |
| 2,000 lines | 2,000 | about 16 MB |
| 5,000 lines | 5,000 | about 41 MB |
| 20,000 lines | 20,000 | about 162 MB |

At 200 columns the same 5,000-line setting keeps 2,000 lines (about 31 MB), because a line costs more. A history cell is a full `VTermScreenCell` (about 40 bytes), plus 4 bytes for its hyperlink id. Memory is not returned to the system until the tab closes.

Why not simply raise the default: at about 8 KB per 80-column line, a 20,000-line history costs more than the whole idle app. The next step is compact storage (trim trailing blank cells per line, then an attribute table); the code that reads history cells is `history_push`, `mica_session_get_cell`, resize/reflow and growth, `find_row_text`, hyperlink-id reads and fold bookkeeping. Compact storage could allow several times the lines at the same cost.
