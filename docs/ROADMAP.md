# What is left

This roadmap tracks open work only. Shipped features are summarized below so they do not remain mixed into the ranked queue. Priorities reflect user value, effort and fit with Mica's native, local-first and memory-conscious design. See [COMPETITORS.md](COMPETITORS.md) and [MEMORY-BASELINE.md](MEMORY-BASELINE.md) for comparison methods and limits.

## Shipped

- The Command Palette (<kbd>⌘⇧P</kbd>) searches the menu action tree, displays current menu shortcuts and switches among tabs with folder, branch and activity context. It also exposes per-tab notification mute controls.
- Dictation supports Hold (default) and Toggle modes. Edit → Undo Last Dictation removes the latest inserted transcript only while no later prompt text has been typed.
- Local deterministic dictation correction uses the user's vocabulary file, project name, Git branch and tracked file names, and recently visible terminal text. It is enabled by default, can be switched off from Edit, and Undo Last Dictation restores the raw transcript after correction. Boosting was measured (see [build/boost-measurements.md](../build/boost-measurements.md)): it inserted wrong words in unrelated places, added 59 MB of peak memory and a 98 MB download, so it was removed in favour of the deterministic corrector.
- Quick Select (<kbd>⌘⇧U</kbd>) labels visible URLs, existing file paths and git hashes. Typing a label copies it; holding Option opens a URL or reveals a file.
- OSC 133 A/B/C/D shell markers are emitted by Mica's zsh integration and recognized by the session parser. Per-row landmarks, failed-command markers, ⌘↑/⌘↓ prompt navigation, and last-command output selection/copy are shipped.
- Agent notifications distinguish “needs input” from “finished”, use no sound, and can be muted per tab. Mica handles terminal notification sequences and clicking a notification returns to its window and tab.
- Project windows and ordinary tabs restore their names and folders after quit. Relaunch starts fresh PTY sessions; commands, running processes and scrollback do not resume.
- The focus timer is shared across windows, with labeled focus/break/paused states, Start/Pause/Resume controls, accessible actions, completion notifications and independent auto-start settings.
- Scrollback stores only meaningful row prefixes within a fixed history limit. Search supports Unicode text; wrapped URLs work at retained physical widths. Full column-width reflow remains open.
- The app includes system-following appearance, an opt-in global shortcut, denied-microphone Settings access, and per-window project windows hosted by one process.

## Open, ranked

| # | Work | Current gap | Effort |
| --- | --- | --- | --- |
| 1 | Retained-history column reflow | Reflow retained rows across width changes while preserving links, cell attributes, search and selection anchors within the per-session history cap. | Large |
| 2 | Agent/project sidebar | Make existing folder, branch, activity and notification context visible without reducing terminal space by default. | Medium |
| 3 | More complete session recovery | Reopened windows start fresh shells. Any future process or scrollback recovery needs explicit process-safety and bounded-storage design. | Large |
| 4 | Split panes | The layout, focus and resize model assumes one PTY grid per tab; define a bounded pane tree and resource accounting first. | Large |
| 5 | Broader shell support | Startup hooks and completion currently target `/bin/zsh -l -i`; add shells only with startup-file preservation and PTY coverage. | Medium–large |
| 6 | Release reliability | Keep install and update flows reproducible and separate development builds from installed releases. | Medium |

## Deferred

- Optional agent/workspace sidebar.
- Timer session labels, daily goal and local history; menu-bar timer extra.
- Dictation snippets and a review-before-insert draft.
- Worktree picker and cleanup; agent resume adapters.
- Bounded scrollback restore; changed-files summary.
- Quick-terminal drop-down; Liquid Glass on the tab strip.

## Known limits

- The first build needs a Swift 6 toolchain and network access for the speech package. Dictation downloads its model on first use/setup and processes audio locally.
- Agent activity is inferred from visible terminal text and can misread ordinary output.
- A single Dock icon serves all project windows and shows the project mark for the front window.
- History rows retain their original physical width when moved by libvterm resize callbacks. Wrapped-link detection is conservative across different widths; full retained-history reflow must preserve links, cell attributes, search and selection anchors within the per-session history cap.
- Memory and timing figures come from one Apple silicon Mac; see [MEMORY-BASELINE.md](MEMORY-BASELINE.md).
