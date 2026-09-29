# Local changes to libvterm 0.3.3

Upstream source: https://launchpad.net/libvterm/trunk/v0.3/+download/libvterm-0.3.3.tar.gz
(sha256 `09156f43dd2128bd347cbeebe50d9a571d32c64e0cf18d211197946aff7226e0`). License: MIT (see `LICENSE`).

Each change was found by `make fuzz` under AddressSanitizer and is marked `Mica patch` in the source.

| File | Problem | Fix |
| --- | --- | --- |
| `src/screen.c` `resize_buffer` | When the top screen row is a continuation of a wrapped line already in scrollback, the reflow loop walked to row -1 and read before the start of the buffer (heap overflow on resize). | Stop the walk at row 0. |
| `src/screen.c` `resize_buffer` | If the cursor could not be placed after a resize, the library called `abort()`, killing the host application. | Clamp the cursor into the new grid instead. |
| `src/screen.c` `putglyph` | A wide glyph ending past the last column dereferenced a NULL cell. | Skip cells that do not exist. |
| `src/state.c` `savecursor` (DECRC) | A cursor saved before the window was resized could be restored outside the new grid, and the next write read past the line-info array. | Clamp the restored cursor to the current grid. |

Known open problem: a fuzz run that feeds random bytes and resizes very often can still find further out-of-range cursor states in upstream code. `make fuzz` is the way to look for them.
