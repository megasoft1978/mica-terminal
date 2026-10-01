# What comparable tools do, and where Mica stands

Researched 2026-10-01 from each product's own documentation and current Mac App Store listings. "Done" means shipped in this repository; the rest is ranked by user value, effort, and fit with Mica's small, local-first design.

## The field

| Tool | What it is | Signature ideas |
| --- | --- | --- |
| [cmux](https://cmux.com/) | Native macOS terminal (Ghostty engine) built for coding agents | Vertical workspace rail with branches, folders, ports and notification state; splits; scriptable control API; layout restoration |
| [Warp](https://docs.warp.dev/terminal/blocks) | Terminal with structured command blocks and agent features | Searchable and bookmarkable command/output blocks, command history, reusable workflows, tab configs |
| [Ghostty](https://ghostty.org/docs/features) | Fast native terminal | Native tabs and splits, quick terminal, broad terminal protocol support, configurable keybindings |
| [iTerm2](https://iterm2.com/documentation.html) | Mature macOS terminal | Shell integration, session restoration, triggers, status bar, scripting and tmux integration |
| [kitty](https://sw.kovidgoyal.net/kitty/) | Fast terminal with shell integration and extensions | Prompt navigation, last-command output, scrollback search and pager, memory-on-demand scrollback |
| [Apple Terminal](https://support.apple.com/guide/terminal/use-window-groups-trml15652/mac) | macOS built-in terminal | Named window groups that restore configured windows and tabs at launch |
| Conductor, Superset, Crystal/Nimbalyst, Claude Squad | Agent orchestrators | One git worktree per agent, diff review, merge and PR flow, many agents at once, sessions that survive closing the window |
| tmux, Zellij | Multiplexers | Panes and layouts, detach and reattach sessions |

## Pomodoro timer patterns

Mica already has a computer-wide focus/break timer, a persistent phase and countdown in the status strip, pause/resume and reset controls, configurable focus/break durations, and completion notifications. Comparable focus apps show a few useful directions:

- Flow keeps a minimal timer in the menu bar, supports multiple interval lengths, session titles, statistics, break reminders, and keyboard shortcuts. Its App Store listing also describes calendar sync and fullscreen breaks ([Flow](https://www.flow.app/), [App Store listing](https://apps.apple.com/gb/app/flow-pomodoro-study-timer/id1423210932?platform=mac)).
- Be Focused treats start, pause and skip as first-class timer actions, with optional auto-start, a daily interval goal, custom durations, and reports ([App Store listing](https://apps.apple.com/gb/app/be-focused-pomodoro-timer/id973134470?mt=12)).
- Session connects a running focus timer to a distraction-reduction workflow, including updating and restoring Slack status ([Session](https://www.stayinsession.com/)).
- Small menu-bar timers like FocusTimer make the remaining time glanceable without requiring the full app window ([FocusTimer](https://focus.braunf.com/)).
- Apple exposes named [custom accessibility actions](https://developer.apple.com/documentation/appkit/nsaccessibilitycustomaction) through VoiceOver's Actions rotor. Mica now exposes ending the active phase there and in the Focus menu, alongside its accessible start/pause/resume and reset controls.

For Mica, the useful pattern is glanceable phase and time plus unmistakable primary actions. Be Focused lists start, pause, skip and optional auto-start as direct timer controls; Apple's Focus listing describes seeing remaining focus or break time in the menu bar without opening a window. Mica keeps that quick visibility in its status strip: uppercase FOCUS/BREAK/PAUSED text, phase color, a progress ring, and labeled Start/Pause/Resume actions. Completed-focus count remains in the menu and accessibility label, while users can independently choose whether focus and break intervals start automatically. Task planning, app blocking and gamified rewards add scope and would distract from Mica's terminal-first workflow.

## Memory (idle, one window, this Mac)

| App | Covers | Footprint |
| --- | --- | ---: |
| Mica | terminal, dictation, focus timer | about 55–60 MB |
| Alacritty | terminal | 69 MB |
| kitty | terminal | 80 MB |
| iTerm2 | terminal | 126 MB |
| Wispr Flow | dictation | 645 MB |

Method and caveats: [MEMORY-BASELINE.md](MEMORY-BASELINE.md). cmux, Warp, Ghostty, Zed and the Electron-based agent managers were not measured.

## Mica against that list

| Capability | Status |
| --- | --- |
| Project = window, named tabs, folders, launchers | Done |
| Agent activity in the tab and attention when input is needed | Done (Dock bounce, tab state) |
| Git branch of the active tab | Done, in the status bar (reads `.git/HEAD`, works in linked worktrees) |
| Worktree per agent | Done: Session → New Worktree Tab… |
| Search scrollback, links, drag to reorder tabs | Done |
| Clipboard from remote sessions with consent | Done (OSC 52) |
| Synchronized output, bracketed paste awareness | Done |
| Local voice dictation, shared focus timer | Done (not offered by the others) |
| Light and dark themes, cursor styles, bundled font, settings | Done |
| Fuzz, sanitizer and UI stress testing | Done |
| Vertical sidebar with per-tab status (branch, last notification, ports) | Not done. Strong interface opportunity; Mica already has project, branch, agent activity and notification state |
| Split panes | Not done. Large: the layout, focus and resize code all assume one grid per tab |
| Restore windows after quitting | Implemented in the current session work for ordinary tabs and project layout windows; child processes and scrollback do not survive a quit |
| Diff review and merge or PR flow | Not done. Large; the alternative is to run `lazygit` or `gh` in a tab, which already works |
| Bring Mica forward on a global hotkey | Done, opt-in ⌃⌥Space; a dedicated drop-down terminal is still open |
| Agent notifications with text, click to return to the tab | Done (OSC 9/99/777 become macOS notifications when Mica is in the background) |
| Scriptable control (a `mica` command for agents to set a tab's status) | Partly: OSC 9/99/777 and `scripts/claude-notify.sh` |
| Import of Ghostty or iTerm themes | Not done |

## What the comparison says

- **Make agent context visible without replacing the terminal.** cmux puts project/workspace metadata and unread attention in a vertical rail. Mica already derives project name, folder, branch, agent activity and notification text, so a compact optional sidebar could make multi-project work easier without adopting a block renderer or browser.
- **Lower the cost of useful history.** Before compact rows, Mica's measured full-cell history reached about 162 MB for one busy tab at the 20,000-line setting. The first compact-row change stores only through the last meaningful cell, but the retained-line policy is still based on full-width cells. Measure actual memory and scroll/search latency before using that saved space to retain more agent output.
- **Use command boundaries where the shell supplies them.** Warp blocks and kitty/iTerm shell integration expose command/output boundaries, status and prompt navigation. Mica already has zsh preexec/precmd hooks; make those structured events the source of truth for command state and landmarks, while keeping screen inference as a fallback for other programs and shells.
- **Keep restoration honest.** Apple Terminal restores saved window groups. cmux restores layouts and supported agent sessions when hooks provide a resume token. iTerm2's full process survival uses long-lived servers and has explicit limits. Mica should distinguish reopening a project and its tabs from resuming the same running process; durable arbitrary PTY jobs are a much larger architecture and should be opt-in if pursued.
- **Treat splits as a later architecture project.** They are common in Ghostty, Warp and cmux, but Mica's current model is one PTY grid per tab. Add them only with a clear tree/focus/resize model and explicit memory limits per pane.
- **Keep the lightweight promise.** Avoid adopting a browser, cloud account, or heavy block renderer just to match feature checklists. Native rendering, bounded history and transparent per-tab memory costs are differentiators.

## Suggested order

1. **Memory-efficient scrollback** — measure retained rows and bytes, trim blank cells per line, then share attribute storage. Maintain the current hard cap and add latency/memory regression checks.
2. **Pomodoro timer UI** — the status strip prioritizes a clear phase label and countdown, with focus, break and paused states shown in text as well as color. VoiceOver and the timer menu expose the completed-focus count, and skip is available through the menu and VoiceOver action. Settings offer separate automatic starts for focus and break intervals, both on by default. Be Focused also lists completed intervals and optional auto-start in its [Mac App Store description](https://apps.apple.com/us/app/be-focused-pomodoro-timer/id973134470?mt=12).
3. **Optional agent/project sidebar** — show project, branch, folder, agent state and unread notification with clear focus/attention styling; use existing state and keep it off when a user prefers the full-width terminal.
4. **Command landmarks** — make shell start/finish events robust and use them for jump-to-command/output and clearer state; preserve raw PTY behavior when hooks are absent.
5. **Session restoration quality** — test several restored project windows and ordinary windows end to end; distinguish startup commands from surviving processes. Current implementation restores window metadata and launches fresh sessions; it does not resume the previous PTY process or scrollback.
6. **Split panes** — design a bounded pane tree and per-pane resource accounting before UI implementation.
7. **Release reliability** — notarized install/update flow depends on Developer ID and release credentials; keep development builds separate from the installed release.
8. **Quick terminal** — useful, but lower value than agent visibility and memory-efficient history for Mica's project-first workflow.

## Sources

- cmux: [Getting started (sidebar, updates, restoration)](https://cmux.com/docs/getting-started), [product overview](https://cmux.com/), [Task Manager](https://cmux.com/docs/task-manager)
- Warp: [Blocks](https://docs.warp.dev/terminal/blocks), [block actions](https://docs.warp.dev/terminal/blocks/block-actions), [command search](https://docs.warp.dev/terminal/entry/command-search), [tab configs](https://docs.warp.dev/terminal/windows/tab-configs)
- [Ghostty feature overview](https://ghostty.org/docs/features), [keybinding actions](https://ghostty.org/docs/config/keybind/reference)
- iTerm2: [documentation index](https://iterm2.com/documentation.html), [session restoration](https://iterm2.com/documentation-restoration.html), [shell integration](https://iterm2.com/documentation-shell-integration.html)
- kitty: [shell integration](https://sw.kovidgoyal.net/kitty/shell-integration/), [scrollback configuration](https://sw.kovidgoyal.net/kitty/conf/), [overview and shortcuts](https://sw.kovidgoyal.net/kitty/overview/)
- [Apple Terminal window groups](https://support.apple.com/guide/terminal/use-window-groups-trml15652/mac)
- [Conductor and the parallel-agent ecosystem](https://rustman.org/wiki/conductor-parallel-agents/), [Conductor vs Superset](https://defract.dev/blog/conductor-vs-superset), [Best tools for managing parallel agents](https://nimbalyst.com/blog/best-agent-management-tools-2026/)
- [Git worktrees with Claude Code](https://www.developersdigest.tech/blog/git-worktrees-claude-code-parallel-agents-guide)
- [Ghostty configuration reference](https://ghostty.org/docs/config/reference)

### Reading while output continues

[Ghostty’s scroll-to-bottom reference](https://ghostty.org/docs/config/reference#scroll-to-bottom) distinguishes keyboard input from incoming output; its documented default returns to the bottom on keystrokes but does not do so on output. Mica now preserves a retained reading row even when its history ring wraps, with a PTY regression covering replacement, eventual eviction and return to live output. Alternate-screen applications that redraw existing screen cells remain a separate behavior; this regression covers ordinary scrolling output.

### Accessible timer progress

[Apple’s AppKit accessibility guidance](https://developer.apple.com/library/archive/documentation/Accessibility/Conceptual/AccessibilityMacOSX/EnhancingtheAccessibilityofStandardAppKitControls.html) calls for meaningful control labels and explicit context for assistive clients. Mica’s timer label now includes the completed-focus count alongside phase, remaining time and its action. Automated UI checks cover zero and singular counts through a shared two-window timer transition; manual VoiceOver verification remains outstanding.

### Retained-history reflow

The [Neovim libvterm screen implementation](https://github.com/neovim/neovim/blob/master/src/nvim/vterm/screen.c) reflows the rows held by libvterm's live grid. Its [terminal integration](https://github.com/neovim/neovim/blob/master/src/nvim/terminal.c) stores scrollback in the Neovim buffer and serves rows back through the push/pop callbacks, so that buffer participates in resize. Mica keeps a separate bounded ring of compact cells and hyperlink IDs. A faithful width reflow must group rows by continuation flags, carry a logical line across the ring/live-grid boundary, preserve cells and links as history rows move back to the screen, and remap the scroll anchor and search cursor. AppKit selection uses view coordinates; Mica now clears it after a successful grid-size change, while a future history projection must keep that policy or rebase coordinates. Any transform also needs to enforce the existing per-session history byte cap during allocation. The current callbacks expose cells and continuation but no hyperlink metadata or target row for pop, so an extension or a separate display projection is needed before implementing this without losing links or breaking live-grid alignment.

### Wrapped links after scrolling

The original `mica_session_row_continues` reported no continuation while viewing history, because the vendored 0.3.3 scrollback callback supplied cells without line metadata. Reading `vterm_state_get_lineinfo` inside that callback cannot recover it reliably: `state.c` moves line metadata before the screen scroll callback runs.

The [Neovim libvterm header](https://github.com/neovim/libvterm/blob/934bc2fbf21800ac3458a499df8820ca5fb45fd3/include/vterm.h) provides the opt-in `sb_pushline4` callback with an explicit continuation flag. Its [state implementation](https://github.com/neovim/libvterm/blob/934bc2fbf21800ac3458a499df8820ca5fb45fd3/src/state.c) invokes an opt-in `premove` hook before updating metadata; the [screen implementation](https://github.com/neovim/libvterm/blob/934bc2fbf21800ac3458a499df8820ca5fb45fd3/src/screen.c) uses that hook to capture departing rows and supplies old line metadata during resize. These sources were inspected locally on 2026-09-30 at commit `934bc2fbf21800ac3458a499df8820ca5fb45fd3`.

The opt-in `premove` and `sb_pushline4` callback portion is now backported, retaining the existing callback fallback. Direct unit tests cover cells and continuation flags, callback opt-in, three damage modes, resize capture, alternate screen and partial scroll regions. Mica now opts into the continuation-aware push callback, retains a bit on each history row, and maps displayed rows through history and folds. Core tests verify history flags and folded barriers; UI tests click both parts of a wrapped URL in scrollback and preserve hard-newline and adjacent-link separation. UI coverage also opens the exact URL from both sides of the history/live boundary and after history-ring replacement. PTY regressions verify continuation flags across the boundary, separation from alternate-screen content, and preservation after ring replacement. A direct resize test found and now guards against losing rows from a wrapped group while shrinking then growing the grid; the fix sends the whole departing group to history before backfill. Width-resize callbacks now retain pushed rows tagged with their original physical width, with a UI regression for a wrapped row moving into scrollback when the grid narrows. Hard newlines, separate adjacent URLs, folded placeholders and alternate-screen rows must not join unrelated text. Resize restores continuation metadata when history is popped into the live grid through Mica's opt-in `sb_popline4` extension; direct regressions cover extended-only callbacks, precedence and legacy fallback, and PTY coverage preserves wrapped and hard-newline flags after height growth. History at a different column width is conservatively excluded from URL joining. Reflowing retained history across column-width changes remains open; do not claim complete resize support.

Do not replace the vendored library wholesale: the inspected fork still contains the `screen_resize failed to update cursor position` abort that Mica already patches out. Preserve every existing safety patch and add a regression for the continuation backport, then run the PTY suite, sanitizers and stress harness.
