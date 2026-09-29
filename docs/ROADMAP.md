# What is left

A verified list of what would make Mica better at its job (one light app for the terminal, dictation and a focus timer, for people who run coding agents). Every item comes from reading the code or from a measurement, not from guesses. Last reviewed 2026-09-29.

## Done in the final pass

- Agent notifications now carry the agent's words (OSC 9, 99, 777) as a macOS notification when Mica is in the background, and clicking it returns to that window and tab.
- Bare `http(s)` addresses in terminal output open with Command-click, not just OSC 8 links.
- Background agent output no longer holds the poll timer at full speed, and idle windows skip the shared-timer file when nothing changed.
- The activity indicator stops spinning when macOS Reduce Motion is on.
- Developer ID signing now uses Apple's secure timestamp, which notarization requires.
- Stale claims in the README, site and docs were corrected against the code.

## Still open, ranked by value against effort

| # | Gap | Evidence | Effort |
| --- | --- | --- | --- |
| 1 | Notarized build and an update path | No Developer ID certificate on the development Mac, so `make notarize` has never run end to end; no releases, no updater | Needs your certificate |
| 2 | Tabs and folders do not survive quitting | Quit destroys all sessions; only the window frame is restored | Medium |
| 3 | Status sidebar with per-tab branch, agent state and last notification | Data exists (branch, activity, notification text); no UI | Medium |
| 4 | Scrollback is short for agent output | 2 MiB cap over 40-byte cells is about 650 lines at 80 columns and 260 at 200 columns | Medium (compact cell storage) |
| 5 | Dictation first run and failures | The 630 MB download starts on the first hold with no consent step; a denied microphone shows text only, without a button for System Settings | Small to medium |
| 6 | zsh only | The shell is `/bin/zsh -l -i` and `$SHELL` is ignored; the shell hooks are zsh | Medium |
| 7 | Split panes | Layout, focus and resize code assume one grid per tab | Large |
| 8 | Quick terminal on a global hotkey | Not present | Medium |
| 9 | Follow system appearance and Increase Contrast | Settings offers Dark or Light only | Small |
| 10 | Vertical status sidebar, glass on the tab strip | See UI-REVIEW.md | Large |

## Known limits worth stating

- The first build needs network access (the speech package) and a Swift 6 toolchain.
- Agent activity on a tab is inferred by reading the visible screen for words such as "running" or "(y/n)", so it can misfire on ordinary output.
- One Dock icon serves every window, and it shows the mark of the project in front.
- Wrapped URLs that break across two lines are not opened as one address.
- All timing and memory figures are from one Apple silicon Mac; see MEMORY-BASELINE.md for the method.
