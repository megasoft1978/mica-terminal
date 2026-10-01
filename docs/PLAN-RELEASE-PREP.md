# Release prep for a finished cycle (worker steps; the reviewer then signs, tags and publishes)

Input: cycle number N and the next alpha number A (cycle 6 -> alpha.11, cycle 7 -> alpha.12). Same safety rules as docs/IMPROVEMENT-PLAN.md: no push, no tags, no signing/notarization, no GUI bundle launch, leave changes uncommitted.

1. Bump version per docs/RELEASING.md step 1 (`include/mica.h`, `Info.plist`, keep equal; revision string 0.1.0-alpha.A).
2. Update every visible claim to the new behaviour: README (what you get, keys table, FAQ, badges and download links to `v0.1.0-alpha.A`, with the same link shapes as today), `docs/index.html` (visible version, ZIP size placeholder to be filled after packaging, feature text, JSON-LD `softwareVersion`/`downloadUrl`, then recompute the CSP script/style hashes as the file explains), `docs/ROADMAP.md`, `docs/COMPETITORS.md` only if a claim changed.
3. Refresh media from the current build: extend the demo script (`tools/render_demo.m`, `tools/render_marketing.m`, `scripts/render-demo-assets.sh`) so the GIF/MP4 and hero images show the new features of cycle N (palette, dictation toggle, prompt navigation, quick select, etc.; for cycle 7, vocabulary correction), then run `make demo-assets` and `make screenshots` if that target exists. Open the PNG/GIF frames and check legibility in dark and light. Keep the GIF under its current size budget and keep captions truthful (no real agent invoked).
4. Write release notes to `build/release-notes-N.md`: title line `Cycle N: <short theme>`, a short bullet list of user-visible changes, known limits, and checksums placeholder.
5. Run `make validate`; report in `build/codex-release-prep-N.md` (max 40 lines): changed files, evidence, anything unverified.
