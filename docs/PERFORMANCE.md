# Performance notes

## Dictation vocabulary correction

`examples/vocabulary-transcripts.tsv` is a fixed 40-prompt coding-dictation fixture. The UI test compares exact expected transcripts: raw output matched 24/40 prompts (60%); deterministic correction matched 34/40 (85%) in the recorded run. This is a text-only fixture, not an audio or speech-recognition accuracy benchmark. The test measured 3.551 ms for correction with 500 candidate terms and a 200-word transcript on this machine; the acceptance limit is 5 ms. The corrector uses Foundation string normalization, Damerau–Levenshtein distance and a bounded phonetic key, with no model or network access. Timing is a single diagnostic sample and varies with host load.

Snapshot measurements on one Apple Silicon Mac (macOS 26, 2026-09-29). They are not a controlled benchmark.

| Check | Result |
| --- | --- |
| Idle CPU, one window, three idle tabs | About 0.6–0.8 % (idle timer backs off to 50 ms after 5 s without output) |
| Output throughput, 18 MB of scrolling text (`seq 1 400000 \| sed …`) on a 40×120 screen | About 4.6 s (≈ 4 MB/s) through the session core, parsing and scrolling only, no drawing |

## Where the time goes

Sampling the throughput run shows about three quarters of the time in libvterm's screen layer, in `vterm_scroll_rect` → `moverect_internal` → `memmove`. libvterm 0.3.3 stores the screen as one flat cell array and moves the whole array for every scrolled line, so heavy scrolling output costs roughly one screen-sized copy per line. Mica's own history push and link tracking are a small fraction.

Reducing this would mean changing how the vendored screen buffer stores rows (for example a ring of row pointers) rather than tuning Mica code. That can still preserve libvterm parsing, but would need a minimal documented patch with focused scroll, resize and fuzz coverage. The existing measurement does not establish input latency while bulk output competes with drawing; measure that separately before choosing a renderer or storage rewrite.

To repeat the measurement, build a small program against `src/session.c` that runs the command in a `MicaSession` and polls until a marker line appears.

## Scrollback capacity

Settings → Scrollback chooses how much history a session may keep. Memory is allocated only as output arrives. The table below is a **historical full-width-storage baseline**, before compact rows; it is not a measurement of the current implementation. Measured on this Mac (80 columns, 60,000 lines of output, growth in phys_footprint per busy tab):

| Setting | Lines kept | Extra memory per busy tab |
| --- | ---: | ---: |
| 650 lines (default) | 650 | about 5 MB |
| 2,000 lines | 2,000 | about 16 MB |
| 5,000 lines | 5,000 | about 41 MB |
| 20,000 lines | 20,000 | about 162 MB |

At 200 columns the same 5,000-line setting keeps 2,000 lines (about 31 MB), because a line costs more. A history cell is a full `VTermScreenCell` (about 40 bytes), plus 4 bytes for its hyperlink id. Memory is not returned to the system until the tab closes.

Current history trims trailing default blank cells and allocates hyperlink rows only when needed. Styled blanks and linked blanks remain meaningful. The retained-line policy still assumes full-width cells; savings currently reduce allocation rather than increase the number of retained rows. Scalar rows now intern up to 16 distinct attribute/foreground/background combinations per row, with a bounded linear lookup. Rows exceeding that palette keep the previous compact scalar representation, while combined Unicode cells keep libvterm's full-cell representation. Readers reconstruct the original cell before rendering, search, resize and hyperlink/fold mapping.

## Repeatable history benchmark

Run `make -s benchmark-history` for CSV output. It sends 20,000 local synthetic lines through a real PTY, suppresses user shell startup files, checks successful child exit and the final line, and measures a missing-query search averaged over ten attempts plus a narrow/wide resize pair. It makes no external requests and invokes no coding agents. A failure or 30-second output timeout returns nonzero.

An earlier run on 2026-09-30, before scalar-cell compression, with the 20,000-line setting:

| Output | Columns | Rows retained | Tracked history bytes | Output ms | Search miss ms | Resize pair ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Short numbered lines | 80 | 19,753 | 7,901,200 | 288 | 7.4 | 0.48 |
| 60-character payload | 80 | 19,753 | 56,098,520 | 768 | 18.3 | 0.15 |
| Short OSC 8 linked lines | 80 | 19,753 | 8,612,308 | 352 | 11.8 | 0.57 |
| Short numbered lines | 200 | 7,960 | 3,184,000 | 527 | 57.1 | 0.28 |
| 60-character payload | 200 | 7,960 | 22,606,400 | 1,076 | 16.8 | 0.55 |
| Short OSC 8 linked lines | 200 | 7,960 | 3,470,560 | 460 | 7.9 | 0.45 |

Tracked bytes include history cells, hyperlink rows and the row index, but exclude allocator overhead, the URI table, live screen and process footprint. Output timing includes startup and PTY transport; drawing and AppKit maintenance are absent. These are diagnostic observations from one run, not performance guarantees. The 57 ms wide-screen search result warrants repeated profiling before making a latency claim. Resize timing alone does not prove content preservation; the PTY regression suite covers that separately.

Search now appends the implicit blank suffix of compact history in one operation, avoiding repeated blank-cell construction and row-index lookup. Two subsequent runs measured missing-query search at 1.99–2.19 ms for short 80-column rows and 1.30–1.78 ms for short 200-column rows, with unchanged retained rows and tracked bytes. Dense 80-column rows measured 8.55–8.66 ms. These runs used a different background load from the initial run, so they establish repeatable current observations rather than a controlled speedup ratio. Regression tests preserve forward and backward matches including spaces after compacted text.

After correcting UTF-8 extraction to retain combining codepoints and omit wide-cell continuation sentinels, another run measured short rows at 2.48 ms (80 columns) and 1.49 ms (200 columns), and dense rows at 14.99 and 7.30 ms respectively. The tracked storage and row counts stayed unchanged. Unicode search now folds both query and candidate rows with Core Foundation's Unicode case-fold API using the fixed `en_US_POSIX` locale, with canonical composition before and after folding. This makes NFC/NFD accents, sigma variants, and `Straße`/`STRASSE` equivalent while preserving distinctions such as `cafe` versus `café`; ASCII query/row pairs still use the existing `strstr` fast path. Scratch storage is bounded by the current grid width and query length (queries longer than one row's UTF-8 capacity are rejected), and folded strings are temporary per search rather than cached. Coverage is in `tests/test_session.c`. See Apple's [`CFStringFold` documentation](https://developer.apple.com/documentation/corefoundation/cfstringfold%28_%3A_%3A%29?language=objc).

Research direction: [kitty's performance guidance](https://sw.kovidgoyal.net/kitty/performance/) separates rendering throughput and interactive latency, while its [scrollback configuration](https://sw.kovidgoyal.net/kitty/conf/#scrollback) describes bounded history and additional pager history. For Mica, use this benchmark alongside UI polling and footprint measurements before changing retention limits. [Ghostty shell integration](https://ghostty.org/docs/features/shell-integration) also demonstrates command-boundary navigation as a useful improvement independent of renderer architecture.

The current scalar-cell representation stores one codepoint per cell for ordinary rows, retaining the full libvterm cell for rows with combining marks or joined emoji. Colors, attributes, widths and hyperlinks remain available in both representations. A subsequent benchmark retained 19,704 rows at 80 columns: short output used 4,492,512 tracked bytes, dense output 28,531,392, and linked output 5,201,856. At 200 columns it retained 7,952 rows, using 1,813,056, 11,514,496 and 2,099,328 bytes respectively. Dense history used about 49% fewer tracked bytes than the earlier representation. The conservative retention calculation still assumes full cells; no history budget was increased. Timing remains diagnostic and depends on background load.

The AppKit PTY smoke test now measures seven active sessions with one continuously flooding the PTY and six writing every 10 ms. A run on this machine measured 1.50 ms average and 4.14 ms maximum for `pollSessions`, below the test limits of 16 ms average and 50 ms maximum. This is a main-thread polling measurement, not a rendering-latency or key-to-echo benchmark; it does not establish performance under a real agent workload.

A PTY regression fills and wraps a 100-line history allowance with dense combining-character rows, replaces it with scalar rows, then replaces it with combining rows again. It checks that scalar history releases the larger allocations and that combining text remains searchable after the reverse transition. Allocation reuse now explicitly shrinks when full Unicode rows become scalar; a failed shrink safely retains the existing allocation.

Row-local style interning was measured with the same `make benchmark-history` workload. On this run, dense 80-column history used 12,721,824 tracked bytes for 19,512 rows (about 652 bytes per row), down from 28,619,136 bytes for 19,656 rows (about 1,456 bytes per row), a 55% per-row reduction. The retained row counts differ slightly because they are capped by the actual byte allowance; treat this as an observed run, not a same-row-count comparison. Short and linked 80-column histories used 3,199,968 and 3,902,400 bytes. At 200 columns, dense history used 5,163,840 bytes for 7,920 rows. The 20-color PTY regression exceeds the 16-entry palette and checks that both ends of the row retain their exact RGB colors; common bold/underline styles and RGB colors are also checked after scrolling into history. The line allowance and byte ceiling are unchanged. Timing is diagnostic and depends on host load.

Scrollback now checks tracked bytes after each retained row, including optional hyperlink metadata. If linked Unicode output exceeds the allowance, the oldest rows are released until history fits. Ordinary compact output retains the same conservative line limit. A local PTY regression demonstrates the previous overrun and verifies the budget, combining codepoints and retained OSC 8 URI after eviction. This allowance excludes allocator overhead, live terminal cells and the separately bounded URI table.

While reading scrollback, incoming output advances the view offset even when the history ring is full. This keeps retained text stationary; once the reading row is evicted, the view clamps to the oldest remaining row. A PTY regression compares every character and width in the reading row before and after more output, then exercises eviction and returning to live output.

History rows now preserve libvterm’s soft-wrap continuation bit. URL joining uses the visible history mapping and stops at folded placeholders or nonadjacent source rows; alternate-screen content does not join to primary-screen history. The bit fits in existing row metadata padding on this build. UI tests cover links split across history rows, and the benchmark checks that tracked storage stays unchanged. Height-only resize now restores continuation metadata with popped history cells; reflowing retained history across column-width changes remains open.

OSC 8 sidecar IDs remain attached to retained physical history rows during grid resize. Before a resize, Mica makes a temporary copy of the live-grid ID map; libvterm's source resize loop pushes old rows in ascending order, and the history callback copies the matching sidecar row. If that bounded grid-sized snapshot cannot be allocated, the resize is rejected before folds, link metadata, dimensions or PTY state are changed. No history allowance is added: the snapshot exists only during resize, and existing history link allocations remain subject to the normal byte cap. Session tests exercise multiple links pushed during height shrink, retained links during width growth/shrink, and injected snapshot-allocation failure; AppKit coverage Command-clicks a wrapped OSC 8 URL after width shrink. IDs still attached to transformed live-grid cells are not remapped, and full logical reflow remains open.

Additional PTY regressions exercise wrap metadata across the primary history/live boundary, prevent joining primary history to independently wrapped alternate-screen output, and preserve later wrapped lines after a 100-line nominal history ring replaces older output. The ring case also checks the tracked byte allowance. Direct Command-click UI coverage now opens exact URLs from both sides of the history/live boundary and after ring replacement. A resize regression also found that libvterm could drop rows from a wrapped group when shrinking the grid; the vendored resize path now pushes the whole departing group into history before backfill, and a direct test checks all characters and continuation flags after shrinking and growing. Column-width resize now retains rows pushed from the old grid with their source widths; the UI regression verifies a wrapped first row moved to scrollback after narrowing. Retained history isn't reflowed to the new width, so column-width reflow remains open.
