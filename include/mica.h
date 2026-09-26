#ifndef MICA_H
#define MICA_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include <vterm.h>

#define MICA_HISTORY_LIMIT_BYTES (2u * 1024u * 1024u)

typedef struct MicaSession MicaSession;

typedef struct {
    uint32_t chars[VTERM_MAX_CHARS_PER_CELL];
    VTermColor fg;
    VTermColor bg;
    VTermScreenCellAttrs attrs;
    char width;
} MicaCell;

MicaSession *mica_session_create(const char *cwd, const char *command, int rows, int cols);
MicaSession *mica_session_create_prefilled(const char *cwd, const char *command, int rows, int cols);
void mica_session_destroy(MicaSession *session);
int mica_session_poll(MicaSession *session, int timeout_ms);
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
uint64_t mica_session_attention_count(const MicaSession *session);
pid_t mica_session_pid(const MicaSession *session);
const char *mica_session_command(const MicaSession *session);
const char *mica_session_title(const MicaSession *session);

#endif
