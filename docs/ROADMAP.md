# What is left

A verified list of what would make Mica better at its job (one light app for the terminal, dictation and a focus timer, for people who run coding agents). Priorities reflect local measurements and a 2026-09-30 comparison of official Ghostty, cmux, Warp, iTerm2, kitty and Apple Terminal docs; see [COMPETITORS.md](COMPETITORS.md). Keep the app native, local-first and memory-conscious.

## Done in the final pass

- Agent notifications now carry the agent's words (OSC 9, 99, 777) as a macOS notification when Mica is in the background, and clicking it returns to that window and tab.
- Bare `http(s)` addresses in terminal output open with Command-click, not just OSC 8 links.
- Command-click opens wrapped URLs correctly when they cross into scrollback, after history-ring replacement, and from either side of the history/live boundary. A vendored libvterm resize fix also preserves complete wrapped row groups when the terminal height shrinks and grows; column-width reflow of retained history remains open.
- Column-width changes retain the original physical width of rows that libvterm moves from the live grid into scrollback, so resize callbacks do not silently discard them. Retained rows still are not reflowed to the new width.
- OSC 8 hyperlink IDs now stay with retained physical history rows across resizes. Mica snapshots the current live-grid sidecar before libvterm's synchronous resize callbacks and attaches IDs to each pushed source row; retained rows are not transformed. Snapshot-allocation failure rejects the resize before mutating the grid. Session and UI tests cover multiple linked rows pushed on height shrink, link retention through width growth/shrink, and a wrapped link pushed by width shrink. Links on cells that remain in the transformed live grid are still not remapped; full retained-history reflow remains open.
- Widening the terminal now allocates its replacement history index before clearing folds or hyperlink marks; injected failures preserve the old grid, fold and retained OSC 8 links. The AppKit view retains its prior grid cache and retries a rejected resize, clearing coordinate-based selection only after the resize succeeds; PTY/UI coverage confirms retry convergence.
- Focus timer settings can independently auto-start the next break or focus interval. Both options default on to preserve existing transitions, can be changed through the actual timer-sheet checkboxes, and synchronize through the shared settings file; two-window UI coverage saves both mixed combinations. When a delayed wake finds auto-start disabled, the next interval remains paused with its full configured duration.
- Background agent output no longer holds the poll timer at full speed, and idle windows skip the shared-timer file when nothing changed.
- Seven active sessions have a repeatable AppKit poll check, including one continuous PTY flood; shell cwd lookups run after PTY output instead of during idle maintenance. Current measurements are test evidence, not a rendering-latency guarantee.
- Scrollback stores each row only through its last meaningful cell, preserving styled blanks and hyperlinks. A session test checks tracked history bytes against the cap and compares them with a full-width cell estimate.
- `make benchmark-history` measures short, dense and linked PTY output at 80 and 200 columns. History search appends compacted blank suffixes directly; forward/backward space matches remain covered by regression tests. See PERFORMANCE.md for measurements and limits.
- Search keeps combining marks and emoji sequences and skips wide-character continuation cells, so adjacent CJK/emoji text and decomposed accents can be found. ASCII rows retain the lowercase `strstr` fast path; Unicode rows use POSIX-locale Unicode case folding and canonical composition, covering case-fold expansions and canonically equivalent spellings without removing meaningful accents. Tests cover `Straße`/`STRASSE`, sigma forms, NFC/NFD accents, and scrollback. Column-width history reflow remains open.
- Wide-terminal search sizes temporary buffers to the row's maximum UTF-8 size, preserving long queries and text past byte 1,024. PTY regressions cover long-prefix false matches and late-row matches in live output and history; larger buffers exist only during a search.
- The status bar keeps the timer and a readable folder suffix visible at 600 px and 800 px, dropping shortcut hints first.
- A denied microphone offers a button to open System Settings → Privacy & Security → Microphone.
- Settings can follow macOS appearance live, while Dark remains the first-run default; Increase Contrast strengthens separators and secondary text.
- Ordinary tabs and project-layout windows reopen after quitting; saved windows keep their tab names and folders. Relaunch starts fresh PTY sessions, so running processes and scrollback do not resume.
- The activity indicator stops spinning when macOS Reduce Motion is on.
- Dictation animation timing belongs to each project window, so one window's refresh throttle cannot suppress another window's listening indicator. A two-window regression checks both directions without starting a microphone or speech helper.
- Ending the current timer phase is available through the Focus menu and the timer's VoiceOver Actions rotor, with phase-specific labels and an idle-disabled menu action. Tests exercise the accessibility handler and shared-window state.
- The focus timer now makes the next action clear at a glance: uppercase FOCUS/BREAK/PAUSED labels, a phase-tinted progress ring, and labeled Start/Pause/Resume controls. Phase-change notifications directly say when to pause work or return to focus. Reset remains separate, while completed-focus count stays in the menu and VoiceOver label. Dark/light audit captures cover each active and paused phase.
- Developer ID signing now uses Apple's secure timestamp, which notarization requires.
- Stale claims in the README, site and docs were corrected against the code.

## Still open, ranked by value against effort

| # | Gap | Evidence | Effort |
| --- | --- | --- | --- |
| 1 | Compact scrollback storage | Rows store meaningful prefixes, intern up to 16 row-local scalar styles/colors, and keep the previous scalar format for more varied rows; combined Unicode retains full cells and links remain separately tracked. The retained-line limit is unchanged; continue measuring search/resize latency before considering a larger allowance | Medium–large |
| 2 | Pomodoro timer UI | Done: uppercase phase and countdown, tinted progress ring, labeled Start/Pause/Resume actions, clear pause/resume notifications, accessible count and skip, independent auto-start | Done |
| 3 | Optional agent/project sidebar | Branch, folder, agent state and notification data already exist. cmux documents a workspace rail that makes this context visible; prototype a compact native sidebar without squeezing the terminal by default | Medium |
| 4 | Reliable command landmarks | Mica has zsh preexec/precmd hooks and terminal search. Formal command start/finish/exit markers could support prompt navigation and focused output selection; keep visual state inference as a fallback | Medium |
| 5 | More shell choices | The shell is `/bin/zsh -l -i` and `$SHELL` is ignored; hooks and completion are zsh-specific. Add other shells only with startup-file preservation and PTY tests | Medium–large |
| 6 | Split panes | Common in Ghostty, Warp and cmux, but layout, focus and resize code assume one grid per tab | Large |
| 7 | Reliable releases and an update path | Alpha 9 has a valid Developer ID signature and stapled app/DMG tickets; the ZIP and DMG checksums are generated after stapling. CI skips the build when a locally notarized release already exists for the tag. An updater remains open | Medium |
| 8 | Quick terminal that drops down from the top of the screen | Settings has an opt-in global shortcut (⌃⌥Space) that brings Mica forward; no drop-down window yet | Medium |
| 9 | More complete session recovery | Current restore recreates windows/tabs, not live PTYs or scrollback. Preserve process safety and make re-executed startup commands obvious before pursuing durable sessions | Large |

## Known limits worth stating

- The first build needs network access (the speech package) and a Swift 6 toolchain.
- Agent activity on a tab is inferred by reading the visible screen for words such as "running" or "(y/n)", so it can misfire on ordinary output.
- One Dock icon serves every window, and it shows the mark of the project in front.
- Bare URLs are joined across soft-wrapped rows on screen for Command-click (tested: wrapped from either row, hard newline stops, adjacent URLs stay apart). Wrapped links now also join in scrollback at the retained column width, with tests for both URL halves, hard newlines, adjacent links and folded barriers. History at a different width is not joined; height-only resize restores continuation metadata when history returns to the live grid. Resize preserves OSC 8 IDs for retained physical rows and for rows pushed out of the old live grid, but it does not map IDs to the transformed live cells. Full retained-history reflow needs a logical-row transform that spans the external ring and libvterm's live grid, preserves hyperlinks and cell attributes, maps search and scroll anchors, clears or rebases selection, and stays within the per-session history budget. Reflowing retained history across column-width changes remains open. There is no underline on hover yet. See COMPETITORS.md for the upstream references and remaining acceptance checks.
- All timing and memory figures are from one Apple silicon Mac; see MEMORY-BASELINE.md for the method.
