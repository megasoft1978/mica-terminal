# Initial macOS process snapshot

Date: 2026-09-26 (local machine). Captured before Mica implementation with `ps` process RSS.

| Process group | Processes | Approximate summed RSS |
|---|---:|---:|
| Zellij | 3 | 14 MiB |
| Alacritty | 3 | 62 MiB |
| Claude Code | 2 | 436 MiB |
| Codex and app-server | multiple | at least 390 MiB |

These are rough per-process RSS sums from one live snapshot, not a controlled benchmark. Shared pages can be counted more than once. Several Mica responsibilities replace parts of Zellij and Alacritty, while Claude, Codex, shells, development servers, and other children remain separate costs. Use `scripts/memory-sample.sh` after the UI is built and compare the same number of tabs in an idle and active state.

The current Zellij configuration keeps 10,000 scrollback lines per pane. Mica grows its history only after output scrolls off-screen and caps allocated history at 2 MiB per session. The number of retained lines depends on terminal width; wider sessions retain fewer lines to keep memory bounded.

## Mica single-session smoke sample

On 2026-09-26, the first idle Mica window with one test zsh session measured about 80 MiB RSS and 37 MiB Apple physical footprint (`footprint -p`). The window was 1100 × 700. `MICA_TEST_NO_STARTUP=1` skipped personal zsh startup files, so a normal shell can use more. This single-session GUI smoke sample is not a controlled comparison with the earlier Zellij/Alacritty snapshot and does not establish a memory win. Re-measure with the same project tabs and workloads before replacing the current setup.
