# What comparable tools do, and where Mica stands

Researched 2026-09-30 from each product's own documentation. "Done" means shipped in this repository; the rest is ranked by user value, effort, and fit with Mica's small, local-first design.

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

For Mica, the best fit is to keep the timer visible but quiet: make its phase, remaining time and actions more legible and accessible; add an optional skip/next-phase action and a small local completed-focus count; keep auto-start opt-in. Task planning, app blocking and gamified rewards add scope and would distract from Mica's terminal-first workflow.

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
| Quick terminal on a global hotkey | Not done. Medium |
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
2. **Pomodoro timer UI** — clarify phase/time/action hierarchy and VoiceOver labels, add an optional skip/next action and completed-focus count, and keep automatic phase changes opt-in. The status bar already keeps the timer visible and the model/state synchronize across windows.
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
