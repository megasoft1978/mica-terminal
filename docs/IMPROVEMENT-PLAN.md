# Improvement plan (worked in cycles)

Owner of judgement: Claude (reviews each cycle). Worker: Codex (`codex exec`, GPT 6 Luna, medium effort). The worker fixes and iterates until each item's acceptance checks pass, then writes a short report; the reviewer reads only the report and the diff and either accepts or sends corrections as the next cycle.

## Token budget (reviewer is Claude Sonnet 5.5)

The worker does the expensive reading, editing and test iteration; the reviewer never reads the worker's log (it is megabytes). Per cycle the reviewer reads only `scripts/review-cycle.sh <n>` (report, diff summary, one PASS/FAIL line per check, about 80 lines), then opens individual hunks only for risky areas (threads, memory, parsing). Corrections go into the next cycle's plan section, not into chat. Waiting uses one background wait on the report file, not polling.

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

## Cycle 2 (reviewer accepted cycle 1: all checks green, committed by the reviewer because the worker cannot write `.git`; do not try to commit, leave changes in the working tree and list them)

1. **Prove the two unverified cycle-1 claims.** (a) Theme mode (Dark/Light/System) survives a relaunch: test through a fresh delegate reading an isolated `NSUserDefaults` suite. (b) Increase Contrast: render the audit with the accessibility flag simulated (inject it through a testable hook rather than toggling the OS) and check separators and secondary text meet at least 4.5:1 against the background in both themes; assert the contrast numbers in a test.
2. **Tabs and folders survive quitting.** On quit (and on window close), write each window's tab names, working folders and configured startup commands (not running processes or scrollback) to a small JSON file under `~/Library/Application Support/Mica/` (path overridable in tests). On launch without an explicit layout, reopen the tabs in their folders. Project windows launched with `mica://open?layout=` keep using their layout file and must not be affected. Corrupt, missing or oversized state files must be ignored safely. Never restore into a folder that no longer exists (fall back to home). Add tests, including a corrupt-file case and a stress action that quits and relaunches repeatedly.
3. **Dictation strip at every width.** Render and layout-test the dictation strip (preparing, listening with 0/3/40 words, failed, denied microphone) at 480, 600, 800 and 1600 px in both themes: label, words and hint rectangles never overlap, the last words stay visible, and the hint drops first. Fix any overlap.
4. **Docs.** Update `docs/ROADMAP.md` and README/site only where behaviour changed.

Same report format, file `build/codex-report-2.md`.

## Cycle 3 (reviewer accepted cycle 2: `make test`, `sanitize`, `stress` green; committed by the reviewer)

Close the gaps your own report listed, plus one security decision:

1. **Restore names and folders only, never commands.** A state file must not be able to make Mica run a command at launch. Remove commands from the state file and from restoration; a restored tab opens an ordinary shell in its folder. Write the file with mode 0600 in a 0700 directory, validate every field (string lengths, at most 9 tabs, absolute paths that exist and are directories), and add tests for a hostile file (huge strings, control characters, `../`, a symlink to a file, a command field that must be ignored).
2. **Quit/relaunch stress action** in `tests/stress_app_ui.m` (save state, tear down the window, start a new one that restores) with the isolated state path, so `make stress` exercises it under the sanitizers.
3. **Automated dictation-strip overlap test** across the matrix you rendered (states x 480/600/800/1600 px x dark/light): label, words and hint rectangles never overlap and the last word is inside the visible rect. Fix any failure. Finish and inspect the Light matrix renders.
4. **Docs**: README/ROADMAP only where behaviour changed.

Same rules; report in `build/codex-report-3.md`. If every item is done and every check green, say so plainly in the first line of the report.

## Cycle 4 (alpha 7 released; Intel/universal builds are explicitly out of scope; never launch `build/Mica.app` or any GUI bundle from the sandbox, use the offscreen test/render binaries only)

1. **Scrollback that fits agent output.** Today a 2 MiB history cap is about 650 lines at 80 columns (see `docs/ROADMAP.md`). Measure current per-line cost, then raise capacity to at least 10,000 lines at 80 columns **without raising idle memory**: store history cells compactly (for example a run-length or attribute-table encoding) or store only the used width of each line. Acceptance: a test that pushes 20,000 lines and can still search and scroll to line 1; `scripts/measure-footprint.sh`-style measurement (or a test-side proxy) showing idle footprint unchanged and worst-case history memory reported in `docs/PERFORMANCE.md`; fuzz and stress green.
2. **Wrapped URLs.** A URL broken across two terminal lines by soft wrap opens as one address on Command-click (and underlines as one). Tests for wrapped, unwrapped, adjacent-URL and non-URL cases.
3. **Quick terminal hotkey (opt-in).** Settings gets a checkbox "Show Mica with a global shortcut (⌃⌥Space)"; off by default. Use Carbon `RegisterEventHotKey` (no Accessibility permission). Pressing it brings the frontmost Mica window forward, or opens a new window if none. Tests for enable/disable/persistence (isolated defaults) and that disabling unregisters.
4. **Docs and roadmap** updated for what changed. Report in `build/codex-report-4.md`, same format, first line states whether every item is done and every check green.
