# Cycle 7 plan: dictation accuracy with a project vocabulary

Starts only after cycle 6 is reviewed and committed (both touch `src/mica_voice_controller.m` and `src/mica_app.m`). No language model is involved (a small local correction model was considered and deliberately parked). Same rules as docs/IMPROVEMENT-PLAN.md and docs/PLAN-CYCLE-6.md. Tests never use a microphone or the speech helper: inject fake transcripts.

Research facts (2026-10-01): Mica pins FluidAudio 0.17.4 (`voice/Package.resolved`). Upstream documents custom-vocabulary rescoring for Parakeet TDT 0.6B v2/v3 through a separate CTC encoder (`CustomVocabularyContext(terms:)`, `CustomVocabularyTerm(text:aliases:)`, streaming via `SlidingWindowAsrManager`), about 130 MB peak vs 66 MB for TDT alone, an extra model download, best with short focused lists (terms of 4+ characters, tested to 230). Whether the 0.17.4 tag exposes this API is UNVERIFIED (no local checkout was available).

## 1. Deterministic vocabulary corrector (Objective-C, no model, ~0 MB)
- New small unit (own file, pure functions, unit-testable without AppKit): `correct(transcript, terms) -> corrected`. Applied in `finishTranscript:` before insertion; raw transcript kept for an "Undo correction" step (reuse cycle 6's Undo Last Dictation: one undo restores the raw text).
- Matching: Unicode/case fold; punctuation-insensitive keys so `mica terminal`, `mica-terminal`, `MicaTerminal`, `mica_terminal` map to the canonical spelling; 1-3 word spans on token boundaries; Damerau-Levenshtein plus a bounded phonetic key. Rewrite only for exact normalized match, or high similarity AND phonetic agreement AND a clear margin over the runner-up. Never touch stopwords or common words, terms under 4 characters (unless explicit alias), or change several unrelated words at once. Deterministic tie-breaking.
- Term sources, in trust order: (a) user file `~/Library/Application Support/Mica/vocabulary.txt` (one term per line, optional `spoken => Canonical` alias; size/line caps, ignore control characters, never executed); (b) project name and current git branch; (c) basenames and path components from `git ls-files` of the tab's folder (capped, refreshed on tab cwd change, computed off the main thread, no network); (d) identifiers mined from a bounded ring of recent visible terminal text, lower confidence, expiring. Per-tab terms merge with global ones; dedupe; hard cap on total terms (for example 500).
- Settings: "Improve dictation with project vocabulary" (on by default, local only) and "Edit Vocabulary…" which reveals the file. Palette entries for both.
- Tests: table-driven corrector cases including must-not-rewrite cases (common words, near misses, short terms, ambiguous runner-up), hostile vocabulary file (huge, control chars, duplicate, `=>` abuse), git-ls-files source with spaces/unicode names, recent-text expiry, undo restores raw, two-window isolation of per-tab terms. Add a measured-latency check (corrector under 5 ms for 500 terms and a 200-word transcript) and an accuracy fixture of at least 40 realistic coding-prompt transcripts (raw vs expected) with before/after hit rate recorded in `docs/PERFORMANCE.md`.

## 2. Native vocabulary boosting in the speech helper (gated, opt-in)
- Step 2a, verify first: resolve the package (network allowed only for `swift package resolve` in `voice/`), read the pinned 0.17.4 source and report whether `SlidingWindowAsrManager` vocabulary configuration exists. If not, evaluate the smallest FluidAudio bump that has it; record version, extra model name and size, and API diff in the report. Stop and report instead of guessing if it needs a risky bump.
- Step 2b, only if 2a is positive: pass the same merged term list (cap about 230, 4+ characters, aliases from the vocabulary file) to the helper after `loadModels`, behind a Settings checkbox "Boost vocabulary while dictating (downloads an extra model, about N MB)", off by default. The CTC model downloads in the background like the speech model, with progress in the status bar; the helper keeps exiting after dictation so the extra memory exists only while talking.
- Measure and document in `docs/MEMORY-BASELINE.md`: helper RSS with and without boosting, extra latency per dictation, extra disk. If peak helper memory exceeds the documented budget by more than about 70 MB or latency feels worse than about 300 ms per utterance, keep it off by default and say so plainly.
- Run the 40-transcript fixture through both paths where possible (audio fixtures only if license-clean and tiny; otherwise state the comparison is unverified) and report hit rates: raw, corrector only, boosting plus corrector.
- Tests: setting default off and persists; term list built and capped; helper invoked with a fake in test; failure to download the extra model degrades silently to the corrector with a visible status message.

## 3. Docs
README (privacy: vocabulary stays on the Mac; memory table footnote if boosting is on), ROADMAP, MEMORY-BASELINE, site only if claims change.

## Not in scope
Any language model, review-before-insert draft, snippets, cloud services.

## Report
`build/codex-report-7.md` (max 60 lines), first line: whether every item is done and every check green; per item status, files, evidence, unverified; for 2a state the verified API facts.
