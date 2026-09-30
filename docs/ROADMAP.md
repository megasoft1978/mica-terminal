# What is left

A verified list of what would make Mica better at its job (one light app for the terminal, dictation and a focus timer, for people who run coding agents). Priorities reflect local measurements and a 2026-09-30 comparison of official Ghostty, cmux, Warp, iTerm2, kitty and Apple Terminal docs; see [COMPETITORS.md](COMPETITORS.md). Keep the app native, local-first and memory-conscious.

## Done in the final pass

- Agent notifications now carry the agent's words (OSC 9, 99, 777) as a macOS notification when Mica is in the background, and clicking it returns to that window and tab.
- Bare `http(s)` addresses in terminal output open with Command-click, not just OSC 8 links.
- Background agent output no longer holds the poll timer at full speed, and idle windows skip the shared-timer file when nothing changed.
- Seven busy sessions have a repeatable poll benchmark; shell cwd lookups now run after PTY output instead of during idle maintenance.
- Scrollback stores each row only through its last meaningful cell, preserving styled blanks and hyperlinks. A session test checks tracked history bytes against the cap and compares them with a full-width cell estimate.
- The status bar keeps the timer and a readable folder suffix visible at 600 px and 800 px, dropping shortcut hints first.
- A denied microphone offers a button to open System Settings → Privacy & Security → Microphone.
- Settings can follow macOS appearance live, while Dark remains the first-run default; Increase Contrast strengthens separators and secondary text.
- Ordinary tabs and project-layout windows reopen after quitting; saved windows keep their tab names and folders. Relaunch starts fresh PTY sessions, so running processes and scrollback do not resume.
- The activity indicator stops spinning when macOS Reduce Motion is on.
- Developer ID signing now uses Apple's secure timestamp, which notarization requires.
- Stale claims in the README, site and docs were corrected against the code.

## Still open, ranked by value against effort

| # | Gap | Evidence | Effort |
| --- | --- | --- | --- |
| 1 | Compact scrollback storage | First step now stores only each row's meaningful prefix and keeps styles/links. It does not yet raise the retained-line limit; measure real memory, hyperlink-heavy output, and search/resize latency before reclaiming the saved budget or deduplicating attributes | Medium–large |
| 2 | Pomodoro timer UI | The timer is visible and shared across windows; clarify phase/time/action hierarchy and VoiceOver labels, consider an optional skip action and completed-focus count, and keep auto-advance opt-in | Small–medium |
| 3 | Optional agent/project sidebar | Branch, folder, agent state and notification data already exist. cmux documents a workspace rail that makes this context visible; prototype a compact native sidebar without squeezing the terminal by default | Medium |
| 4 | Reliable command landmarks | Mica has zsh preexec/precmd hooks and terminal search. Formal command start/finish/exit markers could support prompt navigation and focused output selection; keep visual state inference as a fallback | Medium |
| 5 | More shell choices | The shell is `/bin/zsh -l -i` and `$SHELL` is ignored; hooks and completion are zsh-specific. Add other shells only with startup-file preservation and PTY tests | Medium–large |
| 6 | Split panes | Common in Ghostty, Warp and cmux, but layout, focus and resize code assume one grid per tab | Large |
| 7 | Notarized build and an update path | No Developer ID certificate on the development Mac, so `make notarize` has never run end to end; no updater | Needs your certificate |
| 8 | Quick terminal that drops down from the top of the screen | Settings has an opt-in global shortcut (⌃⌥Space) that brings Mica forward; no drop-down window yet | Medium |
| 9 | More complete session recovery | Current restore recreates windows/tabs, not live PTYs or scrollback. Preserve process safety and make re-executed startup commands obvious before pursuing durable sessions | Large |

## Known limits worth stating

- The first build needs network access (the speech package) and a Swift 6 toolchain.
- Agent activity on a tab is inferred by reading the visible screen for words such as "running" or "(y/n)", so it can misfire on ordinary output.
- One Dock icon serves every window, and it shows the mark of the project in front.
- Bare URLs are joined across soft-wrapped rows on screen for Command-click (tested: wrapped from either row, hard newline stops, adjacent URLs stay apart). Rows that scrolled into history are not joined, and there is no underline on hover yet.
- All timing and memory figures are from one Apple silicon Mac; see MEMORY-BASELINE.md for the method.
