# What comparable tools do, and where Mica stands

Researched 2026-09-29 from the tools' own pages and reviews (sources at the end). "Done" means shipped in this repository; the rest is ranked by value against effort.

## The field

| Tool | What it is | Signature ideas |
| --- | --- | --- |
| [cmux](https://cmux.com/) | Native macOS terminal (Ghostty engine) built for coding agents | Vertical tab sidebar that doubles as a status board: git branch, PR, folder, ports, latest notification per workspace; splits; agent-triggered pane flash; built-in scriptable browser |
| [Warp](https://docs.warp.dev/guides/agent-workflows/how-to-run-multiple-ai-coding-agents/) | Terminal with its own AI and block UI | Agent notifications, parallel agents in tabs/panes, git worktree per agent, command palette |
| [Ghostty](https://ghostty.org/docs/config/reference) | Fast native terminal | Small set of good defaults, titlebar styles, padding, opacity and blur, quick terminal, splits, config file |
| Conductor, Superset, Crystal/Nimbalyst, Claude Squad | Agent orchestrators | One git worktree per agent, diff review, merge and PR flow, many agents at once, sessions that survive closing the window |
| tmux, Zellij | Multiplexers | Panes and layouts, detach and reattach sessions |

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
| Vertical sidebar with per-tab status (branch, last notification, ports) | Not done. Highest-value next step; the data is mostly available now |
| Split panes | Not done. Large: the layout, focus and resize code all assume one grid per tab |
| Restore tabs after quitting | Not done. Medium; needs a saved layout for windows that were not opened from a project file |
| Diff review and merge or PR flow | Not done. Large; the alternative is to run `lazygit` or `gh` in a tab, which already works |
| Quick terminal on a global hotkey | Not done. Medium |
| Scriptable control (a `mica` command for agents to set a tab's status) | Partly: OSC 9/99/777 notifications and `scripts/claude-notify.sh` |
| Import of Ghostty or iTerm themes | Not done |

## Suggested order

1. Vertical sidebar as an option: per tab, name, branch, agent state, last notification line. It is the feature that most separates the agent-focused terminals from ordinary ones.
2. Restore tabs and folders on relaunch.
3. Split panes.
4. Quick terminal hotkey.

## Sources

- cmux: [site](https://cmux.com/), [repository](https://github.com/manaflow-ai/cmux), [Better Stack guide](https://betterstack.com/community/guides/ai/cmux-terminal/)
- [Warp docs: running multiple coding agents](https://docs.warp.dev/guides/agent-workflows/how-to-run-multiple-ai-coding-agents/)
- [Conductor and the parallel-agent ecosystem](https://rustman.org/wiki/conductor-parallel-agents/), [Conductor vs Superset](https://defract.dev/blog/conductor-vs-superset), [Best tools for managing parallel agents](https://nimbalyst.com/blog/best-agent-management-tools-2026/)
- [Git worktrees with Claude Code](https://www.developersdigest.tech/blog/git-worktrees-claude-code-parallel-agents-guide)
- [Ghostty configuration reference](https://ghostty.org/docs/config/reference)
