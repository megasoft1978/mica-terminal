# Local changes to libvterm 0.3.3

Upstream source: https://launchpad.net/libvterm/trunk/v0.3/+download/libvterm-0.3.3.tar.gz
(sha256 `09156f43dd2128bd347cbeebe50d9a571d32c64e0cf18d211197946aff7226e0`). License: MIT (see `LICENSE`).

The safety fixes were found by `make fuzz` under AddressSanitizer. The continuation callback extensions have direct unit regressions. Changes are marked `Mica patch` in the source.

| File | Problem | Fix |
| --- | --- | --- |
| `src/screen.c` `resize_buffer` | When the top screen row is a continuation of a wrapped line already in scrollback, the reflow loop walked to row -1 and read before the start of the buffer (heap overflow on resize). | Stop the walk at row 0. |
| `src/screen.c` `resize_buffer` | If the cursor could not be placed after a resize, the library called `abort()`, killing the host application. | Clamp the cursor into the new grid instead. |
| `src/screen.c` `putglyph` | A wide glyph ending past the last column dereferenced a NULL cell. | Skip cells that do not exist. |
| `src/state.c` `savecursor` (DECRC) | A cursor saved before the window was resized could be restored outside the new grid, and the next write read past the line-info array. | Clamp the restored cursor to the current grid. |
| `src/state.c` `set_col_tabstop`, `clear_col_tabstop` | HTS/TBC with a cursor column outside the current width (reachable after resizes) indexed past the tab stop array (heap overflow found by the fuzzer). | Ignore out-of-range columns. |
| `src/encoding.c` `decode_utf8` | An incomplete multibyte sequence followed by ASCII could emit a replacement character and the ASCII character when only one codepoint slot remained (heap overflow found by the fuzzer). | Emit the replacement and leave the ASCII byte for the next decoder call when the buffer fills. Covered by the fixed UTF-8 boundary fuzz case. |
| `include/vterm.h`, `src/vterm_internal.h`, `src/state.c`, `src/screen.c` | Scrollback callbacks run after line metadata moves and omit soft-wrap continuation. | Backport the opt-in upstream `premove` and `sb_pushline4` callbacks from [Neovim libvterm commit 934bc2f](https://github.com/neovim/libvterm/tree/934bc2fbf21800ac3458a499df8820ca5fb45fd3), preserving legacy callback fallback. Direct unit tests cover flags and cells, opt-in/fallback behavior, three damage modes, resize capture, alternate screen and partial scroll regions. |
| `include/vterm.h`, `src/screen.c` | Taller-window resize restores history cells without their continuation flag. | Add an opt-in `sb_popline4` callback that restores the flag on the destination line. Legacy pop callbacks remain supported. Direct tests shrink and grow the grid with legacy fallback, extended callback precedence and an extended-only callback; the PTY suite checks wrapped history restored to the live screen. |
| `include/vterm.h`, `src/screen.c` | The pop callback reports cells and continuation but not which destination row receives them, so sidecar metadata cannot follow rows that resize pushes and immediately pops. | Add opt-in `sb_popline5` with a destination-row argument while preserving the existing `sb_popline4` signature and opt-in behavior. Direct resize tests check the row order and legacy fallback; the session layer uses it to restore OSC 8 sidecars alongside popped cells. |
| `src/screen.c` `resize_buffer` | A wrapped group too tall for the remaining new grid left `old_row` at its first row, pushing only that row and losing the rest. | Push the entire group before backfilling the live grid. Direct shrink/grow tests compare every character and continuation flag; native Command-click regressions cover a URL across the history/live boundary. |

Known open problem: a fuzz run that feeds random bytes and resizes very often can still find further out-of-range cursor states in upstream code. `make fuzz` is the way to look for them.
