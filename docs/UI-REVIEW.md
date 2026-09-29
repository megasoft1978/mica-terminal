# Mica UI review and modernization plan

Reviewed 2026-09-29 against the current code (`src/mica_app.m`), the offscreen renders the test suite produces, and Apple's macOS Tahoe guidance (sources at the end). Status 2026-09-29: the first slice (terminal padding, merged title bar with the tabs, unfocused-window state), the bundled font, cursor styles and a Settings window are built. Still open: glass on the tab strip, follow-system appearance, vertical padding and a slimmer status bar. The table below describes the state before those changes.

## What the window is made of today

| Part | How it is built now | Gap versus a modern Mac app |
| --- | --- | --- |
| Title bar | Standard opaque title bar showing the window title | Wastes a row above a second custom row; looks like two stacked bars |
| Tab strip | Custom-drawn 28 pt row inside the content view | Not native tabs, no drag-out, no tab overview, hand-rolled accessibility |
| Terminal area | Cells start at x = 0 | No padding, so text touches the window edge and the rounded corners |
| Status strip | Custom-drawn 32 pt row: mode badge, timer, context, hints, dictation | Dense; hints and timer compete; small type (now 11.5 pt) |
| Project badge | Text at the right end of the tab strip | Easy to miss; duplicates the title |
| Materials | Solid `#1E1E1E` (or white in the light theme) | No translucency, no Liquid Glass, no vibrancy |
| Settings | Sheets for project tabs and timer only | No preferences for font, size, theme, cursor, opacity |
| Font | JetBrains Mono if installed, else the system monospace | Not bundled, so the look differs between machines |
| Cursor | Block only | No bar, underline or hollow-when-unfocused |
| Focus state | None | Inactive windows look identical to active ones |

## Recommended direction

Make Mica look like a Tahoe-native terminal: content edge to edge, controls floating on glass, everything else quiet. Ranked by user-visible value against effort.

### Stage 1: quick, low risk (about a day)

1. **Terminal padding.** Add 8–12 pt of inset on all sides (Ghostty exposes this as `window-padding-x/y`, with `window-padding-balance` to spread leftover space evenly). Biggest single change to how it feels.
2. **One title area, not two.** Use `titlebarAppearsTransparent`, `titleVisibility = hidden` and `NSWindowStyleMaskFullSizeContentView`, and put the tab strip in the title bar row beside the traffic lights (the Ghostty "transparent" / "tabs" titlebar look). Reclaims about 28 pt of vertical space.
3. **Unfocused state.** Dim the cursor to a hollow block and lower the tab strip contrast when the window is not key.
4. **Bundle a font.** Ship one monospace font (for example JetBrains Mono, already the preferred one) under its license so every install looks the same; offer SF Mono as an alternative.
5. **Cursor styles.** Block, bar, underline, with blink on/off.

### Stage 2: native structure (a few days)

6. **Native window tabs or a native segmented tab control.** Either adopt `NSWindow` tabbing (free tab overview, drag-out, standard shortcuts) or keep the custom strip but build it from real `NSView`s so hit-testing, accessibility, focus rings and drag reordering come from AppKit rather than hand-written code.
7. **Real toolbar for the actions** (new tab, find, timer, dictation). On macOS 26 `NSToolbar` groups items on glass automatically; use `isBordered = false` for the non-interactive title/status items so they do not get glass.
8. **Preferences window (⌘,).** Font and size, theme (dark, light, follow system), cursor, padding, opacity, notifications, timer, dictation. Replace the one-off sheets.
9. **Status strip becomes a slim, single-purpose bar.** Left: folder or mode. Center: nothing. Right: the timer as a small capsule. Move the shortcut hints to the Help menu and an on-demand ⌘/ card; they are noise for people who already know the keys.

### Stage 3: Tahoe polish (larger)

10. **Liquid Glass.** Put the tab/toolbar row on `NSGlassEffectView` (group related elements in `NSGlassEffectContainerView`), keep the terminal itself opaque or lightly translucent (`background-opacity` plus blur in Ghostty), and let terminal content run edge to edge under the floating glass with `NSScrollView` scroll-edge effects. Limit glass to navigation and controls, per Apple; never behind the text.
11. **Follow system appearance by default** with the current pinned dark as an option, plus accent color for selection and focus.
12. **SF Symbols in menus** (Tahoe shows one icon column in menus) and consistent control sizes; avoid hard-coded control heights and test with `prefersCompactControlSizeMetrics` if a dense layout is needed.
13. **Quick terminal**: a global hotkey drop-down window.
14. **Window state restoration** for position, size and tabs across launches (the frame autosave is a start).

## Things to avoid

- Glass behind terminal text or full-window transparency by default; it hurts legibility.
- More chrome. Warp-style block UIs and AI bars trade render speed for features and do not suit a plain terminal.
- Hard-coded sizes and colors that ignore accessibility settings (Increase Contrast, Reduce Transparency, Reduce Motion).

## Suggested first slice

Stage 1 items 1–3 plus the dictation-strip and tab-title fixes already made: terminal padding, transparent full-size title bar with the tab strip in it, and the unfocused state. It changes the whole feel with modest risk. Tests that assert exact cell geometry (`cellRectAtRow`, header and status heights) will need updating.

## Sources

- Apple, [Build an AppKit app with the new design (WWDC25)](https://developer.apple.com/videos/play/wwdc2025/310/)
- Apple, [Toolbars – Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/toolbars)
- Apple, [Tab bars – Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/tab-bars)
- Apple Newsroom, [A delightful and elegant new software design](https://www.apple.com/newsroom/2025/06/apple-introduces-a-delightful-and-elegant-new-software-design/)
- Ghostty, [Configuration reference](https://ghostty.org/docs/config/reference) (titlebar styles, padding, opacity and blur, unfocused state)
- Reviews comparing [Ghostty, Warp and iTerm2](https://www.devtoolreviews.com/reviews/ghostty-vs-warp-vs-iterm2-2026) for what modern terminals prioritize
