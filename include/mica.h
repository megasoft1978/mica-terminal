#ifndef MICA_H
#define MICA_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include <vterm.h>

#define MICA_VERSION "0.0.1"
#define MICA_REVISION "23"
#define MICA_HISTORY_LIMIT_BYTES (2u * 1024u * 1024u)

typedef struct MicaSession MicaSession;

typedef struct {
    uint32_t chars[VTERM_MAX_CHARS_PER_CELL];
    VTermColor fg;
    VTermColor bg;
    VTermScreenCellAttrs attrs;
    char width;
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
bool mica_session_take_output_metrics(MicaSession *session, MicaSessionOutputMetrics *metrics);
void mica_session_set_cleanup_logger(MicaSessionCleanupLogger logger);
void mica_session_write(MicaSession *session, const void *bytes, size_t length);
void mica_session_key(MicaSession *session, VTermKey key, VTermModifier modifiers);
void mica_session_text(MicaSession *session, uint32_t codepoint, VTermModifier modifiers);
void mica_session_paste(MicaSession *session, const char *utf8, size_t length);
void mica_session_mouse(MicaSession *session, int row, int col, int button, bool pressed);
void mica_session_wheel(MicaSession *session, int row, int col, int direction);
void mica_session_focus(MicaSession *session, bool focused);
void mica_session_resize(MicaSession *session, int rows, int cols);
void mica_session_resize_pixels(MicaSession *session, int rows, int cols, int pixel_width, int pixel_height);
void mica_session_scroll(MicaSession *session, int lines);
void mica_session_scroll_to_bottom(MicaSession *session);
int mica_session_rows(const MicaSession *session);
int mica_session_cols(const MicaSession *session);
int mica_session_view_offset(const MicaSession *session);
size_t mica_session_history_lines(const MicaSession *session);
size_t mica_session_display_history_lines(const MicaSession *session);
bool mica_session_fold_visible_rows(MicaSession *session, int start_row, int end_row);
bool mica_session_toggle_fold_at_view_row(MicaSession *session, int row);
bool mica_session_fold_info_at_view_row(const MicaSession *session, int row, size_t *hidden_rows);
bool mica_session_get_cell(const MicaSession *session, int row, int col, MicaCell *cell);
bool mica_session_is_running(const MicaSession *session);
int mica_session_exit_status(const MicaSession *session);
uint64_t mica_session_command_completion_count(const MicaSession *session);
int mica_session_command_exit_status(const MicaSession *session);
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
