# Cycle 9 — 0.1.0-alpha.13

Ship small improvements to repeated dictation, agent visibility and focus control. Cycle 8 Part B remains unbuilt; this cycle implements snippets, a minimal sidebar, and two independent slices of the timer work.

## Execution rules

- Work in order. Each numbered item is one worker pass, **45 minutes maximum including verification**, confined to one subsystem.
- If an item exceeds its budget, stop with a coherent diff and report it partial; defer unfinished behavior and its documentation.
- Native AppKit, local-first, no telemetry, web views, new dependencies or background helpers. No new polling loops.
- Keep terminal/session management in C and `src/mica_app.m` as wiring. Reuse existing state, actions and libvterm; no parser changes planned.
- Preserve one process for all project windows. Sidebar state is per window; timer state follows the existing shared ownership model.
- Tests use isolated defaults/storage, fake transcripts, injected clocks and local PTY fixtures. Never use microphones, model downloads, agent prompts or user startup files.
- After changes: `make app SIGN_ID=-` and `make test`. After touching `src/session.c`, `src/mica_app.m` or libvterm: also `make sanitize FUZZ_SEEDS=1` and `make stress STRESS_SEEDS=1`.
- Use the existing bounded stress pass; no CPU burners, parallel load, repeated soak runs or cycle 8 A2 load experiment. Allow at most five minutes per check; timeout is unverified, never PASS.
- Reviewer runs unavailable bundle/helper builds using cached dependencies. Workers leave changes uncommitted; no signing, publishing, tags or installed-app changes.
- UI acceptance uses offscreen tests and inspected dark/light renders. Optional features must allocate nothing while disabled; compare short, matched idle-footprint samples before release.

## 1. Whole-transcript dictation snippets — 30–40 minutes

**Subsystem:** dictation text processing. High reuse value with a small deterministic implementation.

- Add `snippets.txt` beside the vocabulary file: `spoken phrase => expansion`; Edit → Edit Snippets… opens it.
- Match the entire corrected transcript after trimming whitespace and case folding. No substring, fuzzy or recursive expansion.
- Cap the file at 64 KiB, 100 entries, trigger at 128 characters and expansion at 2,048 characters. Reject malformed entries, duplicate normalized triggers and control characters, including newlines.
- Expansion is prompt text through the existing insertion path; never send Return. Undo restores the raw transcript under existing eligibility rules.
- Read on demand during dictation; no watcher or retained idle cache. Keep matching/loading in a small independently testable unit.

**Acceptance:** fake transcripts prove exact expansion, partial/nonmatching text unchanged, correction-before-expansion, duplicate/oversized/control rejection, and one-step raw undo. A local PTY fixture proves shell-looking expansion remains unexecuted prompt text.

## 2. Optional agent sidebar MVP — 40–45 minutes

**Subsystem:** workspace presentation. Reuse information already available to the palette and tabs.

- View → Show Sidebar, off by default; retain its visibility for the current window lifetime.
- Native fixed-width list: tab name, shortened folder, cached branch, existing agent state and unread attention indicator. Use text/icons as well as color.
- Click or keyboard activation selects the existing tab; selection and accessibility labels follow tab state.
- Refresh through existing state updates. No filesystem scans, ports discovery, sorting, drag handling or independent agent inference.
- Hidden width is zero; release sidebar views when hidden. Use a separate presentation class with thin controller wiring.

**Acceptance:** toggle restores terminal width; PTY rows/columns follow resize without losing fixture output; activation switches tabs; fake-agent state/badge updates appear; two windows remain independent. Inspect 600/800/1200 px dark/light renders and Reduce Transparency behavior. Hidden lifecycle retains no sidebar view.

## 3. Optional menu-bar timer — 30–40 minutes

**Subsystem:** timer presentation. Keeps focus visible while another app is foreground.

- Add an off-by-default preference for one process-wide `NSStatusItem`.
- Show phase and remaining time; its menu dispatches existing Start/Pause/Resume and End Phase actions.
- Observe the existing shared timer tick; do not introduce another timer, owner or persistence format.
- Create/remove through the existing timer owner lifecycle, including when project windows close. No Dock behavior changes.

**Acceptance:** isolated preference defaults off and persists; repeated enable/disable creates exactly one item and releases it; two-window operations share the same countdown. Injected time covers focus, break and paused titles, action enabled states and accessibility labels. Off state adds no observer or status item.

## 4. Label the current focus session — 25–35 minutes

**Subsystem:** timer metadata. A deliberately small slice of cycle 8 B2.

- Focus → Label… edits a shared plain-text label, capped at 80 characters; reject controls.
- Persist it alongside existing timer state. Show it in the Focus menu and timer accessibility description; preserve countdown priority.
- Label survives pause/resume, window switching and active-timer restoration. Clear on Reset and when beginning the next focus session.
- No history log, goal arithmetic or new status-strip layout.

**Acceptance:** isolated storage round-trips label; old state without a label still loads; malformed labels are ignored. Two windows see the same edit; injected transitions prove pause/resume preservation and reset/next-focus clearing. Existing phase/countdown labels remain intact.

## 5. Alpha.13 documentation and release readiness — 30–40 minutes

**Subsystem:** release metadata and evidence; depends on accepted feature items.

- Update README, ROADMAP and site only for accepted behavior. Extend `build/claim-audit.md` with exact proving tests.
- Prepare consistent alpha.13 version/build metadata and draft release notes; keep public download links on alpha.12 until alpha.13 artifacts are published and verified.
- Keep vocabulary-boost memory/latency labelled UNMEASURED unless reviewer measurements exist. Do not equate text fixtures with audio accuracy.
- Existing competitor notes suffice for this scope; introduce no new current competitor claims.
- Record commands, durations, results, inspected renders, matched idle-footprint samples and unavailable checks in `build/codex-report-9.md` (maximum 60 lines).

**Acceptance:** `git diff --check`, existing release tests and local link/CSP checks pass; final app/test gates pass within their limits. Each new claim has evidence. Default-off features show no reproducible idle-footprint increase; otherwise alpha.13 readiness remains unverified. Signing and publication belong to the reviewer.

## Explicitly deferred

- Sidebar drag/reorder, persistence across launches, cross-window aggregation, ports and changed-files summaries.
- Timer daily goal and bounded local history: require explicit completion/skip semantics, duplicate prevention and calendar-boundary tests.
- Worktree picker and cleanup: enumeration plus safe deletion is larger than a single presentation change.
- Agent resume adapters: require verified CLI contracts and explicit opt-in; restored tabs continue starting fresh shells.
- Bounded scrollback restore and retained-history reflow: separate storage, privacy, hyperlink and anchor design.
- Liquid Glass tab strip, splits, quick-terminal drop-down, broader shells and review-before-insert dictation.
- Cycle 8 A2 load reproduction; boost/audio benchmarking and refreshed GIF/MP4. Existing unverified caveats remain documented.

## Top three risks

1. **Shared timer ownership:** duplicate status items or stale labels after owner/window teardown; cover lifecycle and two-window transitions.
2. **Sidebar resize regressions:** reduced columns can expose retained-history/link limitations; test through PTYs and preserve conservative existing behavior.
3. **Verification and memory claims:** cached helper builds, baseline variation or the unresolved PTY flake may block readiness; report missing evidence and never substitute repeated reruns for a fix.