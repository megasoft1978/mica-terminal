# Improvement plan (worked in cycles)

Owner of judgement: Claude (reviews each cycle). Worker: Codex (`codex exec`, GPT 6 Luna, medium effort). The worker fixes and iterates until each item's acceptance checks pass, then writes a short report; the reviewer reads only the report and the diff and either accepts or sends corrections as the next cycle.

## Rules for the worker (hard limits)

- Work only in this repository. Never run `git push`, never create tags or releases, never run `make notarize`/`make dmg`/`make dist`/signing, never touch `/Applications`, `~/Desktop` launchers or the keychain, never handle passwords or tokens.
- Keep changes surgical and in the style of the surrounding code (comment density, naming). No new dependencies, no drive-by refactors. Do not weaken or delete an existing test to make it pass; fix the cause.
- Commit locally after each finished item with a concise message and no attribution lines.
- Every item ends green on: `make test`, `make sanitize FUZZ_SEEDS=2`, `make stress STRESS_SEEDS=3`. If a check is flaky, find why and fix the test or the code; do not just rerun.
- Verify UI changes with `make ui-audit` and read the PNGs in `build/ui-audit/`. Update docs (README, site, `docs/*.md`) only where behaviour changed; if `docs/index.html` `<style>`/`<script>` change, recompute the CSP hashes (the file explains how).
- Anything you could not verify must be listed as unverified in the report. Do not invent APIs or flags.

## Items for cycle 1 (in order)

1. **Deterministic test suite.** `make test` must pass repeatedly (run it 3 times) under load. Find the tests that depend on wall-clock timing or keyboard layout and make them condition-based. Acceptance: 3 consecutive green runs, plus one while `make stress` runs in parallel.
2. **Slow polls.** The app log has shown `slow-session-poll duration_ms=310..360` with 7 tabs. Add a repeatable measurement (test or tool) with 7+ tabs emitting output, find what makes a poll slow (agent-activity screen scanning, git branch reads, process lookups, allocations), and remove the cost without changing behaviour. Acceptance: the measurement shows a poll with 7 busy tabs staying under 16 ms on average and 50 ms at worst; behaviour tests unchanged.
3. **Narrow windows.** At 800 px and at 600 px wide, the status bar and tab strip must not truncate the folder or timer into unreadable text (see `build/ui-audit/07-dark-narrow.png`: "Ready · …ote"). Prioritise: timer, folder name, then hints; drop hints first; never overlap. Add renders at those widths to `tools/render_ui_audit.m` and a layout test that asserts no overlapping rects.
4. **Microphone denied and first run.** When microphone access is denied, the dictation strip must offer a clear action that opens System Settings → Privacy & Security → Microphone (use the documented `x-apple.systempreferences:` URL). Add a test for the state and an audit render. Keep the model prefetch behaviour as is.
5. **Follow system appearance.** Add "System" to Settings → Theme (default stays Dark to avoid a surprise), following macOS appearance changes live, and honour Increase Contrast for separators and secondary text. Tests: setting persists, switching appearance updates colours, all states render in light and dark in `make ui-audit`.
6. **Roadmap and docs.** Update `docs/ROADMAP.md` (remove what is done, keep the rest ranked) and any README/site sentence that changed.

## Report format (write to `build/codex-report-<cycle>.md`, at most 60 lines)

For each item: status (done / partial / blocked), what changed (files), evidence (the commands run and their result lines), and anything unverified. End with the commit list (`git log --oneline` since the cycle started) and the top three risks you see.

## Later cycles (reviewer decides after cycle 1)

Tabs and folders surviving quit; scrollback capacity (compact cell storage); per-tab status sidebar; a global-hotkey quick terminal; Intel/universal build; split panes.
