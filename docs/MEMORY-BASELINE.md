# Memory measurements

These samples describe Mica process memory on one macOS system. They are snapshots, not a controlled benchmark, and do not establish a memory reduction for a particular workflow.

| Workload | Mica RSS | Apple physical footprint |
| --- | ---: | ---: |
| One idle shell tab | About 80 MiB | About 37 MiB |
| Three idle shell tabs in one window | About 98 MiB | About 33 MiB |

The samples were taken on 2026-09-26. Test shells skipped user startup files with `MICA_TEST_NO_STARTUP=1`; a normal login shell can use more memory. The windows were not measured under identical conditions, so the footprint values should not be compared with each other as a performance result.

Run `make memory` to sample Mica, Claude Code, and Codex processes. For a useful local comparison, record the same projects, tab count, window size, shell startup configuration, and running commands before and after a change. Process RSS sums may count shared pages more than once. Shell child processes are reported separately by the operating system.

Mica allocates scrollback as output moves off-screen and caps it at 2 MiB per terminal session. The number of retained lines depends on the terminal width.

## Mica vs. Terminal.app + Zellij

Zellij is a terminal multiplexer, not a terminal emulator: it needs a host terminal to display anything. The fair comparison is therefore Mica against a terminal app running Zellij.

Setup (2026-09-29, macOS 26.6, Apple Silicon, Zellij 0.43.1, one window, three empty tabs, idle, no startup files, shells excluded from both sides):

| Setup | RSS | Apple physical footprint |
| --- | ---: | ---: |
| Mica (3 tabs) | About 178 MiB | About 77 MiB |
| Terminal.app + `zellij attach` (server + client, 3 tabs) | About 171 MiB | About 64 MiB |
| Zellij server + client alone (no host terminal) | About 37 MiB | About 23 MiB |

In this single idle sample Mica used about as much memory as Terminal.app plus Zellij, and slightly more by physical footprint. Mica does not reduce memory compared with that combination; its advantage is one integrated app (tabs, agent status, dictation, timer) rather than lower memory. Results vary with the host terminal, window size, and workload, so treat this as a snapshot, not a benchmark.
