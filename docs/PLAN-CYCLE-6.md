# Cycle 6 plan: discoverability, dictation control, command landmarks

Source: three 2026-10-01 research passes (terminal UI/UX, multi-agent workflows, dictation/timer/Tahoe). Ranked by value vs effort; deferred items listed at the end. Constraints stay: native AppKit, C core for terminal logic, no web views, no telemetry, no new dependencies, idle memory not raised (~55-60 MB), per-window state (see AGENTS.md).

Rules: same as docs/IMPROVEMENT-PLAN.md (no push/tags/signing, no launching GUI bundles, no real agent calls, do not weaken tests, leave changes uncommitted in the working tree and list them). Work items strictly in order; finish each (tests green) before starting the next. Every item ends green on `make test`, `make sanitize FUZZ_SEEDS=2`, `make stress STRESS_SEEDS=3`; UI changes get `make ui-audit` renders (dark + light, 600/800/1200 px) that you open and inspect. Anything unverified goes in the report.

## 1. Command palette + tab switcher (⌘⇧P)
- Native overlay (AppKit text field + table, closes on Esc, fully keyboard and VoiceOver operable, respects Reduce Transparency; opaque surface, no glass behind text).
- Lists every menu action with its current shortcut shown inline (built from the existing menu tree in `buildMenus`, so it cannot drift), plus "Go to tab" rows: tab name, folder, git branch, agent state; fuzzy/substring match, most recently used first.
- Enter runs the action via the existing selector; no new global state (per window controller).
- Tests: opens/closes, filter results, running an action, switching tab, disabled items not run, two-window isolation, accessibility labels. Add Help-menu entry and ⌘/ card line.

## 2. Dictation: toggle mode and undo-last
- Settings: "Dictation key behaviour" = Hold (default, unchanged) or Toggle (press once to start, again to stop). Strip shows a distinct label for toggle mode ("Listening · press ⌥ to stop"). Esc cancels without inserting.
- New action Edit → Undo Last Dictation (and in palette): removes exactly the text Mica last inserted from the prompt if the user has typed nothing since; otherwise disabled with a tooltip. Never sends Return.
- Tests (no microphone, no speech helper; inject a fake transcript): default is Hold, setting persists in isolated defaults, toggle start/stop/cancel, undo enabled/disabled states, strip layout at 480/600/800/1600 px with no overlap (extend the existing matrix).

## 3. Command landmarks (OSC 133) and prompt navigation
- Extend the zsh integration in `src/session.c` to emit OSC 133 A/B/C/D (with exit status) and have the C session record per-row prompt/command marks within the existing history budget (compact, bounded, survive scroll/clear; handle resize as folds/links do today).
- Actions: Jump to Previous/Next Prompt (⌘↑ / ⌘↓ only when the shell is at a prompt and the program is not full-screen; otherwise pass keys through unchanged), Select Last Command Output, Copy Last Command Output. Also surface exit status as a small non-colour-only marker in the left padding when the command failed.
- Programs that print OSC 133 themselves must not break; unknown params ignored; vendored libvterm patches only if unavoidable (add PATCHES.md entry + fuzz test).
- Tests: session tests for marks across scroll, clear, alternate screen, resize, history ring wrap; fuzz seed with random OSC 133 payloads; UI tests for jump and copy-output. `make sanitize`/`stress` must stay green.

## 4. Keyboard Quick Select
- ⌘⇧U (name it "Quick Select…"): overlays short hint labels on visible URLs, absolute/relative file paths (existing files only get a "file" style) and git hashes; typing the label copies (⌥ held: opens / reveals). Esc leaves. Built on the existing visible-grid reader and wrapped-URL joining; no helper process.
- Tests: detection of URLs (incl. wrapped), paths with spaces rejected unless quoted, hashes, hint collision-free for >26 matches, copy goes to pasteboard (isolated), nothing executes.

## 5. Notifications: finished vs waiting, per-tab mute
- Agent notifications distinguish "needs input" from "finished" in title and sound-free default; add per-tab "Mute notifications" toggle (tab context menu + palette), persisted with tab state only as a boolean.
- Tests with the existing fake-agent harness: both cases, mute honoured, still shown in tab badge.

## 6. Docs
README (keys table, features), `docs/ROADMAP.md` (move done items, keep the rest ranked, add the deferred list below), site only where behaviour changed (recompute CSP hashes if `<style>`/`<script>` change), `docs/COMPETITORS.md` rows if a claim changed.

## Deferred to cycle 7 (do not start)
Optional agent/workspace sidebar; timer session label, daily goal and local history, menu-bar timer extra; local dictation vocabulary and snippets; review-before-insert draft; worktree picker/cleanup; agent resume adapters; bounded scrollback restore; changed-files summary; quick-terminal drop-down; Liquid Glass on the tab strip.

## Report
Write `build/codex-report-6.md` (max 60 lines): first line says whether every item is done and every check green. Per item: status, files, evidence (commands + result lines), unverified. End with changed-file list and top three risks.
