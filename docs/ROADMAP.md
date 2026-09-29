# What is left

A verified list of what would make Mica better at its job (one light app for the terminal, dictation and a focus timer, for people who run coding agents). Every item comes from reading the code or from a measurement, not from guesses. Last reviewed 2026-09-29.

## Done in the final pass

- Agent notifications now carry the agent's words (OSC 9, 99, 777) as a macOS notification when Mica is in the background, and clicking it returns to that window and tab.
- Bare `http(s)` addresses in terminal output open with Command-click, not just OSC 8 links.
- Background agent output no longer holds the poll timer at full speed, and idle windows skip the shared-timer file when nothing changed.
- Seven busy sessions have a repeatable poll benchmark; shell cwd lookups now run after PTY output instead of during idle maintenance.
- The status bar keeps the timer and a readable folder suffix visible at 600 px and 800 px, dropping shortcut hints first.
- A denied microphone offers a button to open System Settings → Privacy & Security → Microphone.
- Settings can follow macOS appearance live, while Dark remains the first-run default; Increase Contrast strengthens separators and secondary text.
- Ordinary tabs reopen after quitting with their names, working folders and configured startup commands; project layout windows continue to load from their layout files.
- The activity indicator stops spinning when macOS Reduce Motion is on.
- Developer ID signing now uses Apple's secure timestamp, which notarization requires.
- Stale claims in the README, site and docs were corrected against the code.

## Still open, ranked by value against effort

| # | Gap | Evidence | Effort |
| --- | --- | --- | --- |
| 1 | Notarized build and an update path | No Developer ID certificate on the development Mac, so `make notarize` has never run end to end; no releases, no updater | Needs your certificate |
| 2 | Status sidebar with per-tab branch, agent state and last notification | Data exists (branch, activity, notification text); no UI | Medium |
| 3 | Scrollback is short for agent output | 2 MiB cap over 40-byte cells is about 650 lines at 80 columns and 260 at 200 columns; see the staged design in PERFORMANCE.md | High (measure, trim blank cells, then encode attributes) |
| 4 | zsh only | The shell is `/bin/zsh -l -i` and `$SHELL` is ignored; the shell hooks are zsh | Medium |
| 5 | Split panes | Layout, focus and resize code assume one grid per tab | Large |
| 6 | Quick terminal that drops down from the top of the screen | Settings has an opt-in global shortcut (⌃⌥Space) that brings Mica forward; no drop-down window yet | Medium |
| 7 | Vertical status sidebar, glass on the tab strip | See UI-REVIEW.md | Large |

## Known limits worth stating

- The first build needs network access (the speech package) and a Swift 6 toolchain.
- Agent activity on a tab is inferred by reading the visible screen for words such as "running" or "(y/n)", so it can misfire on ordinary output.
- One Dock icon serves every window, and it shows the mark of the project in front.
- Bare URLs are joined across soft-wrapped rows on screen for Command-click (tested: wrapped from either row, hard newline stops, adjacent URLs stay apart). Rows that scrolled into history are not joined, and there is no underline on hover yet.
- All timing and memory figures are from one Apple silicon Mac; see MEMORY-BASELINE.md for the method.
