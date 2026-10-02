#ifndef MICA_H
#define MICA_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include <vterm.h>

#define MICA_VERSION "0.1.0-alpha.12"
#define MICA_REVISION "0.1.0-alpha.12"
#define MICA_HISTORY_LIMIT_BYTES (2u * 1024u * 1024u)

typedef struct MicaSession MicaSession;

typedef struct {
    uint32_t chars[VTERM_MAX_CHARS_PER_CELL];
    VTermColor fg;
    VTermColor bg;
    VTermScreenCellAttrs attrs;
    char width;
    uint32_t hyperlink_id;
} MicaCell;

typedef struct {
    int start_row;
    int end_row;
} MicaDirtyRows;

typedef struct {
    size_t bytes_read;
    size_t read_calls;
    size_t largest_read;
    double parse_milliseconds;
} MicaSessionOutputMetrics;

typedef void (*MicaSessionCleanupLogger)(pid_t pid, const char *stage,
                                         bool started, double elapsed_ms);

MicaSession *mica_session_create(const char *cwd, const char *command, int rows, int cols);
MicaSession *mica_session_create_prefilled(const char *cwd, const char *command, int rows, int cols);
void mica_session_destroy(MicaSession *session);
int mica_session_poll(MicaSession *session, int timeout_ms);
// Master PTY descriptor, owned by the session. Returns -1 after EOF/close.
int mica_session_fd(const MicaSession *session);
bool mica_session_take_output_metrics(MicaSession *session, MicaSessionOutputMetrics *metrics);
void mica_session_set_cleanup_logger(MicaSessionCleanupLogger logger);
void mica_session_write(MicaSession *session, const void *bytes, size_t length);
#ifdef MICA_SESSION_TESTING
void mica_session_test_feed_output(MicaSession *session, const char *bytes, size_t length);
#endif
void mica_session_key(MicaSession *session, VTermKey key, VTermModifier modifiers);
void mica_session_text(MicaSession *session, uint32_t codepoint, VTermModifier modifiers);
void mica_session_paste(MicaSession *session, const char *utf8, size_t length);
void mica_session_mouse(MicaSession *session, int row, int col, int button, bool pressed);
void mica_session_wheel(MicaSession *session, int row, int col, int direction);
void mica_session_focus(MicaSession *session, bool focused);
// Returns false if the session rejected the resize (for example, if its bounded history index could not grow).
bool mica_session_resize(MicaSession *session, int rows, int cols);
bool mica_session_resize_pixels(MicaSession *session, int rows, int cols, int pixel_width, int pixel_height);
void mica_session_scroll(MicaSession *session, int lines);
void mica_session_scroll_to_bottom(MicaSession *session);
// Drops all scrolled-off history (Cmd+K); the visible screen is left alone.
void mica_session_clear_scrollback(MicaSession *session);
// Switches the ANSI palette and default colours between the dark (default) and light themes.
void mica_session_set_light_theme(MicaSession *session, bool light);
// UTF-8 search across history and the screen, with ASCII case folding. Combining codepoints
// are retained; canonically equivalent Unicode spellings are not normalized. `cursor` holds the last match's absolute row
// (start with -1) and is updated; the view scrolls to the match. Returns false if nothing matches.
bool mica_session_find(MicaSession *session, const char *query, bool backward, long *cursor);
int mica_session_rows(const MicaSession *session);
int mica_session_cols(const MicaSession *session);
int mica_session_view_offset(const MicaSession *session);
size_t mica_session_history_lines(const MicaSession *session);
// Bytes currently held by this session's compacted scrollback cells, hyperlink rows and row index.
size_t mica_session_history_storage_bytes(const MicaSession *session);
// Scrollback allowance for all sessions, in lines at 80 columns (clamped to 100...100000). Default is
// MICA_HISTORY_LIMIT_BYTES worth (about 650 lines). Memory is allocated only as output arrives.
void mica_set_history_limit_lines(size_t lines_at_80_columns);
size_t mica_history_limit_bytes(void);
// Monotonic count of lines that have scrolled off the top; keeps counting once scrollback is full.
// True when the foreground program enabled bracketed paste (mode 2004), which makes pasted newlines safe.
bool mica_session_bracketed_paste(const MicaSession *session);
// True while a full-screen program (lazygit, vim, yazi, htop) is on the alternate screen.
bool mica_session_alt_screen(const MicaSession *session);
// True while a program has an unfinished synchronized-output frame (mode 2026); redraw should wait.
bool mica_session_sync_output_active(const MicaSession *session);
// Words a program sent with OSC 9, 99 or 777 (an agent asking for attention), or NULL. The caller frees it.
char *mica_session_take_notification(MicaSession *session);
// Text a program set through OSC 52, or NULL. The caller frees it.
char *mica_session_take_clipboard_write(MicaSession *session);
uint64_t mica_session_scrolled_lines(const MicaSession *session);
size_t mica_session_display_history_lines(const MicaSession *session);
bool mica_session_fold_visible_rows(MicaSession *session, int start_row, int end_row);
bool mica_session_toggle_fold_at_view_row(MicaSession *session, int row);
bool mica_session_fold_info_at_view_row(const MicaSession *session, int row, size_t *hidden_rows);
bool mica_session_get_cell(const MicaSession *session, int row, int col, MicaCell *cell);
// Whether this displayed row is a soft-wrap continuation of the preceding row.
bool mica_session_row_continues(const MicaSession *session, int row);
const char *mica_session_hyperlink_uri(const MicaSession *session, uint32_t hyperlink_id);
bool mica_session_is_running(const MicaSession *session);
const char *mica_session_hook_token(const MicaSession *session);
int mica_session_exit_status(const MicaSession *session);
uint64_t mica_session_command_completion_count(const MicaSession *session);
int mica_session_command_exit_status(const MicaSession *session);
int mica_session_osc133_state(const MicaSession *session);
uint64_t mica_session_osc133_count(const MicaSession *session);
// OSC 133 row annotations are bit flags; rows may carry more than one phase.
#define MICA_LANDMARK_PROMPT 1u
#define MICA_LANDMARK_PROMPT_END 2u
#define MICA_LANDMARK_COMMAND 4u
#define MICA_LANDMARK_FINISHED 8u
uint8_t mica_session_row_landmark(const MicaSession *session, int row, int *status);
bool mica_session_jump_prompt(MicaSession *session, int direction);
bool mica_session_reports_mouse(const MicaSession *session);
bool mica_session_reports_focus(const MicaSession *session);
bool mica_session_cursor_visible(const MicaSession *session);
void mica_session_cursor(const MicaSession *session, int *row, int *col);
uint64_t mica_session_revision(const MicaSession *session);
bool mica_session_take_dirty_rows(MicaSession *session, MicaDirtyRows *rows);
uint64_t mica_session_attention_count(const MicaSession *session);
pid_t mica_session_pid(const MicaSession *session);
bool mica_session_working_directory(const MicaSession *session, char *buffer, size_t capacity);
const char *mica_session_command(const MicaSession *session);
const char *mica_session_title(const MicaSession *session);
const char *mica_session_current_command(const MicaSession *session);

#endif
