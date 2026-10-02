#define _DARWIN_C_SOURCE
#include "mica.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <libproc.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

#define MICA_HISTORY_INITIAL 32
#define MICA_READ_BUFFER 16384
#define MICA_POLL_READ_BUDGET (64 * 1024)
#define MICA_PENDING_INPUT_LIMIT (1024 * 1024)
#define MICA_TITLE_MAX_BYTES 512
#define MICA_FOLD_LIMIT 128
#define MICA_HYPERLINK_MAX_URI_BYTES 2048
#define MICA_HYPERLINK_MAX_TABLE_BYTES (512u * 1024u)
#define MICA_HYPERLINK_MAX_COUNT 512

static const uint32_t mica_ansi_palette[16] = {
    0x1e1e1e, 0xf48771, 0x90c978, 0xf5d67a,
    0x57c7ff, 0xc792ea, 0x89ddff, 0xd4d4d4,
    0x4a4a4a, 0xff5370, 0xc3e88d, 0xffcb6b,
    0x82aaff, 0xc792ea, 0x89ddff, 0xffffff,
};

// Light theme: dark-on-white with ANSI colours darkened for contrast on a white background.
static const uint32_t mica_ansi_palette_light[16] = {
    0x24292f, 0xcf222e, 0x116329, 0x7d4e00,
    0x0550ae, 0x8250df, 0x1b7c83, 0x6e7781,
    0x57606a, 0xa40e26, 0x1a7f37, 0x9a6700,
    0x218bff, 0xa475f9, 0x3192aa, 0x8c959f,
};

typedef struct {
    size_t start;
    size_t end;
} MicaFold;

// Scrollback rows keep only meaningful trailing cells. Cell and hyperlink storage
// grows with content instead of reserving the full terminal width for every line.
typedef struct {
    uint32_t character;
    uint8_t attribute_index;
    char width;
} MicaHistoryScalarCell;

// Keeps the previous compact scalar representation for high-entropy styling.
typedef struct {
    uint32_t character;
    VTermScreenCellAttrs attrs;
    VTermColor fg;
    VTermColor bg;
    char width;
} MicaHistoryScalarCellExpanded;

// Attribute palettes are row-local and deliberately small. Highly varied
// rows keep the full-cell representation instead of building a costly table.
#define MICA_HISTORY_ATTRIBUTE_LIMIT 16
typedef struct {
    VTermScreenCellAttrs attrs;
    VTermColor fg;
    VTermColor bg;
} MicaHistoryAttribute;

typedef struct {
    void *cells;
    uint32_t *hyperlinks;
    MicaHistoryAttribute *attributes;
    size_t cols;
    size_t screen_cols;
    size_t cell_capacity;
    size_t hyperlink_capacity;
    size_t attribute_capacity;
    size_t attribute_count;
    bool scalar_cells;
    bool indexed_attributes;
    bool continuation;
    uint8_t landmark;
    int16_t landmark_status;
} MicaHistoryRow;

struct MicaSession {
    int master_fd;
    pid_t child_pid;
    uint32_t terminal_device;
    int rows;
    int cols;
    int pixel_width;
    int pixel_height;
    bool running;
    bool cursor_visible;
    int mouse_mode;
    int exit_status;
    int command_exit_status;
    uint64_t revision;
    MicaDirtyRows dirty_rows;
    bool has_dirty_rows;
    uint64_t attention_count;
double last_attention_at;
int last_attention_kind;
    uint64_t command_completion_count;
    uint64_t osc133_count;
    int osc133_state;
    MicaSessionOutputMetrics output_metrics;
    bool focus_report;
    VTerm *vt;
    VTermScreen *screen;
    VTermState *state;
    MicaHistoryRow *history;
    size_t history_cols;
    size_t history_capacity;
    size_t history_start;
    size_t history_count;
    size_t history_storage_bytes;
uint64_t scrolled_total;
    size_t view_offset;
    MicaFold *folds;
    size_t fold_count;
    size_t fold_capacity;
    char *pending_input;
    size_t pending_input_offset;
    size_t pending_input_length;
    size_t pending_input_capacity;
    char *command;
    char *current_command;
char *clipboard_text;
size_t clipboard_length;
size_t clipboard_capacity;
bool clipboard_overflow;
bool clipboard_ready;
bool sync_output;
bool bracketed_paste;
    bool alt_screen;
char mark_token[33];
char hook_token[33];
char notification_text[256];
bool notification_ready;
char sync_tail[8];
size_t sync_tail_length;
double sync_output_started;
    char *sync_hold;
    size_t sync_hold_length;
    size_t sync_hold_capacity;
    char sync_carry[8];
    size_t sync_carry_length;
    double sync_carry_at;
char selection_buffer[4096];
    char *title;
    char *startup_dir;
    char title_fragments[MICA_TITLE_MAX_BYTES + 1];
    size_t title_fragment_length;
    bool title_fragment_active;
    char osc_fragments[4096];
    size_t osc_fragment_length;
    int osc_fragment_command;
    bool osc_fragment_active;
    bool osc_fragment_overflow;
    uint32_t *screen_link_ids;
    uint8_t *screen_landmarks;
    int16_t *screen_landmark_status;
    // During a libvterm resize, rows are pushed to scrollback synchronously in
    // source-grid order. Snapshot the sidecar first so damage callbacks cannot
    // rewrite the IDs before the corresponding rows are captured.
    const uint32_t *resize_source_link_ids;
    size_t resize_source_link_cols;
    size_t resize_source_link_rows;
    size_t resize_source_link_next_row;
    uint32_t *resize_target_link_ids;
    size_t resize_target_link_cols;
    size_t resize_target_link_rows;
    char **hyperlink_uris;
    size_t hyperlink_count;
    size_t hyperlink_bytes;
    uint32_t active_hyperlink_id;
    bool hyperlink_tracking;
    VTermRect pending_link_move;
    bool pending_link_move_valid;
    size_t pending_link_move_cells;
};

static MicaSessionCleanupLogger cleanup_logger;

static bool ensure_screen_link_map(MicaSession *session) {
    if (!session || session->rows <= 0 || session->cols <= 0) return false;
    size_t cells = (size_t)session->rows * (size_t)session->cols;
    if (!session->screen_link_ids) session->screen_link_ids = calloc(cells, sizeof(*session->screen_link_ids));
    return session->screen_link_ids != NULL;
}

static bool ensure_screen_landmarks(MicaSession *session) {
    if (!session || session->rows <= 0) return false;
    if (!session->screen_landmarks) session->screen_landmarks = calloc((size_t)session->rows, 1);
    if (!session->screen_landmark_status)
        session->screen_landmark_status = calloc((size_t)session->rows, sizeof(*session->screen_landmark_status));
    return session->screen_landmarks && session->screen_landmark_status;
}

static void record_osc133_mark(MicaSession *session, uint8_t mark, int status) {
    if (!session || !session->screen) return;
    VTermPos pos = {0};
    vterm_state_get_cursorpos(session->state, &pos);
    if (pos.row < 0 || pos.row >= session->rows) return;
    if (ensure_screen_landmarks(session)) {
        uint8_t flag = mark == 'A' ? MICA_LANDMARK_PROMPT : mark == 'B' ? MICA_LANDMARK_PROMPT_END :
            mark == 'C' ? MICA_LANDMARK_COMMAND : MICA_LANDMARK_FINISHED;
        session->screen_landmarks[pos.row] |= flag;
        if (mark == 'D') session->screen_landmark_status[pos.row] = (int16_t)status;
    }
}

static void history_row_release(MicaSession *session, MicaHistoryRow *row) {
    if (!session || !row) return;
    session->history_storage_bytes -= row->cell_capacity +
        row->hyperlink_capacity * sizeof(*row->hyperlinks) +
        row->attribute_capacity * sizeof(*row->attributes);
    free(row->cells);
    free(row->hyperlinks);
    free(row->attributes);
    memset(row, 0, sizeof(*row));
}

// Cell capacity is measured in bytes, because rows can use either representation.
static bool history_row_resize_cells(MicaSession *session, MicaHistoryRow *row, size_t cols, bool scalar, bool indexed) {
    size_t cell_size = scalar ? (indexed ? sizeof(MicaHistoryScalarCell) : sizeof(MicaHistoryScalarCellExpanded)) : sizeof(VTermScreenCell);
    if (cols > SIZE_MAX / cell_size) return false;
    size_t bytes = cols * cell_size;
    if (bytes == 0) {
        free(row->cells);
        session->history_storage_bytes -= row->cell_capacity;
        row->cells = NULL;
        row->cell_capacity = 0;
        row->scalar_cells = scalar;
        row->indexed_attributes = indexed;
        return true;
    }
    // Shrink when a full Unicode row becomes scalar, even at the usual
    // half-capacity reuse boundary; otherwise a Unicode burst keeps its cost.
    bool shrink_representation = scalar && !row->scalar_cells && bytes < row->cell_capacity;
    if (!shrink_representation && row->cell_capacity >= bytes && bytes >= row->cell_capacity / 2) {
        row->scalar_cells = scalar;
        row->indexed_attributes = indexed;
        return true;
    }
    size_t old_bytes = row->cell_capacity;
    void *cells = realloc(row->cells, bytes);
    if (!cells) {
        if (row->cell_capacity < bytes) return false;
        row->scalar_cells = scalar;
        row->indexed_attributes = indexed;
        return true;
    }
    row->cells = cells;
    row->cell_capacity = bytes;
    row->scalar_cells = scalar;
    row->indexed_attributes = indexed;
    session->history_storage_bytes = session->history_storage_bytes - old_bytes + bytes;
    return true;
}

static bool history_row_resize_links(MicaSession *session, MicaHistoryRow *row, size_t cols) {
    if (cols > SIZE_MAX / sizeof(*row->hyperlinks)) return false;
    if (cols == 0) {
        free(row->hyperlinks);
        session->history_storage_bytes -= row->hyperlink_capacity * sizeof(*row->hyperlinks);
        row->hyperlinks = NULL;
        row->hyperlink_capacity = 0;
        return true;
    }
    if (row->hyperlink_capacity >= cols && (cols >= row->hyperlink_capacity / 2 || cols == row->hyperlink_capacity)) return true;
    size_t old_bytes = row->hyperlink_capacity * sizeof(*row->hyperlinks);
    uint32_t *links = realloc(row->hyperlinks, cols * sizeof(*links));
    if (!links) return row->hyperlink_capacity >= cols;
    row->hyperlinks = links;
    row->hyperlink_capacity = cols;
    session->history_storage_bytes = session->history_storage_bytes - old_bytes + cols * sizeof(*links);
    return true;
}

static bool history_cell_is_trimmable_blank(const VTermScreenCell *cell) {
    if (!cell || cell->width != 1 || cell->attrs.bold || cell->attrs.underline || cell->attrs.italic ||
        cell->attrs.blink || cell->attrs.reverse || cell->attrs.conceal || cell->attrs.strike ||
        cell->attrs.font || cell->attrs.dwl || cell->attrs.dhl || cell->attrs.small || cell->attrs.baseline ||
        !VTERM_COLOR_IS_DEFAULT_FG(&cell->fg) || !VTERM_COLOR_IS_DEFAULT_BG(&cell->bg)) return false;
    if (cell->chars[0] != 0 && cell->chars[0] != ' ') return false;
    for (size_t i = 1; i < VTERM_MAX_CHARS_PER_CELL; i++)
        if (cell->chars[i] != 0) return false;
    return true;
}

static size_t history_compact_cols(const VTermScreenCell *cells, const uint32_t *links, size_t cols) {
    while (cols > 0 && (!links || links[cols - 1] == 0) &&
        history_cell_is_trimmable_blank(&cells[cols - 1])) cols--;
    return cols;
}

static VTermScreenCell history_blank_cell(void) {
    VTermScreenCell cell = {0};
    cell.width = 1;
    cell.fg.type = VTERM_COLOR_DEFAULT_FG;
    cell.bg.type = VTERM_COLOR_DEFAULT_BG;
    return cell;
}

static VTermScreenCell history_cell_at(const MicaHistoryRow *row, size_t col) {
    if (col >= row->cols) return history_blank_cell();
    if (!row->scalar_cells) return ((const VTermScreenCell *)row->cells)[col];
    VTermScreenCell cell = {0};
    if (row->indexed_attributes) {
        const MicaHistoryScalarCell *source = &((const MicaHistoryScalarCell *)row->cells)[col];
        cell.chars[0] = source->character;
        if (source->attribute_index < row->attribute_count) {
            const MicaHistoryAttribute *attribute = &row->attributes[source->attribute_index];
            cell.attrs = attribute->attrs;
            cell.fg = attribute->fg;
            cell.bg = attribute->bg;
        } else {
            cell.fg.type = VTERM_COLOR_DEFAULT_FG;
            cell.bg.type = VTERM_COLOR_DEFAULT_BG;
        }
        cell.width = source->width;
    } else {
        const MicaHistoryScalarCellExpanded *source = &((const MicaHistoryScalarCellExpanded *)row->cells)[col];
        cell.chars[0] = source->character;
        cell.attrs = source->attrs;
        cell.fg = source->fg;
        cell.bg = source->bg;
        cell.width = source->width;
    }
    return cell;
}

static bool history_cells_are_scalar(const VTermScreenCell *cells, size_t cols) {
    for (size_t col = 0; col < cols; col++)
        for (size_t index = 1; index < VTERM_MAX_CHARS_PER_CELL; index++)
            if (cells[col].chars[index]) return false;
    return true;
}

static bool history_attrs_equal(VTermScreenCellAttrs a, VTermScreenCellAttrs b) {
    return a.bold == b.bold && a.underline == b.underline && a.italic == b.italic &&
        a.blink == b.blink && a.reverse == b.reverse && a.conceal == b.conceal &&
        a.strike == b.strike && a.font == b.font && a.dwl == b.dwl && a.dhl == b.dhl &&
        a.small == b.small && a.baseline == b.baseline;
}

static void history_row_clear_attributes(MicaSession *session, MicaHistoryRow *row) {
    free(row->attributes);
    session->history_storage_bytes -= row->attribute_capacity * sizeof(*row->attributes);
    row->attributes = NULL;
    row->attribute_capacity = 0;
    row->attribute_count = 0;
}

static bool history_row_store_cells(MicaSession *session, MicaHistoryRow *row, const VTermScreenCell *cells) {
    if (!row->scalar_cells) {
        if (row->cols) memcpy(row->cells, cells, row->cols * sizeof(*cells));
        history_row_clear_attributes(session, row);
        return true;
    }
    if (!row->indexed_attributes) {
        MicaHistoryScalarCellExpanded *stored = row->cells;
        for (size_t col = 0; col < row->cols; col++) {
            stored[col] = (MicaHistoryScalarCellExpanded){ cells[col].chars[0], cells[col].attrs, cells[col].fg, cells[col].bg, cells[col].width };
        }
        history_row_clear_attributes(session, row);
        return true;
    }
    MicaHistoryScalarCell *stored = row->cells;
    for (size_t col = 0; col < row->cols; col++) {
        size_t index = 0;
        while (index < row->attribute_count) {
            const MicaHistoryAttribute *attribute = &row->attributes[index];
            if (history_attrs_equal(attribute->attrs, cells[col].attrs) &&
                vterm_color_is_equal(&attribute->fg, &cells[col].fg) &&
                vterm_color_is_equal(&attribute->bg, &cells[col].bg)) break;
            index++;
        }
        if (index == row->attribute_count) {
            if (index >= MICA_HISTORY_ATTRIBUTE_LIMIT) return false;
            if (row->attribute_capacity == index) {
                size_t capacity = row->attribute_capacity ? row->attribute_capacity * 2 : 4;
                if (capacity > MICA_HISTORY_ATTRIBUTE_LIMIT) capacity = MICA_HISTORY_ATTRIBUTE_LIMIT;
                size_t old_bytes = row->attribute_capacity * sizeof(*row->attributes);
                MicaHistoryAttribute *attributes = realloc(row->attributes, capacity * sizeof(*attributes));
                if (!attributes) return false;
                row->attributes = attributes;
                row->attribute_capacity = capacity;
                session->history_storage_bytes = session->history_storage_bytes - old_bytes + capacity * sizeof(*attributes);
            }
            row->attributes[index] = (MicaHistoryAttribute){ cells[col].attrs, cells[col].fg, cells[col].bg };
            row->attribute_count++;
        }
        stored[col].character = cells[col].chars[0];
        stored[col].attribute_index = (uint8_t)index;
        stored[col].width = cells[col].width;
    }
    // Return unused palette capacity to the bounded history pool.
    if (row->attribute_capacity > row->attribute_count) {
        size_t capacity = row->attribute_count;
        size_t old_bytes = row->attribute_capacity * sizeof(*row->attributes);
        if (!capacity) history_row_clear_attributes(session, row);
        else {
            MicaHistoryAttribute *attributes = realloc(row->attributes, capacity * sizeof(*attributes));
            if (attributes) {
                row->attributes = attributes;
                row->attribute_capacity = capacity;
                session->history_storage_bytes = session->history_storage_bytes - old_bytes + capacity * sizeof(*attributes);
            }
        }
    }
    return true;
}

static uint32_t intern_hyperlink(MicaSession *session, const char *uri, size_t length) {
    if (!session || !uri || length == 0 || length > MICA_HYPERLINK_MAX_URI_BYTES ||
        length > MICA_HYPERLINK_MAX_TABLE_BYTES - session->hyperlink_bytes ||
        session->hyperlink_count >= MICA_HYPERLINK_MAX_COUNT) return 0;
    for (size_t i = 0; i < length; i++) {
        unsigned char byte = (unsigned char)uri[i];
        if (byte < 0x20 || byte == 0x7f) return 0;
    }
    for (size_t i = 0; i < session->hyperlink_count; i++) {
        if (strlen(session->hyperlink_uris[i]) == length &&
            memcmp(session->hyperlink_uris[i], uri, length) == 0) return (uint32_t)i + 1;
    }
    char *copy = malloc(length + 1);
    if (!copy) return 0;
    memcpy(copy, uri, length);
    copy[length] = '\0';
    char **grown = realloc(session->hyperlink_uris,
        (session->hyperlink_count + 1) * sizeof(*grown));
    if (!grown) { free(copy); return 0; }
    session->hyperlink_uris = grown;
    session->hyperlink_uris[session->hyperlink_count++] = copy;
    session->hyperlink_bytes += length;
    return (uint32_t)session->hyperlink_count;
}

static int move_link_rect(VTermRect dest, VTermRect src, void *user) {
    MicaSession *session = user;
    if (!session || !session->screen_link_ids) return 1;
    int height = dest.end_row - dest.start_row;
    int width = dest.end_col - dest.start_col;
    if (height <= 0 || width <= 0 || height != src.end_row - src.start_row ||
        width != src.end_col - src.start_col) return 1;
    int start = dest.start_row > src.start_row ? height - 1 : 0;
    int end = dest.start_row > src.start_row ? -1 : height;
    int step = dest.start_row > src.start_row ? -1 : 1;
    for (int offset = start; offset != end; offset += step) {
        uint32_t *to = session->screen_link_ids + (size_t)(dest.start_row + offset) * session->cols + dest.start_col;
        uint32_t *from = session->screen_link_ids + (size_t)(src.start_row + offset) * session->cols + src.start_col;
        memmove(to, from, (size_t)width * sizeof(*to));
    }
    session->pending_link_move = dest;
    session->pending_link_move_valid = true;
    session->pending_link_move_cells = (size_t)width * (size_t)height;
    return 1;
}

static double monotonic_milliseconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec * 1000.0 + now.tv_nsec / 1000000.0;
}

static double cleanup_stage_begin(pid_t pid, const char *stage) {
    if (cleanup_logger) cleanup_logger(pid, stage, true, 0);
    return monotonic_milliseconds();
}

static void cleanup_stage_end(pid_t pid, const char *stage, double started_at) {
    if (cleanup_logger)
        cleanup_logger(pid, stage, false, monotonic_milliseconds() - started_at);
}

void mica_session_set_cleanup_logger(MicaSessionCleanupLogger logger) {
    cleanup_logger = logger;
}

static void remove_fold_at(MicaSession *session, size_t index) {
    if (!session || index >= session->fold_count) return;
    if (index + 1 < session->fold_count)
        memmove(&session->folds[index], &session->folds[index + 1],
                (session->fold_count - index - 1) * sizeof(*session->folds));
    session->fold_count--;
}

static void clear_folds(MicaSession *session) {
    if (!session) return;
    free(session->folds);
    session->folds = NULL;
    session->fold_count = 0;
    session->fold_capacity = 0;
}

static size_t folded_hidden_lines(const MicaSession *session) {
    size_t hidden = 0;
    if (!session) return 0;
    for (size_t i = 0; i < session->fold_count; i++)
        hidden += session->folds[i].end - session->folds[i].start - 1;
    return hidden;
}

static size_t display_history_count(const MicaSession *session) {
    if (!session) return 0;
    size_t hidden = folded_hidden_lines(session);
    return hidden > session->history_count ? 0 : session->history_count - hidden;
}

static size_t history_index_for_display_row(const MicaSession *session, size_t display_row,
                                             bool *is_fold_placeholder) {
    size_t hidden_before = 0;
    if (is_fold_placeholder) *is_fold_placeholder = false;
    for (size_t i = 0; session && i < session->fold_count; i++) {
        MicaFold fold = session->folds[i];
        size_t visible_start = fold.start - hidden_before;
        if (display_row < visible_start) break;
        if (display_row == visible_start) {
            if (is_fold_placeholder) *is_fold_placeholder = true;
            return fold.start;
        }
        hidden_before += fold.end - fold.start - 1;
    }
    return display_row + hidden_before;
}

static void adjust_folds_after_history_drop_oldest(MicaSession *session) {
    if (!session) return;
    for (size_t i = 0; i < session->fold_count;) {
        MicaFold *fold = &session->folds[i];
        fold->start = fold->start > 0 ? fold->start - 1 : 0;
        fold->end--;
        if (fold->end <= fold->start + 1) remove_fold_at(session, i);
        else i++;
    }
}

static void adjust_folds_after_history_pop(MicaSession *session) {
    if (!session) return;
    for (size_t i = 0; i < session->fold_count;) {
        MicaFold *fold = &session->folds[i];
        if (fold->start >= session->history_count) {
            remove_fold_at(session, i);
            continue;
        }
        if (fold->end > session->history_count) fold->end = session->history_count;
        if (fold->end <= fold->start + 1) remove_fold_at(session, i);
        else i++;
    }
}

static void configure_terminal_colors(MicaSession *session, bool light) {
    for (int index = 0; index < 16; index++) {
        uint32_t rgb = light ? mica_ansi_palette_light[index] : mica_ansi_palette[index];
        VTermColor color;
        vterm_color_rgb(&color, (uint8_t)(rgb >> 16), (uint8_t)(rgb >> 8), (uint8_t)rgb);
        vterm_state_set_palette_color(session->state, index, &color);
    }
    VTermColor foreground, background;
    if (light) { vterm_color_rgb(&foreground, 0x24, 0x29, 0x2f); vterm_color_rgb(&background, 0xff, 0xff, 0xff); }
    else { vterm_color_rgb(&foreground, 0xd4, 0xd4, 0xd4); vterm_color_rgb(&background, 0x1e, 0x1e, 0x1e); }
    vterm_state_set_default_colors(session->state, &foreground, &background);
}

static uint8_t xterm_cube_component(unsigned value) {
    return value == 0 ? 0 : (uint8_t)(55 + 40 * value);
}

static void convert_screen_color(const MicaSession *session, VTermColor *color) {
    if (VTERM_COLOR_IS_INDEXED(color) && color->indexed.idx >= 16) {
        unsigned index = color->indexed.idx;
        if (index < 232) {
            unsigned cube = index - 16;
            vterm_color_rgb(color,
                xterm_cube_component(cube / 36),
                xterm_cube_component((cube / 6) % 6),
                xterm_cube_component(cube % 6));
        } else {
            uint8_t gray = (uint8_t)(8 + 10 * (index - 232));
            vterm_color_rgb(color, gray, gray, gray);
        }
        return;
    }
    // The AppKit renderer consumes RGB only. Resolve the ANSI 0–15 palette
    // too, otherwise basic SGR colors appear as the default foreground.
    vterm_screen_convert_color_to_rgb(session->screen, color);
}

static int history_push(int cols, const VTermScreenCell *cells, void *user);
static int history_pop(int cols, VTermScreenCell *cells, void *user);
static int history_clear(void *user);

static char *copy_title(VTermStringFragment fragment) {
    if (!fragment.str || fragment.len == 0) return strdup("");
    size_t length = fragment.len;
    if (length > MICA_TITLE_MAX_BYTES) {
        length = MICA_TITLE_MAX_BYTES;
        while (length > 0 && (((unsigned char)fragment.str[length] & 0xc0) == 0x80)) length--;
    }
    char *title = malloc(length + 1);
    if (!title) return NULL;
    size_t copied = 0;
    for (size_t i = 0; i < length; i++) {
        unsigned char byte = (unsigned char)fragment.str[i];
        if (byte < 0x20 || byte == 0x7f) continue;
        // Drop bidi/format controls that can disguise text (U+200B-200F, U+202A-202E, U+2066-2069, C1).
        if (byte == 0xC2 && i + 1 < length && (unsigned char)fragment.str[i + 1] >= 0x80 && (unsigned char)fragment.str[i + 1] <= 0x9F) { i++; continue; }
        if (byte == 0xE2 && i + 2 < length) {
            unsigned char b1 = (unsigned char)fragment.str[i + 1], b2 = (unsigned char)fragment.str[i + 2];
            if ((b1 == 0x80 && ((b2 >= 0x8B && b2 <= 0x8F) || (b2 >= 0xAA && b2 <= 0xAE))) || (b1 == 0x81 && b2 >= 0xA6 && b2 <= 0xA9)) { i += 2; continue; }
        }
        title[copied++] = (char)byte;
    }
    title[copied] = '\0';
    return title;
}

static size_t gHistoryLimitBytes = MICA_HISTORY_LIMIT_BYTES;

// The scrollback allowance is expressed as lines at 80 columns (a line costs columns x sizeof(cell)); memory is only
// allocated as output arrives, so a larger allowance does not raise idle memory.
void mica_set_history_limit_lines(size_t lines_at_80_columns) {
    if (lines_at_80_columns < 100) lines_at_80_columns = 100;
    if (lines_at_80_columns > 100000) lines_at_80_columns = 100000;
    gHistoryLimitBytes = lines_at_80_columns * 80u * sizeof(VTermScreenCell);
}

size_t mica_history_limit_bytes(void) { return gHistoryLimitBytes; }

static size_t history_limit_lines(int cols) {
    if (cols <= 0 || (size_t)cols > (SIZE_MAX - sizeof(MicaHistoryRow)) / sizeof(VTermScreenCell)) return 0;
    size_t bytes_per_line = (size_t)cols * sizeof(VTermScreenCell) + sizeof(MicaHistoryRow);
    return gHistoryLimitBytes / bytes_per_line;
}

static bool write_startup_file(const char *directory, const char *name, const char *contents) {
    char path[1024];
    int length = snprintf(path, sizeof(path), "%s/%s", directory, name);
    if (length < 0 || (size_t)length >= sizeof(path)) return false;
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd < 0) return false;
    size_t remaining = strlen(contents);
    const char *cursor = contents;
    while (remaining > 0) {
        ssize_t written = write(fd, cursor, remaining);
        if (written > 0) {
            cursor += written;
            remaining -= (size_t)written;
        } else if (written < 0 && errno == EINTR) {
            continue;
        } else {
            close(fd);
            return false;
        }
    }
    return close(fd) == 0;
}

static void sweep_stale_zsh_startup_dirs(void) {
    DIR *temporary_directory = opendir("/tmp");
    if (!temporary_directory) return;
    time_t now = time(NULL);
    struct dirent *entry;
    while ((entry = readdir(temporary_directory)) != NULL) {
        if (strncmp(entry->d_name, "mica-zsh-", 9) != 0) continue;
        char directory[PATH_MAX];
        int length = snprintf(directory, sizeof(directory), "/tmp/%s", entry->d_name);
        if (length < 0 || (size_t)length >= sizeof(directory)) continue;
        struct stat info;
        if (lstat(directory, &info) != 0 || !S_ISDIR(info.st_mode) ||
            now < info.st_mtime || now - info.st_mtime <= 24 * 60 * 60) continue;
        const char *names[] = { ".zshenv", ".zprofile", ".zshrc", ".zlogin" };
        char path[PATH_MAX];
        for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
            length = snprintf(path, sizeof(path), "%s/%s", directory, names[i]);
            if (length > 0 && (size_t)length < sizeof(path)) unlink(path);
        }
        (void)rmdir(directory);
    }
    closedir(temporary_directory);
}

static char *create_prefill_startup_dir(void) {
    sweep_stale_zsh_startup_dirs();
    char template[] = "/tmp/mica-zsh-XXXXXX";
    char *directory = mkdtemp(template);
    if (!directory) return NULL;
    static const char startup[] =
        "if [[ \"$MICA_TEST_NO_STARTUP\" != 1 ]]; then\n"
        "original=\"$MICA_ORIGINAL_ZDOTDIR\"\n"
        "export ZDOTDIR=\"$original\"\n"
        "[[ -r \"$original/.zshenv\" ]] && source \"$original/.zshenv\"\n"
        "export MICA_ORIGINAL_ZDOTDIR=\"${ZDOTDIR:-$original}\"\n"
        "export ZDOTDIR=\"$MICA_ZSH_WRAPPER\"\n"
        "fi\n";
    static const char profile[] =
        "if [[ \"$MICA_TEST_NO_STARTUP\" != 1 ]]; then\n"
        "original=\"$MICA_ORIGINAL_ZDOTDIR\"\n"
        "export ZDOTDIR=\"$original\"\n"
        "[[ -r \"$original/.zprofile\" ]] && source \"$original/.zprofile\"\n"
        "export MICA_ORIGINAL_ZDOTDIR=\"${ZDOTDIR:-$original}\"\n"
        "export ZDOTDIR=\"$MICA_ZSH_WRAPPER\"\n"
        "fi\n";
    static const char interactive[] =
        "if [[ \"$MICA_TEST_NO_STARTUP\" == 1 ]]; then\n"
        "    if [[ -n $MICA_INITIAL_COMMAND ]]; then\n"
        "        print -z -- \"$MICA_INITIAL_COMMAND\"\n"
        "        unset MICA_INITIAL_COMMAND\n"
        "    fi\n"
        "else\n"
        "original=\"$MICA_ORIGINAL_ZDOTDIR\"\n"
        "export ZDOTDIR=\"$original\"\n"
        "[[ -r \"$original/.zshrc\" ]] && source \"$original/.zshrc\"\n"
        "export MICA_ORIGINAL_ZDOTDIR=\"${ZDOTDIR:-$original}\"\n"
        "export ZDOTDIR=\"$MICA_ZSH_WRAPPER\"\n"
        "if [[ -n $MICA_INITIAL_COMMAND ]]; then\n"
        "    print -z -- \"$MICA_INITIAL_COMMAND\"\n"
        "    unset MICA_INITIAL_COMMAND\n"
        "fi\n"
        "fi\n"
        "function _mica_command_started() {\n"
        "    printf '\\033]133;B\\033\\\\'\n"
        "    local mica_command=\"${1##[[:space:]]#}\"\n"
        "    mica_command=\"${mica_command#unset CLAUDECODE && }\"\n"
        "    mica_command=\"${mica_command##[[:space:]]#}\"\n"
        "    mica_command=\"${mica_command%%[[:space:]]*}\"\n"
        "    [[ -n $mica_command ]] || return\n"
        "    MICA_COMMAND_ACTIVE=1\n"
        "    printf '\\033]133;C\\033\\\\'\n"
        "    printf '\\033]777;mica;%s;command-started;%s\\033\\\\' \"$MICA_MARK_TOKEN\" \"$mica_command\"\n"
        "}\n"
        "function _mica_command_finished() {\n"
        "    local mica_status=$?\n"
        "    [[ $MICA_COMMAND_ACTIVE == 1 ]] || return\n"
        "    unset MICA_COMMAND_ACTIVE\n"
        "    printf '\\033]133;D;%d\\033\\\\' $mica_status\n"
        "    printf '\\033]777;mica;%s;command-finished;%d\\033\\\\' \"$MICA_MARK_TOKEN\" $mica_status\n"
        "}\n"
        "autoload -Uz add-zsh-hook\n"
        "add-zsh-hook preexec _mica_command_started\n"
        "add-zsh-hook precmd _mica_command_finished\n"
        "function _mica_prompt_start() { printf '\\033]133;A\\033\\\\' }\n"
        "add-zsh-hook precmd _mica_prompt_start\n"
        "if [[ -n $MICA_TEST_ZLE_DIR ]]; then\n"
        "    function mica_test_prompt_ready() { : > \"$MICA_TEST_ZLE_DIR/$$.ready\"; }\n"
        "    function mica_test_capture_buffer() { print -r -- \"$BUFFER\" > \"$MICA_TEST_ZLE_DIR/$$.buffer\"; }\n"
        "    function mica_test_raw_transcript() { : > \"$MICA_TEST_ZLE_DIR/$$.executed\"; }\n"
        "    zle -N mica_test_capture_buffer\n"
        "    bindkey '^X^B' mica_test_capture_buffer\n"
        "    autoload -Uz add-zle-hook-widget\n"
        "    add-zle-hook-widget zle-line-init mica_test_prompt_ready\n"
        "fi\n";
    static const char login[] =
        "if [[ \"$MICA_TEST_NO_STARTUP\" != 1 ]]; then\n"
        "original=\"$MICA_ORIGINAL_ZDOTDIR\"\n"
        "export ZDOTDIR=\"$original\"\n"
        "[[ -r \"$original/.zlogin\" ]] && source \"$original/.zlogin\"\n"
        "export MICA_ORIGINAL_ZDOTDIR=\"${ZDOTDIR:-$original}\"\n"
        "export ZDOTDIR=\"$MICA_ZSH_WRAPPER\"\n"
        "fi\n";
    if (!write_startup_file(directory, ".zshenv", startup) ||
        !write_startup_file(directory, ".zprofile", profile) ||
        !write_startup_file(directory, ".zshrc", interactive) ||
        !write_startup_file(directory, ".zlogin", login)) {
        char path[1024];
        const char *names[] = { ".zshenv", ".zprofile", ".zshrc", ".zlogin" };
        for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
            int length = snprintf(path, sizeof(path), "%s/%s", directory, names[i]);
            if (length > 0 && (size_t)length < sizeof(path)) unlink(path);
        }
        rmdir(directory);
        return NULL;
    }
    return strdup(directory);
}

static void remove_prefill_startup_dir(char *directory) {
    if (!directory) return;
    char path[1024];
    const char *names[] = { ".zshenv", ".zprofile", ".zshrc", ".zlogin" };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        int length = snprintf(path, sizeof(path), "%s/%s", directory, names[i]);
        if (length > 0 && (size_t)length < sizeof(path)) unlink(path);
    }
    rmdir(directory);
    free(directory);
}

static int damage_callback(VTermRect rect, void *user) {
    MicaSession *session = user;
    if (session) {
        if (session->screen_link_ids) {
            for (int row = rect.start_row; row < rect.end_row; row++) {
                for (int col = rect.start_col; col < rect.end_col; col++) {
                    if (row < 0 || row >= session->rows || col < 0 || col >= session->cols) continue;
                    size_t index = (size_t)row * session->cols + (size_t)col;
                    if (session->pending_link_move_valid &&
                        vterm_rect_contains(session->pending_link_move, (VTermPos){row, col})) {
                        if (session->pending_link_move_cells > 0 && --session->pending_link_move_cells == 0)
                            session->pending_link_move_valid = false;
                        continue;
                    }
                    VTermScreenCell cell;
                    bool has_glyph = vterm_screen_get_cell(session->screen, (VTermPos){row, col}, &cell) &&
                        cell.chars[0] != 0;
                    session->screen_link_ids[index] = has_glyph ? session->active_hyperlink_id : 0;
                }
            }
        }
        if (rect.start_row < rect.end_row) {
            if (!session->has_dirty_rows) {
                session->dirty_rows.start_row = rect.start_row;
                session->dirty_rows.end_row = rect.end_row;
                session->has_dirty_rows = true;
            } else {
                if (rect.start_row < session->dirty_rows.start_row)
                    session->dirty_rows.start_row = rect.start_row;
                if (rect.end_row > session->dirty_rows.end_row)
                    session->dirty_rows.end_row = rect.end_row;
            }
        }
        session->revision++;
    }
    return 1;
}

static int cursor_callback(VTermPos position, VTermPos old_position, int visible, void *user) {
    (void)visible;
    MicaSession *session = user;
    if (!session) return 1;
    int first = position.row < old_position.row ? position.row : old_position.row;
    int last = position.row > old_position.row ? position.row : old_position.row;
    if (first < 0) first = 0;
    if (last >= session->rows) last = session->rows - 1;
    if (first <= last) {
        if (!session->has_dirty_rows) {
            session->dirty_rows.start_row = first;
            session->dirty_rows.end_row = last + 1;
            session->has_dirty_rows = true;
        } else {
            if (first < session->dirty_rows.start_row) session->dirty_rows.start_row = first;
            if (last + 1 > session->dirty_rows.end_row) session->dirty_rows.end_row = last + 1;
        }
    }
    session->revision++;
    return 1;
}

static int property_callback(VTermProp prop, VTermValue *value, void *user) {
    MicaSession *session = user;
    if (!session || !value) return 1;
    if (prop == VTERM_PROP_CURSORVISIBLE) session->cursor_visible = value->boolean != 0;
    if (prop == VTERM_PROP_MOUSE) session->mouse_mode = value->number;
    if (prop == VTERM_PROP_ALTSCREEN) session->alt_screen = value->boolean != 0;
    if (prop == VTERM_PROP_FOCUSREPORT) session->focus_report = value->boolean != 0;
    if (prop == VTERM_PROP_TITLE) {
        VTermStringFragment fragment = value->string;
        if (fragment.initial || !session->title_fragment_active) {
            session->title_fragment_length = 0;
            session->title_fragment_active = true;
        }
        size_t available = MICA_TITLE_MAX_BYTES + 1 - session->title_fragment_length;
        size_t append = fragment.len < available ? fragment.len : available;
        if (append && fragment.str) {
            memcpy(session->title_fragments + session->title_fragment_length, fragment.str, append);
            session->title_fragment_length += append;
        }
        if (fragment.final) {
            VTermStringFragment complete = {
                .str = session->title_fragments,
                .len = session->title_fragment_length,
                .initial = true,
                .final = true,
            };
            char *title = copy_title(complete);
            session->title_fragment_active = false;
            if (title && (!session->title || strcmp(session->title, title) != 0)) {
                free(session->title);
                session->title = title;
            } else free(title);
        }
    }
    session->revision++;
    return 1;
}

// Output can ring the bell or send notifications in a loop; count at most a couple per second.
static void note_attention(MicaSession *session, int kind) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    double seconds = (double)now.tv_sec + (double)now.tv_nsec / 1e9;
    // Repeats of the same kind within half a second are dropped; different kinds still count.
    if (session->attention_count > 0 && kind == session->last_attention_kind && seconds - session->last_attention_at < 0.5) return;
    session->last_attention_at = seconds;
    session->last_attention_kind = kind;
    session->attention_count++;
}

static int bell_callback(void *user) {
    MicaSession *session = user;
    if (session) note_attention(session, 1);
    return 1;
}

static int notification_osc(int command, VTermStringFragment fragment, void *user) {
    MicaSession *session = user;
    if (!session || (!fragment.str && fragment.len > 0)) return 1;
    if (fragment.initial || !session->osc_fragment_active || command != session->osc_fragment_command) {
        session->osc_fragment_length = 0;
        session->osc_fragment_command = command;
        session->osc_fragment_active = true;
        session->osc_fragment_overflow = false;
    }
    if (fragment.len > sizeof(session->osc_fragments) - session->osc_fragment_length) {
        session->osc_fragment_overflow = true;
    } else if (!session->osc_fragment_overflow && fragment.len > 0) {
        memcpy(session->osc_fragments + session->osc_fragment_length, fragment.str, fragment.len);
        session->osc_fragment_length += fragment.len;
    }
    if (!fragment.final) return 1;
    bool overflow = session->osc_fragment_overflow;
    fragment.str = session->osc_fragments;
    fragment.len = session->osc_fragment_length;
    fragment.initial = true;
    fragment.final = true;
    session->osc_fragment_active = false;
    if (overflow) {
        if (command == 8) {
            vterm_screen_flush_damage(session->screen);
            session->active_hyperlink_id = 0;
        }
        return 1;
    }
    // OSC 133 is advisory shell integration metadata. Ignore unknown parameters
    // and retain the latest recognized phase without interfering with libvterm.
    if (command == 133 && fragment.len > 0) {
        const char *p = fragment.str;
        size_t n = (size_t)fragment.len;
        if ((p[0] == 'A' || p[0] == 'B' || p[0] == 'C' || p[0] == 'D') &&
            (n == 1 || p[1] == ';')) {
            session->osc133_state = p[0];
            session->osc133_count++;
            if (p[0] == 'A') record_osc133_mark(session, 'A', 0);
            else if (p[0] == 'B') record_osc133_mark(session, 'B', 0);
            else if (p[0] == 'C') record_osc133_mark(session, 'C', 0);
            if (p[0] == 'D') {
                const char *semi = memchr(p, ';', n);
                if (semi) {
                    int status = 0;
                    for (const char *q = semi + 1; q < p + n && *q >= '0' && *q <= '9'; q++) {
                        int digit = *q - '0';
                        status = status > (INT_MAX - digit) / 10 ? INT_MAX : status * 10 + digit;
                    }
                    session->command_exit_status = status;
                }
                record_osc133_mark(session, 'D', session->command_exit_status);
            }
            session->revision++;
        }
        return 1;
    }
    if (command == 8) {
        // Flush glyph damage while the previous OSC 8 target is still active.
        // libvterm owns escape parsing; this callback only records its link state.
        vterm_screen_flush_damage(session->screen);
        const char *separator = memchr(fragment.str, ';', (size_t)fragment.len);
        if (!separator || (size_t)(separator - fragment.str + 1) >= (size_t)fragment.len) {
            session->active_hyperlink_id = 0;
            return 1;
        }
        const char *uri = separator + 1;
        size_t uri_length = (size_t)fragment.len - (size_t)(uri - fragment.str);
        if (!uri_length) {
            session->active_hyperlink_id = 0;
            return 1;
        }
        session->hyperlink_tracking = true;
        if (ensure_screen_link_map(session)) {
            // Row-merged damage can combine changed glyphs with unchanged link
            // cells. Switch to exact damage once OSC 8 metadata is in use.
            vterm_screen_set_damage_merge(session->screen, VTERM_DAMAGE_CELL);
            session->active_hyperlink_id = intern_hyperlink(session, uri, uri_length);
        } else {
            session->active_hyperlink_id = 0;
        }
        return 1;
    }
    // Markers carry a per-session secret so output from cat, curl or a remote host cannot forge them.
    char started_prefix[64], completion_prefix[64];
    snprintf(started_prefix, sizeof(started_prefix), "mica;%s;command-started;", session ? session->mark_token : "");
    snprintf(completion_prefix, sizeof(completion_prefix), "mica;%s;command-finished;", session ? session->mark_token : "");
    if (session && command == 777 && fragment.final && fragment.str &&
        fragment.len > (int)strlen(started_prefix) &&
        memcmp(fragment.str, started_prefix, strlen(started_prefix)) == 0) {
        size_t start = strlen(started_prefix);
        size_t length = (size_t)fragment.len - start;
        if (length > 80) length = 80;
        char safe_command[81];
        size_t used = 0;
        for (size_t i = 0; i < length; i++) {
            unsigned char byte = (unsigned char)fragment.str[start + i];
            if ((byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') ||
                (byte >= '0' && byte <= '9') || byte == '_' || byte == '-' ||
                byte == '.' || byte == '/' || byte == '+') safe_command[used++] = (char)byte;
        }
        safe_command[used] = '\0';
        if (used) {
            char *copy = strdup(safe_command);
            if (copy) {
                free(session->current_command);
                session->current_command = copy;
                session->revision++;
            }
        }
        return 1;
    }
    if (session && command == 777 && fragment.final && fragment.str &&
        fragment.len > (int)strlen(completion_prefix) &&
        memcmp(fragment.str, completion_prefix, strlen(completion_prefix)) == 0) {
        int status = 0;
        bool valid = true;
        for (int i = (int)strlen(completion_prefix); i < fragment.len; i++) {
            unsigned char byte = (unsigned char)fragment.str[i];
            if (byte < '0' || byte > '9' || status > 25 || (status == 25 && byte > '5')) {
                valid = false;
                break;
            }
            status = status * 10 + (byte - '0');
        }
        if (valid) {
            session->command_exit_status = status;
            session->command_completion_count++;
            free(session->current_command);
            session->current_command = NULL;
            session->revision++;
        }
        return 1;
    }
    if (session && fragment.final && (command == 9 || command == 99 || command == 777)) {
        bool notification = true;
        if (command == 9 && fragment.str && fragment.len >= 2 &&
            fragment.str[0] == '4' && fragment.str[1] == ';') notification = false;
        if (command == 777 &&
            (!fragment.str || fragment.len < 7 || memcmp(fragment.str, "notify;", 7) != 0)) notification = false;
        if (notification) note_attention(session, command);
        // Keep the words an agent sent (Codex, Claude Code and others use OSC 9/99/777) so the app can show them.
        if (notification && fragment.initial && fragment.final && fragment.str && fragment.len > 0) {
            const char *text = fragment.str;
            size_t length = fragment.len;
            if (command == 777 && length > 7) { text += 7; length -= 7; }               // "notify;" prefix
            else if (command == 99) {                                                    // "metadata;body"
                const char *separator = memchr(text, ';', length);
                if (separator) { length -= (size_t)(separator + 1 - text); text = separator + 1; }
            }
            size_t used = 0;
            bool last_space = false;
            for (size_t i = 0; i < length && used + 1 < sizeof(session->notification_text); i++) {
                unsigned char byte = (unsigned char)text[i];
                if (byte == ';' && command == 777) byte = 0x1f;                        // title;body separator
                if (byte < 0x20 || byte == 0x7f) {
                    if (byte == 0x1f) { if (used) { session->notification_text[used++] = ':'; } last_space = false; byte = ' '; }
                    else byte = ' ';
                }
                if (byte == ' ') { if (last_space || used == 0) continue; last_space = true; } else last_space = false;
                session->notification_text[used++] = (char)byte;
            }
            while (used && session->notification_text[used - 1] == ' ') used--;
            session->notification_text[used] = '\0';
            session->notification_ready = used > 0;
        }
    }
    return 1;
}

static void clear_pending_input(MicaSession *session) {
    free(session->pending_input);
    session->pending_input = NULL;
    session->pending_input_offset = 0;
    session->pending_input_length = 0;
    session->pending_input_capacity = 0;
}

static void flush_pending_input(MicaSession *session) {
    if (!session || session->master_fd < 0) return;
    while (session->pending_input_offset < session->pending_input_length) {
        ssize_t written = write(session->master_fd,
                               session->pending_input + session->pending_input_offset,
                               session->pending_input_length - session->pending_input_offset);
        if (written > 0) {
            session->pending_input_offset += (size_t)written;
            continue;
        }
        if (written < 0 && errno == EINTR) continue;
        if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return;
        clear_pending_input(session);
        return;
    }
    clear_pending_input(session);
}

typedef struct {
    pid_t pid;
    uint64_t start_seconds;
    uint64_t start_microseconds;
} MicaProcessIdentity;

static size_t snapshot_process_tree(pid_t root_pid, MicaProcessIdentity **tree_out) {
    *tree_out = NULL;
    int required_count = proc_listallpids(NULL, 0);
    if (required_count <= 0) return 0;
    size_t capacity = (size_t)required_count + 16;
    pid_t *pids = NULL;
    int returned_count = 0;
    for (;;) {
        if (capacity > (size_t)INT_MAX / sizeof(*pids)) break;
        pid_t *grown = realloc(pids, capacity * sizeof(*pids));
        if (!grown) break;
        pids = grown;
        returned_count = proc_listallpids(pids, (int)(capacity * sizeof(*pids)));
        if (returned_count <= 0 || (size_t)returned_count < capacity) break;
        if (capacity > (size_t)INT_MAX / sizeof(*pids) / 2) break;
        capacity *= 2;
    }
    if (returned_count <= 0 || (size_t)returned_count >= capacity) {
        free(pids);
        return 0;
    }
    size_t pid_count = (size_t)returned_count;
    struct proc_bsdinfo *processes = calloc(pid_count ? pid_count : 1, sizeof(*processes));
    bool *included = calloc(pid_count ? pid_count : 1, sizeof(*included));
    if (!processes || !included) {
        free(processes);
        free(included);
        free(pids);
        return 0;
    }
    ssize_t root_index = -1;
    for (size_t index = 0; index < pid_count; index++) {
        if (pids[index] <= 0) continue;
        if (proc_pidinfo(pids[index], PROC_PIDTBSDINFO, 0,
            &processes[index], sizeof(processes[index])) != sizeof(processes[index])) continue;
        if ((pid_t)processes[index].pbi_pid == root_pid) root_index = (ssize_t)index;
    }
    free(pids);
    if (root_index < 0) {
        free(processes);
        free(included);
        return 0;
    }
    included[root_index] = true;
    size_t tree_count = 1;
    bool changed = true;
    while (changed) {
        changed = false;
        for (size_t index = 0; index < pid_count; index++) {
            if (included[index] || processes[index].pbi_pid == 0) continue;
            for (size_t parent = 0; parent < pid_count; parent++) {
                if (included[parent] && processes[index].pbi_ppid == processes[parent].pbi_pid) {
                    included[index] = true;
                    tree_count++;
                    changed = true;
                    break;
                }
            }
        }
    }
    MicaProcessIdentity *tree = calloc(tree_count, sizeof(*tree));
    if (!tree) {
        free(processes);
        free(included);
        return 0;
    }
    size_t output_index = 0;
    for (size_t index = 0; index < pid_count; index++) {
        if (!included[index]) continue;
        tree[output_index++] = (MicaProcessIdentity){
            .pid = (pid_t)processes[index].pbi_pid,
            .start_seconds = processes[index].pbi_start_tvsec,
            .start_microseconds = processes[index].pbi_start_tvusec,
        };
    }
    free(processes);
    free(included);
    *tree_out = tree;
    return tree_count;
}

static void signal_process_tree(const MicaProcessIdentity *tree, size_t tree_count,
                                int signal_number) {
    for (size_t index = 0; index < tree_count; index++) {
        struct proc_bsdinfo current;
        if (proc_pidinfo(tree[index].pid, PROC_PIDTBSDINFO, 0,
            &current, sizeof(current)) != sizeof(current)) continue;
        if (current.pbi_start_tvsec != tree[index].start_seconds ||
            current.pbi_start_tvusec != tree[index].start_microseconds) continue;
        (void)kill(tree[index].pid, signal_number);
    }
}

static size_t snapshot_terminal_processes(uint32_t terminal_device,
                                         MicaProcessIdentity **processes_out) {
    *processes_out = NULL;
    if (terminal_device == UINT32_MAX) return 0;
    int required_count = proc_listallpids(NULL, 0);
    if (required_count <= 0) return 0;
    size_t capacity = (size_t)required_count + 16;
    pid_t *pids = NULL;
    int returned_count = 0;
    for (;;) {
        if (capacity > (size_t)INT_MAX / sizeof(*pids)) break;
        pid_t *grown = realloc(pids, capacity * sizeof(*pids));
        if (!grown) break;
        pids = grown;
        returned_count = proc_listallpids(pids, (int)(capacity * sizeof(*pids)));
        if (returned_count <= 0 || (size_t)returned_count < capacity) break;
        if (capacity > (size_t)INT_MAX / sizeof(*pids) / 2) break;
        capacity *= 2;
    }
    if (returned_count <= 0 || (size_t)returned_count >= capacity) {
        free(pids);
        return 0;
    }
    size_t pid_count = (size_t)returned_count;
    MicaProcessIdentity *processes = calloc(pid_count, sizeof(*processes));
    if (!processes) { free(pids); return 0; }
    size_t process_count = 0;
    for (size_t index = 0; index < pid_count; index++) {
        if (pids[index] <= 0) continue;
        struct proc_bsdinfo info;
        if (proc_pidinfo(pids[index], PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) ||
            info.e_tdev != terminal_device) continue;
        processes[process_count++] = (MicaProcessIdentity){
            .pid = (pid_t)info.pbi_pid,
            .start_seconds = info.pbi_start_tvsec,
            .start_microseconds = info.pbi_start_tvusec,
        };
    }
    free(pids);
    if (!process_count) {
        free(processes);
        return 0;
    }
    *processes_out = processes;
    return process_count;
}

static uint32_t terminal_device_for_master(int master_fd) {
    char slave_path[PATH_MAX];
    struct stat slave_info;
    if (master_fd < 0 || ioctl(master_fd, TIOCPTYGNAME, slave_path) < 0 ||
        stat(slave_path, &slave_info) < 0) return UINT32_MAX;
    return (uint32_t)slave_info.st_rdev;
}

static bool reserve_pending_input(MicaSession *session, size_t additional) {
    size_t queued = session->pending_input_length - session->pending_input_offset;
    if (additional > MICA_PENDING_INPUT_LIMIT - queued) return false;
    if (session->pending_input_offset > 0 && queued > 0)
        memmove(session->pending_input, session->pending_input + session->pending_input_offset, queued);
    session->pending_input_offset = 0;
    session->pending_input_length = queued;
    size_t needed = queued + additional;
    if (needed <= session->pending_input_capacity) return true;
    size_t capacity = session->pending_input_capacity ? session->pending_input_capacity : 4096;
    while (capacity < needed) {
        if (capacity > MICA_PENDING_INPUT_LIMIT / 2) {
            capacity = MICA_PENDING_INPUT_LIMIT;
            break;
        }
        capacity *= 2;
    }
    char *grown = realloc(session->pending_input, capacity);
    if (!grown) return false;
    session->pending_input = grown;
    session->pending_input_capacity = capacity;
    return true;
}

static void write_nonblocking(MicaSession *session, const char *bytes, size_t length) {
    if (!session || session->master_fd < 0 || !bytes || length == 0) return;

    if (session->pending_input_length == 0) {
        while (length > 0) {
            ssize_t written = write(session->master_fd, bytes, length);
            if (written > 0) {
                bytes += written;
                length -= (size_t)written;
                continue;
            }
            if (written < 0 && errno == EINTR) continue;
            if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
            return;
        }
        if (length == 0) return;
    }

    size_t queued = session->pending_input_length - session->pending_input_offset;
    if (length > SIZE_MAX - queued || !reserve_pending_input(session, length)) return;
    memcpy(session->pending_input + queued, bytes, length);
    session->pending_input_length = queued + length;
}

static void output_callback(const char *bytes, size_t length, void *user) {
    MicaSession *session = user;
    write_nonblocking(session, bytes, length);
}

static int history_push_continued(int cols, const VTermScreenCell *cells, bool continuation, void *user) {
    MicaSession *session = user;
    if (!session || cols <= 0) return 1;
    session->scrolled_total++;
    if (session->history_cols == 0) session->history_cols = (size_t)session->cols;
    size_t limit = history_limit_lines((int)session->history_cols);
    if (session->history_count == session->history_capacity && session->history_capacity < limit) {
        size_t old_capacity = session->history_capacity;
        size_t next_capacity = session->history_capacity ? session->history_capacity * 2 : MICA_HISTORY_INITIAL;
        if (next_capacity > limit) next_capacity = limit;
        MicaHistoryRow *grown = next_capacity <= SIZE_MAX / sizeof(*grown)
            ? calloc(next_capacity, sizeof(*grown)) : NULL;
        if (grown) {
            for (size_t i = 0; i < session->history_count; i++) {
                size_t old_slot = (session->history_start + i) % session->history_capacity;
                grown[i] = session->history[old_slot];
            }
            free(session->history);
            session->history = grown;
            session->history_capacity = next_capacity;
            session->history_start = 0;
            session->history_storage_bytes = session->history_storage_bytes - old_capacity * sizeof(*grown) +
                next_capacity * sizeof(*grown);
        }
    }
    if (session->history_capacity == 0) return 1;
    size_t slot;
    if (session->history_count < session->history_capacity) {
        slot = (session->history_start + session->history_count) % session->history_capacity;
        session->history_count++;
    } else {
        adjust_folds_after_history_drop_oldest(session);
        slot = session->history_start;
        session->history_start = (session->history_start + 1) % session->history_capacity;
    }
    MicaHistoryRow *row = &session->history[slot];
    row->continuation = continuation;
    row->screen_cols = (size_t)cols;
    if (session->screen_landmarks && (size_t)cols == (size_t)session->cols) {
        row->landmark = session->screen_landmarks[0];
        row->landmark_status = session->screen_landmark_status[0];
        if (session->rows > 1) {
            memmove(session->screen_landmarks, session->screen_landmarks + 1, (size_t)session->rows - 1);
            memmove(session->screen_landmark_status, session->screen_landmark_status + 1,
                ((size_t)session->rows - 1) * sizeof(*session->screen_landmark_status));
        }
        session->screen_landmarks[session->rows - 1] = 0;
        session->screen_landmark_status[session->rows - 1] = 0;
    }
    const uint32_t *links = NULL;
    if (session->resize_source_link_ids && (size_t)cols == session->resize_source_link_cols &&
        session->resize_source_link_next_row < session->resize_source_link_rows) {
        size_t resize_row = session->resize_source_link_next_row;
        links = session->resize_source_link_ids +
            resize_row * session->resize_source_link_cols;
        session->resize_source_link_next_row++;
    } else if ((size_t)cols == (size_t)session->cols) {
        links = session->screen_link_ids;
    }
    size_t compact_cols = history_compact_cols(cells, links, (size_t)cols);
    bool scalar = history_cells_are_scalar(cells, compact_cols);
    if (!history_row_resize_cells(session, row, compact_cols, scalar, scalar)) {
        row->cols = 0;
        (void)history_row_resize_links(session, row, 0);
    } else {
        row->cols = compact_cols;
        if (!history_row_store_cells(session, row, cells)) {
            // Attribute diversity is bounded; keep exact data in the prior
            // compact scalar format when interning would exceed the palette.
            history_row_clear_attributes(session, row);
            if (history_row_resize_cells(session, row, compact_cols, true, false)) {
                row->cols = compact_cols;
                (void)history_row_store_cells(session, row, cells);
            } else {
                row->cols = 0;
                (void)history_row_resize_links(session, row, 0);
            }
        }
        bool has_links = false;
        if (links)
            for (size_t col = 0; col < compact_cols; col++)
                if (links[col]) { has_links = true; break; }
        if (has_links && history_row_resize_links(session, row, compact_cols)) {
            memcpy(row->hyperlinks, links, compact_cols * sizeof(*row->hyperlinks));
        } else if (!has_links) {
            (void)history_row_resize_links(session, row, 0);
        } else {
            (void)history_row_resize_links(session, row, 0);
        }
    }
    // The conservative row limit estimates cells and the index, but linked
    // Unicode rows also allocate hyperlink metadata. Enforce the actual byte
    // allowance without reducing retention for ordinary compact rows.
    while (session->history_storage_bytes > gHistoryLimitBytes && session->history_count > 0) {
        adjust_folds_after_history_drop_oldest(session);
        history_row_release(session, &session->history[session->history_start]);
        session->history_start = (session->history_start + 1) % session->history_capacity;
        session->history_count--;
    }
    size_t new_display_count = display_history_count(session);
    // Offsets measure distance from live output, which advances even when
    // the oldest row is replaced. Keep a retained reading row stationary.
    if (session->view_offset > 0 && session->view_offset < new_display_count)
        session->view_offset++;
    if (session->view_offset > new_display_count) session->view_offset = new_display_count;
    return 1;
}

static int history_push(int cols, const VTermScreenCell *cells, void *user) {
    return history_push_continued(cols, cells, false, user);
}

static int history_pop_continued(int cols, VTermScreenCell *cells, bool *continuation,
                                 int destination_row, void *user) {
    MicaSession *session = user;
    if (!session || session->history_count == 0) return 0;
    size_t slot = (session->history_start + session->history_count - 1) % session->history_capacity;
    if (session->history[slot].screen_cols != (size_t)cols) return 0;
    for (int col = 0; col < cols; col++) cells[col] = history_blank_cell();
    MicaHistoryRow *row = &session->history[slot];
    if (continuation) *continuation = row->continuation;
    size_t copy_cols = row->cols < (size_t)cols ? row->cols : (size_t)cols;
    for (size_t col = 0; col < copy_cols; col++) cells[col] = history_cell_at(row, col);
    if (row->hyperlinks && session->resize_target_link_ids && destination_row >= 0 &&
        (size_t)destination_row < session->resize_target_link_rows) {
        size_t link_cols = row->hyperlink_capacity < session->resize_target_link_cols
            ? row->hyperlink_capacity : session->resize_target_link_cols;
        memcpy(session->resize_target_link_ids + (size_t)destination_row * session->resize_target_link_cols,
            row->hyperlinks, link_cols * sizeof(*row->hyperlinks));
    }
    session->history_count--;
    history_row_release(session, row);
    if (session->scrolled_total > 0) session->scrolled_total--;
    adjust_folds_after_history_pop(session);
    if (session->history_count == 0) session->history_start = 0;
    size_t display_count = display_history_count(session);
    if (session->view_offset > display_count) session->view_offset = display_count;
    return 1;
}

static int history_pop(int cols, VTermScreenCell *cells, void *user) {
    return history_pop_continued(cols, cells, NULL, -1, user);
}

static int history_pop_continued4(int cols, VTermScreenCell *cells, bool *continuation, void *user) {
    return history_pop_continued(cols, cells, continuation, -1, user);
}

static int history_pop_continued5(int cols, VTermScreenCell *cells, bool *continuation,
                                  int destination_row, void *user) {
    return history_pop_continued(cols, cells, continuation, destination_row, user);
}

static int history_clear(void *user) {
    MicaSession *session = user;
    if (!session) return 1;
    for (size_t i = 0; i < session->history_capacity; i++) history_row_release(session, &session->history[i]);
    free(session->history);
    session->history = NULL;
    session->history_storage_bytes = 0;
    session->history_capacity = 0;
    session->history_cols = 0;
    session->history_start = 0;
    session->history_count = 0;
    session->scrolled_total = 0;
    session->view_offset = 0;
    if (session->screen_link_ids)
        memset(session->screen_link_ids, 0, (size_t)session->rows * session->cols * sizeof(*session->screen_link_ids));
    clear_folds(session);
    return 1;
}

#ifdef MICA_SESSION_TESTING
static bool fail_next_history_resize_allocation;
static bool fail_next_resize_link_snapshot_allocation;
void mica_session_test_fail_next_history_resize_allocation(void) {
    fail_next_history_resize_allocation = true;
}
void mica_session_test_fail_next_resize_link_snapshot_allocation(void) {
    fail_next_resize_link_snapshot_allocation = true;
}
#endif

static MicaHistoryRow *allocate_history_index(size_t capacity) {
#ifdef MICA_SESSION_TESTING
    if (fail_next_history_resize_allocation) {
        fail_next_history_resize_allocation = false;
        return NULL;
    }
#endif
    return capacity ? calloc(capacity, sizeof(MicaHistoryRow)) : NULL;
}

static const VTermScreenCallbacks screen_callbacks = {
    .damage = damage_callback,
    .moverect = move_link_rect,
    .movecursor = cursor_callback,
    .settermprop = property_callback,
    .bell = bell_callback,
    .sb_pushline = history_push,
    .sb_pushline4 = history_push_continued,
    .sb_popline = history_pop,
    .sb_popline4 = history_pop_continued4,
    .sb_popline5 = history_pop_continued5,
    .sb_clear = history_clear,
};

static bool directory_is_enterable(const char *path, int *error) {
    struct stat info;
    if (stat(path, &info) != 0) { *error = errno; return false; }
    if (!S_ISDIR(info.st_mode)) { *error = ENOTDIR; return false; }
    if (access(path, X_OK) != 0) { *error = errno; return false; }
    return true;
}

// Decides in the parent which folder the shell starts in, so the forked child only needs
// chdir() and write(). `message` explains a fallback and is empty when the folder was fine.
static bool plan_working_directory(const char *requested, char *directory, size_t directory_size,
                                   char *message, size_t message_size) {
    message[0] = '\0';
    if (!requested || !requested[0]) { directory[0] = '\0'; return true; }
    int original_error = 0;
    if (directory_is_enterable(requested, &original_error)) {
        snprintf(directory, directory_size, "%s", requested);
        return true;
    }
    char candidate[PATH_MAX];
    snprintf(candidate, sizeof(candidate), "%s", requested);
    while (candidate[0]) {
        size_t length = strlen(candidate);
        while (length > 1 && candidate[length - 1] == '/') candidate[--length] = '\0';
        char *separator = strrchr(candidate, '/');
        if (!separator) { candidate[0] = '.'; candidate[1] = '\0'; }
        else if (separator == candidate) candidate[1] = '\0';
        else *separator = '\0';
        int ignored = 0;
        if (directory_is_enterable(candidate, &ignored)) {
            snprintf(directory, directory_size, "%s", candidate);
            snprintf(message, message_size, "mica: cannot enter %s: %s; using %s\r\n",
                     requested, strerror(original_error), candidate);
            return true;
        }
        if (strcmp(candidate, ".") == 0 || strcmp(candidate, "/") == 0) break;
    }
    const char *home = getenv("HOME");
    int ignored = 0;
    if (home && home[0] && directory_is_enterable(home, &ignored)) {
        snprintf(directory, directory_size, "%s", home);
        snprintf(message, message_size, "mica: cannot enter %s: %s; using %s\r\n",
                 requested, strerror(original_error), home);
        return true;
    }
    snprintf(message, message_size, "mica: cannot enter %s or a parent folder: %s\r\n",
             requested, strerror(original_error));
    return false;
}

// OSC 52: programs (often over SSH or tmux) ask the terminal to set the clipboard.
// Only writes are supported; read requests are ignored so nothing leaks out.
#define MICA_CLIPBOARD_LIMIT (256u * 1024u)
static int selection_set(VTermSelectionMask mask, VTermStringFragment frag, void *user) {
    MicaSession *session = user;
    (void)mask;
    if (!session) return 1;
    if (frag.initial) { session->clipboard_length = 0; session->clipboard_overflow = false; session->clipboard_ready = false; }
    if (session->clipboard_overflow) return 1;
    if (session->clipboard_length + frag.len > MICA_CLIPBOARD_LIMIT) { session->clipboard_overflow = true; return 1; }
    if (session->clipboard_length + frag.len + 1 > session->clipboard_capacity) {
        size_t capacity = session->clipboard_capacity ? session->clipboard_capacity * 2 : 4096;
        while (capacity < session->clipboard_length + frag.len + 1) capacity *= 2;
        char *grown = realloc(session->clipboard_text, capacity);
        if (!grown) { session->clipboard_overflow = true; return 1; }
        session->clipboard_text = grown;
        session->clipboard_capacity = capacity;
    }
    if (frag.len) memcpy(session->clipboard_text + session->clipboard_length, frag.str, frag.len);
    session->clipboard_length += frag.len;
    if (frag.final) {
        session->clipboard_text[session->clipboard_length] = '\0';
        session->clipboard_ready = true;
        session->revision++;
    }
    return 1;
}
static int selection_query(VTermSelectionMask mask, void *user) { (void)mask; (void)user; return 0; }
static const VTermSelectionCallbacks selection_callbacks = { .set = selection_set, .query = selection_query };

// DEC private mode 2026 (synchronized output): a TUI brackets a frame with
// CSI ? 2026 h ... CSI ? 2026 l so the terminal can present it without tearing.
static double monotonic_seconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (double)now.tv_sec + (double)now.tv_nsec / 1e9;
}
// libvterm consumes unknown DEC modes silently, so watch the raw byte stream for the toggles.
static void scan_synchronized_output_chunk(MicaSession *session, const char *bytes, size_t length, size_t first_start_limit) {
    const size_t sequence_length = 8;
    for (size_t i = 0; i < first_start_limit && i + sequence_length <= length; i++) {
        if (bytes[i] != '\x1b') continue;
        if (memcmp(bytes + i, "\x1b[?2004h", sequence_length) == 0) { session->bracketed_paste = true; continue; }
        if (memcmp(bytes + i, "\x1b[?2004l", sequence_length) == 0) { session->bracketed_paste = false; continue; }
    }
}

// Sequences can straddle two reads, so keep the last few bytes and rescan across the seam.
static void scan_synchronized_output(MicaSession *session, const char *bytes, size_t length) {
    const size_t sequence_length = 8;
    if (session->sync_tail_length) {
        char seam[16];
        size_t head = length < sequence_length - 1 ? length : sequence_length - 1;
        memcpy(seam, session->sync_tail, session->sync_tail_length);
        memcpy(seam + session->sync_tail_length, bytes, head);
        // Only sequences starting in the saved tail are new; the rest is covered by the main scan.
        scan_synchronized_output_chunk(session, seam, session->sync_tail_length + head, session->sync_tail_length);
    }
    scan_synchronized_output_chunk(session, bytes, length, length);
    size_t keep = length < sequence_length - 1 ? length : sequence_length - 1;
    if (length < sequence_length - 1 && session->sync_tail_length) {
        size_t combined = session->sync_tail_length + length;
        size_t retained = combined < sequence_length - 1 ? combined : sequence_length - 1;
        memmove(session->sync_tail, session->sync_tail + session->sync_tail_length - (retained - length), retained - length);
        memcpy(session->sync_tail + (retained - length), bytes, length);
        session->sync_tail_length = retained;
        return;
    }
    memcpy(session->sync_tail, bytes + length - keep, keep);
    session->sync_tail_length = keep;
}


// A frame bracketed by CSI ? 2026 h ... CSI ? 2026 l is held back as bytes and handed to the terminal
// emulator only when the frame ends, so no repaint (timer tick, animation, resize) can ever show it half
// drawn. A frame that never ends is released after a second.
#define MICA_SYNC_HOLD_LIMIT (4u * 1024u * 1024u)
#define MICA_SYNC_TIMEOUT 1.0

static void release_sync_hold(MicaSession *session) {
    if (session->sync_hold_length) vterm_input_write(session->vt, session->sync_hold, session->sync_hold_length);
    session->sync_hold_length = 0;
    session->sync_output = false;
    session->revision++;
}

static void hold_sync_bytes(MicaSession *session, const char *bytes, size_t length) {
    if (!length) return;
    // Keep this arithmetic bounded even if a future caller supplies a much
    // larger chunk. The previous add-then-compare could wrap size_t and let
    // the subsequent memcpy run past the fixed synchronized-frame limit.
    if (session->sync_hold_length > MICA_SYNC_HOLD_LIMIT ||
        length > MICA_SYNC_HOLD_LIMIT - session->sync_hold_length) {
        release_sync_hold(session);
        vterm_input_write(session->vt, bytes, length);
        return;
    }
    size_t required = session->sync_hold_length + length;
    if (required > session->sync_hold_capacity) {
        size_t capacity = session->sync_hold_capacity ? session->sync_hold_capacity : 16384;
        while (capacity < required) {
            if (capacity > MICA_SYNC_HOLD_LIMIT / 2) {
                capacity = MICA_SYNC_HOLD_LIMIT;
                break;
            }
            capacity *= 2;
        }
        char *grown = realloc(session->sync_hold, capacity);
        if (!grown) { vterm_input_write(session->vt, bytes, length); return; }
        session->sync_hold = grown;
        session->sync_hold_capacity = capacity;
    }
    memcpy(session->sync_hold + session->sync_hold_length, bytes, length);
    session->sync_hold_length += length;
}

static void feed_terminal_output_whole(MicaSession *session, const char *bytes, size_t length) {
    static const char prefix[] = "\x1b[?2026";
    const size_t prefix_length = sizeof(prefix) - 1;
    size_t position = 0;
    for (size_t i = 0; i + prefix_length < length; i++) {
        if (bytes[i] != '\x1b' || memcmp(bytes + i, prefix, prefix_length) != 0) continue;
        char mode = bytes[i + prefix_length];
        if (mode != 'h' && mode != 'l') continue;
        size_t end = i + prefix_length + 1;
        if (mode == 'h' && !session->sync_output) {
            vterm_input_write(session->vt, bytes + position, end - position);
            session->sync_output = true;
            session->sync_output_started = monotonic_seconds();
        } else if (mode == 'l' && session->sync_output) {
            hold_sync_bytes(session, bytes + position, end - position);
            release_sync_hold(session);
        } else {
            continue;
        }
        position = end;
        i = end - 1;
    }
    if (position >= length) return;
    if (session->sync_output) hold_sync_bytes(session, bytes + position, length - position);
    else vterm_input_write(session->vt, bytes + position, length - position);
}

// A mode-2026 marker can straddle two reads; keep a possible partial marker at the end of a read until
// the next one (or 100 ms, whichever comes first) so it is recognized.
static void feed_terminal_output(MicaSession *session, const char *bytes, size_t length) {
    static const char full[] = "\x1b[?2026";
    char *joined = NULL;
    if (session->sync_carry_length) {
        joined = malloc(session->sync_carry_length + length);
        if (joined) {
            memcpy(joined, session->sync_carry, session->sync_carry_length);
            memcpy(joined + session->sync_carry_length, bytes, length);
            bytes = joined;
            length += session->sync_carry_length;
        }
        session->sync_carry_length = 0;
    }
    size_t keep = 0;
    for (size_t k = (length < sizeof(full) - 1 ? length : sizeof(full) - 1); k > 0; k--) {
        if (memcmp(bytes + length - k, full, k) == 0) { keep = k; break; }
    }
    if (keep) {
        memcpy(session->sync_carry, bytes + length - keep, keep);
        session->sync_carry_length = keep;
        session->sync_carry_at = monotonic_seconds();
        length -= keep;
    }
    if (length) feed_terminal_output_whole(session, bytes, length);
    free(joined);
}

#ifdef MICA_SESSION_TESTING
void mica_session_test_feed_output(MicaSession *session, const char *bytes, size_t length) {
    if (session && bytes && length) feed_terminal_output(session, bytes, length);
}
#endif

static void flush_sync_carry(MicaSession *session) {
    size_t length = session->sync_carry_length;
    session->sync_carry_length = 0;
    char copy[8];
    memcpy(copy, session->sync_carry, length);
    if (length) feed_terminal_output_whole(session, copy, length);
}

static const VTermStateFallbacks screen_fallbacks = { .osc = notification_osc };

extern char **environ;

// Builds the child's environment in the parent. Between fork and exec the child
// of a multithreaded GUI process may only call async-signal-safe functions, so
// setenv/getenv (which take libc locks) must not run there.
typedef struct { const char *key; const char *value; } EnvOverride;

static char **build_child_environment(const EnvOverride *overrides, size_t count) {
    size_t existing = 0;
    while (environ && environ[existing]) existing++;
    char **result = calloc(existing + count + 1, sizeof(*result));
    if (!result) return NULL;
    size_t used = 0;
    for (size_t i = 0; i < existing; i++) {
        bool replaced = false;
        for (size_t j = 0; j < count; j++) {
            size_t key_length = strlen(overrides[j].key);
            if (strncmp(environ[i], overrides[j].key, key_length) == 0 && environ[i][key_length] == '=') { replaced = true; break; }
        }
        if (!replaced && !(result[used] = strdup(environ[i]))) goto fail;
        if (!replaced) used++;
    }
    for (size_t j = 0; j < count; j++) {
        if (!overrides[j].value) continue;
        size_t length = strlen(overrides[j].key) + strlen(overrides[j].value) + 2;
        if (!(result[used] = malloc(length))) goto fail;
        snprintf(result[used++], length, "%s=%s", overrides[j].key, overrides[j].value);
    }
    return result;
fail:
    for (size_t i = 0; result[i]; i++) free(result[i]);
    free(result);
    return NULL;
}

static void free_environment(char **environment) {
    if (!environment) return;
    for (size_t i = 0; environment[i]; i++) free(environment[i]);
    free(environment);
}

static MicaSession *session_create(const char *cwd, const char *command, int rows, int cols,
                                   bool prefilled) {
    if (rows < 1 || cols < 1) return NULL;
    MicaSession *session = calloc(1, sizeof(*session));
    if (!session) return NULL;
    session->master_fd = -1;
    session->child_pid = -1;
    session->terminal_device = UINT32_MAX;
    session->rows = rows;
    session->cols = cols;
    session->running = true;
    {
        unsigned char random_bytes[16];
        arc4random_buf(random_bytes, sizeof(random_bytes));
        for (size_t i = 0; i < sizeof(random_bytes); i++) snprintf(session->mark_token + i * 2, 3, "%02x", random_bytes[i]);
    }
    {
        unsigned char random_bytes[16]; arc4random_buf(random_bytes, sizeof(random_bytes));
        for (size_t i=0;i<sizeof(random_bytes);i++) snprintf(session->hook_token+i*2,3,"%02x",random_bytes[i]);
    }
    session->command = command ? strdup(command) : strdup("/bin/zsh -l -i");
    session->startup_dir = create_prefill_startup_dir();
    session->vt = vterm_new(rows, cols);
    if (!session->command || !session->vt || (prefilled && command && !session->startup_dir)) goto fail;

    vterm_set_utf8(session->vt, 1);
    session->state = vterm_obtain_state(session->vt);
    vterm_state_set_selection_callbacks(session->state, &selection_callbacks, session,
                                        session->selection_buffer, sizeof(session->selection_buffer));
    session->screen = vterm_obtain_screen(session->vt);
    vterm_screen_set_callbacks(session->screen, &screen_callbacks, session);
    vterm_screen_callbacks_has_pushline4(session->screen);
    vterm_screen_callbacks_has_popline4(session->screen);
    vterm_screen_callbacks_has_popline5(session->screen);
    vterm_screen_set_unrecognised_fallbacks(session->screen, &screen_fallbacks, session);
    vterm_screen_set_damage_merge(session->screen, VTERM_DAMAGE_ROW);
    vterm_screen_enable_reflow(session->screen, true);
    vterm_screen_enable_altscreen(session->screen, 1);
    vterm_output_set_callback(session->vt, output_callback, session);
    vterm_screen_reset(session->screen, 1);
    configure_terminal_colors(session, false);
    vterm_input_write(session->vt, "\x1b[0m", 4);

    const char *locale_hint = (!getenv("LANG") && !getenv("LC_ALL") && !getenv("LC_CTYPE")) ? "en_US.UTF-8" : NULL;
    const char *original_zdotdir = getenv("MICA_ORIGINAL_ZDOTDIR");
    if (!original_zdotdir || !original_zdotdir[0]) original_zdotdir = getenv("ZDOTDIR");
    if (!original_zdotdir || !original_zdotdir[0]) original_zdotdir = getenv("HOME");
    if (!original_zdotdir || !original_zdotdir[0]) original_zdotdir = ".";
    bool use_wrapper = session->startup_dir != NULL;
    // GUI launchers can inherit NO_COLOR from an unrelated parent shell.
    // Mica advertises a color-capable xterm-256color terminal.
    EnvOverride overrides[] = {
        { "LANG", locale_hint }, { "MICA_MARK_TOKEN", session->mark_token }, { "MICA_TAB_TOKEN", session->hook_token }, { "MICA_HOOK_SOCK", getenv("MICA_HOOK_SOCK") }, { "TERM", "xterm-256color" }, { "COLORTERM", "truecolor" },
        { "TERM_PROGRAM", "Mica" }, { "TERM_PROGRAM_VERSION", MICA_VERSION },
        { "TERM_PROGRAM_REVISION", MICA_REVISION }, { "CLICOLOR", "1" }, { "NO_COLOR", NULL },
        { "MICA_ORIGINAL_ZDOTDIR", use_wrapper ? original_zdotdir : NULL },
        { "MICA_ZSH_WRAPPER", use_wrapper ? session->startup_dir : NULL },
        { "ZDOTDIR", use_wrapper ? session->startup_dir : NULL },
        { "MICA_INITIAL_COMMAND", (use_wrapper && prefilled && command) ? command : NULL },
    };
    size_t override_count = sizeof(overrides) / sizeof(overrides[0]);
    char **child_environment = NULL;
    {
        EnvOverride active[sizeof(overrides) / sizeof(overrides[0])];
        size_t active_count = 0;
        for (size_t i = 0; i < override_count; i++) {
            bool unsets = strcmp(overrides[i].key, "NO_COLOR") == 0;
            if (overrides[i].value || unsets) active[active_count++] = overrides[i];
        }
        child_environment = build_child_environment(active, active_count);
    }
    if (!child_environment) goto fail;
    const char *test_mode = getenv("MICA_TEST_NO_STARTUP");
    bool skip_user_startup = test_mode && strcmp(test_mode, "1") == 0;
    // Some UI tests need Mica's temporary ZDOTDIR wrapper to install a
    // ZLE probe, while still suppressing every user startup file.
    bool test_zle_probe = skip_user_startup && getenv("MICA_TEST_ZLE_DIR") != NULL;
    bool prefilled_shell = use_wrapper && prefilled && command;

    char start_directory[PATH_MAX], start_message[PATH_MAX * 2 + 128];
    bool start_directory_ok = plan_working_directory(cwd, start_directory, sizeof(start_directory),
                                                     start_message, sizeof(start_message));
    struct winsize window_size = { .ws_row = (unsigned short)rows, .ws_col = (unsigned short)cols };
    int master = -1;
    pid_t pid = forkpty(&master, NULL, NULL, &window_size);
    if (pid < 0) { free_environment(child_environment); goto fail; }
    if (pid == 0) {
        struct termios terminal_settings;
        if (tcgetattr(STDIN_FILENO, &terminal_settings) == 0) {
            terminal_settings.c_iflag &= (tcflag_t)~(IXON | IXOFF);
            terminal_settings.c_iflag |= IUTF8;
            (void)tcsetattr(STDIN_FILENO, TCSANOW, &terminal_settings);
        }
        // The GUI process may ignore or block signals; the shell must start clean.
        signal(SIGPIPE, SIG_DFL); signal(SIGINT, SIG_DFL); signal(SIGQUIT, SIG_DFL);
        signal(SIGHUP, SIG_DFL); signal(SIGTSTP, SIG_DFL); signal(SIGCHLD, SIG_DFL);
        sigset_t no_signals;
        sigemptyset(&no_signals);
        sigprocmask(SIG_SETMASK, &no_signals, NULL);
        if (start_message[0]) { ssize_t written = write(STDERR_FILENO, start_message, strlen(start_message)); (void)written; }
        if (!start_directory_ok || (start_directory[0] && chdir(start_directory) != 0)) _exit(126);
        environ = child_environment;
        if (prefilled_shell) {
            execl("/bin/zsh", "zsh", "-l", "-i", (char *)NULL);
        }
        if (command) {
            if (skip_user_startup && !test_zle_probe) {
                execl("/bin/zsh", "zsh", "-f", "-i", "-c",
                      "mica_command=$1; mica_label=${mica_command#unset CLAUDECODE && }; mica_label=${mica_label##[[:space:]]#}; mica_label=${mica_label%%[[:space:]]*}; printf '\\033]777;mica;%s;command-started;%s\\033\\\\' \"$MICA_MARK_TOKEN\" \"$mica_label\"; eval \"$mica_command\"; mica_status=$?; printf '\\n[command exited: %d]\\n' \"$mica_status\"; printf '\\033]777;mica;%s;command-finished;%d\\033\\\\' \"$MICA_MARK_TOKEN\" \"$mica_status\"; exec /bin/zsh -f -i",
                      "mica", command, (char *)NULL);
            } else {
                execl("/bin/zsh", "zsh", "-l", "-i", "-c",
                      "mica_command=$1; mica_label=${mica_command#unset CLAUDECODE && }; mica_label=${mica_label##[[:space:]]#}; mica_label=${mica_label%%[[:space:]]*}; printf '\\033]777;mica;%s;command-started;%s\\033\\\\' \"$MICA_MARK_TOKEN\" \"$mica_label\"; eval \"$mica_command\"; mica_status=$?; printf '\\n[command exited: %d]\\n' \"$mica_status\"; printf '\\033]777;mica;%s;command-finished;%d\\033\\\\' \"$MICA_MARK_TOKEN\" \"$mica_status\"; exec /bin/zsh -l -i",
                      "mica", command, (char *)NULL);
            }
        } else {
            if (skip_user_startup && !test_zle_probe) execl("/bin/zsh", "zsh", "-f", "-i", (char *)NULL);
            else execl("/bin/zsh", "zsh", "-l", "-i", (char *)NULL);
        }
        dprintf(STDERR_FILENO, "mica: cannot start zsh: %s\r\n", strerror(errno));
        _exit(127);
    }
    free_environment(child_environment);
    session->master_fd = master;
    session->child_pid = pid;
    session->terminal_device = terminal_device_for_master(master);
    int flags = fcntl(master, F_GETFL, 0);
    if (flags >= 0) fcntl(master, F_SETFL, flags | O_NONBLOCK);
    int descriptor_flags = fcntl(master, F_GETFD, 0);
    if (descriptor_flags < 0 || fcntl(master, F_SETFD, descriptor_flags | FD_CLOEXEC) < 0) {
        mica_session_destroy(session);
        return NULL;
    }
    return session;

fail:
    mica_session_destroy(session);
    return NULL;
}

MicaSession *mica_session_create(const char *cwd, const char *command, int rows, int cols) {
    return session_create(cwd, command, rows, cols, false);
}

MicaSession *mica_session_create_prefilled(const char *cwd, const char *command, int rows, int cols) {
    return session_create(cwd, command, rows, cols, true);
}

void mica_session_destroy(MicaSession *session) {
    if (!session) return;
    pid_t pid = session->child_pid;
    MicaProcessIdentity *process_tree = NULL;
    double stage_started = cleanup_stage_begin(pid, "snapshot_process_tree");
    size_t process_count = session->child_pid > 0
        ? snapshot_process_tree(session->child_pid, &process_tree) : 0;
    cleanup_stage_end(pid, "snapshot_process_tree", stage_started);
    MicaProcessIdentity *terminal_processes = NULL;
    stage_started = cleanup_stage_begin(pid, "snapshot_terminal_processes");
    size_t terminal_process_count = session->master_fd >= 0
        ? snapshot_terminal_processes(session->terminal_device, &terminal_processes) : 0;
    cleanup_stage_end(pid, "snapshot_terminal_processes", stage_started);
    if (session->master_fd >= 0) {
        double close_started = cleanup_stage_begin(pid, "close_pty");
        close(session->master_fd);
        cleanup_stage_end(pid, "close_pty", close_started);
        session->master_fd = -1;
    }
    if (session->running) {
        stage_started = cleanup_stage_begin(pid, "signal_hangup");
        signal_process_tree(process_tree, process_count, SIGHUP);
        signal_process_tree(terminal_processes, terminal_process_count, SIGHUP);
        cleanup_stage_end(pid, "signal_hangup", stage_started);
    }
    if (session->child_pid > 0 && session->running) {
        // Give the shell and its descendants a short grace period, then kill
        // the captured tree even if the shell leader already exited. Children
        // can have separate process groups and ignore the terminal hangup.
        int status = 0;
        bool childReaped = false;
        stage_started = cleanup_stage_begin(pid, "graceful_wait");
        for (int attempt = 0; attempt < 40; attempt++) {
            pid_t result = waitpid(session->child_pid, &status, WNOHANG);
            if (result == session->child_pid || (result < 0 && errno == ECHILD)) {
                childReaped = true;
                break;
            }
            struct timespec pause = { .tv_sec = 0, .tv_nsec = 5000000 };
            nanosleep(&pause, NULL);
        }
        cleanup_stage_end(pid, "graceful_wait", stage_started);
        stage_started = cleanup_stage_begin(pid, "signal_kill");
        signal_process_tree(process_tree, process_count, SIGKILL);
        signal_process_tree(terminal_processes, terminal_process_count, SIGKILL);
        cleanup_stage_end(pid, "signal_kill", stage_started);
        if (!childReaped) {
            // The child has not been reaped, so its PID cannot have been
            // recycled. Do not signal it after waitpid has reaped it.
            (void)kill(session->child_pid, SIGKILL);
            stage_started = cleanup_stage_begin(pid, "forced_reap");
            for (int attempt = 0; attempt < 50; attempt++) {
                pid_t result = waitpid(session->child_pid, &status, WNOHANG);
                if (result == session->child_pid || (result < 0 && errno == ECHILD)) break;
                struct timespec pause = { .tv_sec = 0, .tv_nsec = 5000000 };
                nanosleep(&pause, NULL);
            }
            cleanup_stage_end(pid, "forced_reap", stage_started);
        }
    } else {
        // The interactive shell may already have exited while a child it
        // started remains attached to this PTY. Its controlling-terminal ID
        // still lets us clean up that process without trusting a stale PID.
        stage_started = cleanup_stage_begin(pid, "signal_orphan_hangup");
        signal_process_tree(terminal_processes, terminal_process_count, SIGHUP);
        cleanup_stage_end(pid, "signal_orphan_hangup", stage_started);
        if (terminal_process_count) {
            stage_started = cleanup_stage_begin(pid, "orphan_grace_wait");
            struct timespec pause = { .tv_sec = 0, .tv_nsec = 50000000 };
            nanosleep(&pause, NULL);
            cleanup_stage_end(pid, "orphan_grace_wait", stage_started);
            stage_started = cleanup_stage_begin(pid, "signal_orphan_kill");
            signal_process_tree(terminal_processes, terminal_process_count, SIGKILL);
            cleanup_stage_end(pid, "signal_orphan_kill", stage_started);
        }
    }
    double release_started = cleanup_stage_begin(pid, "release_session_resources");
    free(process_tree);
    free(terminal_processes);
    if (session->vt) vterm_free(session->vt);
    for (size_t i = 0; i < session->history_capacity; i++) history_row_release(session, &session->history[i]);
    free(session->history);
    free(session->sync_hold);
    free(session->screen_link_ids);
    free(session->screen_landmarks);
    free(session->screen_landmark_status);
    for (size_t i = 0; i < session->hyperlink_count; i++) free(session->hyperlink_uris[i]);
    free(session->hyperlink_uris);
    clear_folds(session);
    clear_pending_input(session);
    free(session->command);
    free(session->clipboard_text);
    free(session->current_command);
    free(session->title);
    remove_prefill_startup_dir(session->startup_dir);
    cleanup_stage_end(pid, "release_session_resources", release_started);
    free(session);
}

int mica_session_poll(MicaSession *session, int timeout_ms) {
    if (!session) return -1;
    if (session->sync_carry_length && monotonic_seconds() - session->sync_carry_at > 0.1) {
        flush_sync_carry(session);
        vterm_screen_flush_damage(session->screen);
    }
    if (session->sync_output && monotonic_seconds() - session->sync_output_started > MICA_SYNC_TIMEOUT) {
        release_sync_hold(session);
        vterm_screen_flush_damage(session->screen);
    }
    if (session->master_fd >= 0) {
        short events = POLLIN | POLLHUP | POLLERR;
        if (session->pending_input_length > session->pending_input_offset) events |= POLLOUT;
        struct pollfd pfd = { .fd = session->master_fd, .events = events };
        int rc = poll(&pfd, 1, timeout_ms);
        if (rc > 0 && (pfd.revents & POLLOUT)) flush_pending_input(session);
        if (rc > 0 && (pfd.revents & (POLLIN | POLLHUP | POLLERR))) {
            char buffer[MICA_READ_BUFFER];
            size_t bytes_read = 0;
            bool received_output = false;
            while (bytes_read < MICA_POLL_READ_BUDGET) {
                ssize_t n = read(session->master_fd, buffer, sizeof(buffer));
                if (n > 0) {
                    struct timespec parse_started, parse_finished;
                    clock_gettime(CLOCK_MONOTONIC, &parse_started);
                    scan_synchronized_output(session, buffer, (size_t)n);
                    feed_terminal_output(session, buffer, (size_t)n);
                    clock_gettime(CLOCK_MONOTONIC, &parse_finished);
                    double parse_ms = (parse_finished.tv_sec - parse_started.tv_sec) * 1000.0 +
                        (parse_finished.tv_nsec - parse_started.tv_nsec) / 1000000.0;
                    session->output_metrics.bytes_read += (size_t)n;
                    session->output_metrics.read_calls++;
                    if ((size_t)n > session->output_metrics.largest_read)
                        session->output_metrics.largest_read = (size_t)n;
                    session->output_metrics.parse_milliseconds += parse_ms;
                    bytes_read += (size_t)n;
                    received_output = true;
                    continue;
                }
                if (n < 0 && errno == EINTR) continue;
                if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
                if (n == 0 || (n < 0 && errno == EIO)) {
                    close(session->master_fd);
                    session->master_fd = -1;
                    clear_pending_input(session);
                }
                break;
            }
            if (received_output) vterm_screen_flush_damage(session->screen);
        }
    }
    if (session->running && session->child_pid > 0) {
        int status = 0;
        pid_t result = waitpid(session->child_pid, &status, WNOHANG);
        if (result == session->child_pid) {
            session->running = false;
            session->exit_status = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
        } else if (result < 0 && errno == ECHILD) {
            session->running = false;
            session->exit_status = 0;
        }
    }
    return 0;
}

int mica_session_fd(const MicaSession *session) {
    return session ? session->master_fd : -1;
}

bool mica_session_take_output_metrics(MicaSession *session, MicaSessionOutputMetrics *metrics) {
    if (!session || !metrics) return false;
    *metrics = session->output_metrics;
    memset(&session->output_metrics, 0, sizeof(session->output_metrics));
    return metrics->bytes_read > 0;
}

void mica_session_write(MicaSession *session, const void *bytes, size_t length) {
    write_nonblocking(session, bytes, length);
}

void mica_session_key(MicaSession *session, VTermKey key, VTermModifier modifiers) {
    if (!session || !session->vt || !session->running) return;
    /* Keep Shift-Return distinct from Return for multiline input. */
    if (key == VTERM_KEY_ENTER &&
        (modifiers & (VTERM_MOD_SHIFT | VTERM_MOD_ALT | VTERM_MOD_CTRL)) == VTERM_MOD_SHIFT) {
        static const char shift_enter[] = "\033\r";
        write_nonblocking(session, shift_enter, sizeof(shift_enter) - 1);
        return;
    }
    vterm_keyboard_key(session->vt, key, modifiers);
}

void mica_session_text(MicaSession *session, uint32_t codepoint, VTermModifier modifiers) {
    if (session && session->vt && session->running) vterm_keyboard_unichar(session->vt, codepoint, modifiers);
}

void mica_session_paste(MicaSession *session, const char *utf8, size_t length) {
    if (!session || !session->vt || !session->running || !utf8) return;
    // Reserve the sanitized paste and both six-byte bracket markers as one
    // transaction. Never leave the shell inside bracketed-paste mode or send
    // a truncated paste if the queue is already full.
    if (length > MICA_PENDING_INPUT_LIMIT - 12) return;
    char *safe = malloc(length ? length : 1);
    if (!safe) return;
    size_t safe_length = 0;
    for (size_t index = 0; index < length; index++)
{
            unsigned char byte = (unsigned char)utf8[index];
            // Keep tab, newline and carriage return; drop ESC and other C0 controls that could act as input.
            if (byte == 0x1b || byte == 0x7f || (byte < 0x20 && byte != '\t' && byte != '\n' && byte != '\r')) continue;
            safe[safe_length++] = utf8[index];
        }
    if (!reserve_pending_input(session, safe_length + 12)) {
        free(safe);
        return;
    }
    vterm_keyboard_start_paste(session->vt);
    // Clipboard contents are untrusted terminal input. In particular, an ESC
    // can terminate bracketed-paste mode and turn a following newline into an
    // executable command in the user's shell.
    write_nonblocking(session, safe, safe_length);
    vterm_keyboard_end_paste(session->vt);
    free(safe);
}

void mica_session_mouse(MicaSession *session, int row, int col, int button, bool pressed) {
    if (session && session->vt && session->running) {
        vterm_mouse_move(session->vt, row, col, VTERM_MOD_NONE);
        vterm_mouse_button(session->vt, button, pressed, VTERM_MOD_NONE);
    }
}

void mica_session_wheel(MicaSession *session, int row, int col, int direction) {
    if (!session || !session->vt || !session->running) return;
    vterm_mouse_move(session->vt, row, col, VTERM_MOD_NONE);
    vterm_mouse_button(session->vt, direction < 0 ? 4 : 5, true, VTERM_MOD_NONE);
}

void mica_session_focus(MicaSession *session, bool focused) {
    if (!session || !session->state) return;
    if (focused) vterm_state_focus_in(session->state);
    else vterm_state_focus_out(session->state);
}

bool mica_session_resize(MicaSession *session, int rows, int cols) {
    if (!session) return false;
    return mica_session_resize_pixels(session, rows, cols, session->pixel_width, session->pixel_height);
}

bool mica_session_resize_pixels(MicaSession *session, int rows, int cols, int pixel_width, int pixel_height) {
    if (!session || rows < 1 || cols < 1 || pixel_width < 0 || pixel_height < 0) return false;
    int old_rows = session->rows;
    bool grid_changed = rows != session->rows || cols != session->cols;
    bool pixels_changed = pixel_width != session->pixel_width || pixel_height != session->pixel_height;
    if (!grid_changed && !pixels_changed) return true;
    bool resize_history_index = (size_t)cols > session->history_cols;
    size_t resized_capacity = 0;
    MicaHistoryRow *resized_history = NULL;
    if (resize_history_index) {
        resized_capacity = session->history_capacity;
        size_t limit = history_limit_lines(cols);
        if (resized_capacity > limit) resized_capacity = limit;
        resized_history = allocate_history_index(resized_capacity);
        if (resized_capacity && !resized_history) return false;
    }
    uint32_t *resize_link_snapshot = NULL;
    uint32_t *resize_link_target = NULL;
    if (grid_changed && session->screen_link_ids) {
        if (session->rows <= 0 || session->cols <= 0 ||
            (size_t)session->rows > SIZE_MAX / (size_t)session->cols ||
            (size_t)session->rows * (size_t)session->cols > SIZE_MAX / sizeof(*resize_link_snapshot) ||
            (size_t)rows > SIZE_MAX / (size_t)cols ||
            (size_t)rows * (size_t)cols > SIZE_MAX / sizeof(*resize_link_target)) {
            free(resized_history);
            return false;
        }
        size_t link_count = (size_t)session->rows * (size_t)session->cols;
        bool snapshot_allocation_failed = false;
#ifdef MICA_SESSION_TESTING
        if (fail_next_resize_link_snapshot_allocation) {
            fail_next_resize_link_snapshot_allocation = false;
            snapshot_allocation_failed = true;
        }
#endif
        if (!snapshot_allocation_failed)
            resize_link_snapshot = malloc(link_count * sizeof(*resize_link_snapshot));
        if (!resize_link_snapshot) {
            free(resized_history);
            return false;
        }
        resize_link_target = calloc((size_t)rows * (size_t)cols, sizeof(*resize_link_target));
        if (!resize_link_target) {
            free(resize_link_snapshot);
            free(resized_history);
            return false;
        }
        memcpy(resize_link_snapshot, session->screen_link_ids,
            link_count * sizeof(*resize_link_snapshot));
        session->resize_source_link_ids = resize_link_snapshot;
        session->resize_source_link_cols = (size_t)session->cols;
        session->resize_source_link_rows = (size_t)session->rows;
        session->resize_source_link_next_row = 0;
        session->resize_target_link_ids = resize_link_target;
        session->resize_target_link_cols = (size_t)cols;
        session->resize_target_link_rows = (size_t)rows;
    }
    if (grid_changed) {
        clear_folds(session);
        if (session->view_offset > session->history_count)
            session->view_offset = session->history_count;
        // History rows retain their physical width here, so their link sidecars
        // remain aligned. Pushed rows read from the source-grid snapshot above;
        // links still in the transformed live grid are rebuilt on later output.
        free(session->screen_link_ids);
        session->screen_link_ids = NULL;
        session->pending_link_move_valid = false;
    }
    if (resize_history_index) {
        size_t kept = session->history_count;
        if (kept > resized_capacity) kept = resized_capacity;
        size_t skip = session->history_count - kept;
        size_t old_capacity = session->history_capacity;
        for (size_t i = 0; i < kept; i++) {
            size_t old_slot = (session->history_start + skip + i) % old_capacity;
            resized_history[i] = session->history[old_slot];
        }
        for (size_t i = 0; i < skip; i++) {
            size_t old_slot = (session->history_start + i) % old_capacity;
            history_row_release(session, &session->history[old_slot]);
        }
        free(session->history);
        session->history = resized_history;
        session->history_capacity = resized_capacity;
        session->history_cols = (size_t)cols;
        session->history_count = kept;
        session->history_start = 0;
        session->history_storage_bytes = session->history_storage_bytes - old_capacity * sizeof(MicaHistoryRow) +
            resized_capacity * sizeof(MicaHistoryRow);
        if (session->view_offset > kept) session->view_offset = kept;
    }
    if (grid_changed) {
        vterm_set_size(session->vt, rows, cols);
        free(resize_link_snapshot);
        session->resize_source_link_ids = NULL;
        session->resize_source_link_cols = 0;
        session->resize_source_link_rows = 0;
        session->resize_source_link_next_row = 0;
    }
    session->rows = rows;
    session->cols = cols;
    session->pixel_width = pixel_width;
    session->pixel_height = pixel_height;
    if (grid_changed) {
        if (resize_link_target) {
            session->screen_link_ids = resize_link_target;
            session->resize_target_link_ids = NULL;
            session->resize_target_link_cols = 0;
            session->resize_target_link_rows = 0;
        } else if (session->hyperlink_tracking) {
            ensure_screen_link_map(session);
        }
        if (session->screen_landmarks) {
            uint8_t *resized_marks = calloc((size_t)rows, sizeof(*resized_marks));
            int16_t *resized_status = calloc((size_t)rows, sizeof(*resized_status));
            if (resized_marks && resized_status) {
                size_t copy_rows = (size_t)rows < (size_t)old_rows ? (size_t)rows : (size_t)old_rows;
                memcpy(resized_marks, session->screen_landmarks, copy_rows * sizeof(*resized_marks));
                memcpy(resized_status, session->screen_landmark_status, copy_rows * sizeof(*resized_status));
                free(session->screen_landmarks); free(session->screen_landmark_status);
                session->screen_landmarks = resized_marks; session->screen_landmark_status = resized_status;
            } else { free(resized_marks); free(resized_status); }
        }
    }
    struct winsize window_size = {
        .ws_row = (unsigned short)rows,
        .ws_col = (unsigned short)cols,
        .ws_xpixel = (unsigned short)(pixel_width > USHRT_MAX ? USHRT_MAX : pixel_width),
        .ws_ypixel = (unsigned short)(pixel_height > USHRT_MAX ? USHRT_MAX : pixel_height),
    };
    if (session->master_fd >= 0) ioctl(session->master_fd, TIOCSWINSZ, &window_size);
    if (grid_changed) vterm_screen_flush_damage(session->screen);
    return true;
}

void mica_session_scroll(MicaSession *session, int lines) {
    if (!session) return;
    size_t history_lines = display_history_count(session);
    if (session->view_offset > history_lines) session->view_offset = history_lines;
    if (lines > 0) {
        size_t n = (size_t)lines;
        session->view_offset = n > history_lines - session->view_offset
            ? history_lines : session->view_offset + n;
    } else if (lines < 0) {
        size_t n = (size_t)(-(int64_t)lines);
        session->view_offset = n > session->view_offset ? 0 : session->view_offset - n;
    }
}

// Lower-cased UTF-8 text of one absolute row (0 = oldest history line, history_count = first screen row).
static size_t find_row_text(const MicaSession *session, size_t row, char *out, size_t capacity) {
    size_t length = 0;
    const MicaHistoryRow *history_row = NULL;
    if (row < session->history_count) {
        size_t slot = (session->history_start + row) % session->history_capacity;
        history_row = &session->history[slot];
    }
    for (int col = 0; col < session->cols; col++) {
        VTermScreenCell cell;
        if (history_row) {
            if ((size_t)col >= history_row->cols) {
                // Compacted suffix cells are default spaces. Preserve their searchable
                // text without constructing a full terminal cell for each column.
                size_t blanks = (size_t)(session->cols - col);
                if (blanks > capacity - length - 1) blanks = capacity - length - 1;
                memset(out + length, ' ', blanks);
                length += blanks;
                break;
            }
            cell = history_cell_at(history_row, (size_t)col);
        } else {
            vterm_screen_get_cell(session->screen, (VTermPos){ (int)(row - session->history_count), col }, &cell);
        }
        // Wide-cell continuation sentinels are layout, not text. Keep every
        // codepoint in the base cell, including combining marks and emoji joins.
        if (cell.chars[0] > 0x10ffff || (cell.width == 0 && cell.chars[0] == 0)) continue;
        for (size_t index = 0; index < VTERM_MAX_CHARS_PER_CELL; index++) {
            uint32_t ch = cell.chars[index];
            if (index > 0 && ch == 0) break;
            if (ch > 0x10ffff || (ch >= 0xd800 && ch <= 0xdfff)) continue;
            if (ch == 0) ch = ' ';
            if (ch < 0x80) { if (length + 1 >= capacity) goto finished; out[length++] = (char)((ch >= 'A' && ch <= 'Z') ? ch + 32 : ch); }
            else if (ch < 0x800) { if (length + 2 >= capacity) goto finished; out[length++] = (char)(0xC0 | (ch >> 6)); out[length++] = (char)(0x80 | (ch & 0x3F)); }
            else if (ch < 0x10000) { if (length + 3 >= capacity) goto finished; out[length++] = (char)(0xE0 | (ch >> 12)); out[length++] = (char)(0x80 | ((ch >> 6) & 0x3F)); out[length++] = (char)(0x80 | (ch & 0x3F)); }
            else { if (length + 4 >= capacity) goto finished; out[length++] = (char)(0xF0 | (ch >> 18)); out[length++] = (char)(0x80 | ((ch >> 12) & 0x3F)); out[length++] = (char)(0x80 | ((ch >> 6) & 0x3F)); out[length++] = (char)(0x80 | (ch & 0x3F)); }
        }
    }
finished:
    out[length] = '\0';
    return length;
}

static CFMutableStringRef search_fold_string(CFStringRef source, CFLocaleRef locale) {
    CFMutableStringRef folded = CFStringCreateMutableCopy(kCFAllocatorDefault, 0, source);
    if (!folded) return NULL;
    CFStringNormalize(folded, kCFStringNormalizationFormC);
    CFStringFold(folded, kCFCompareCaseInsensitive, locale);
    CFStringNormalize(folded, kCFStringNormalizationFormC);
    return folded;
}

static CFLocaleRef search_fold_locale(void) {
    return CFLocaleCreate(kCFAllocatorDefault, CFSTR("en_US_POSIX"));
}

static bool contains_non_ascii_bytes(const char *text, size_t length) {
    for (size_t index = 0; index < length; index++)
        if ((unsigned char)text[index] >= 0x80) return true;
    return false;
}

bool mica_session_find(MicaSession *session, const char *query, bool backward, long *cursor) {
    if (!session || !query || !query[0] || !cursor) return false;
    if (session->cols <= 0 || (size_t)session->cols > (SIZE_MAX - 1) / (4u * VTERM_MAX_CHARS_PER_CELL)) return false;
    size_t row_capacity = (size_t)session->cols * 4u * VTERM_MAX_CHARS_PER_CELL + 1;
    size_t query_length = strnlen(query, row_capacity);
    if (query_length >= row_capacity || query_length + 1 > SIZE_MAX - row_capacity) return false;
    bool query_is_ascii = true;
    for (size_t index = 0; index < query_length; index++)
        if ((unsigned char)query[index] >= 0x80) { query_is_ascii = false; break; }
    CFLocaleRef fold_locale = NULL;
    CFMutableStringRef folded_query = NULL;
    if (!query_is_ascii) {
        fold_locale = search_fold_locale();
        if (!fold_locale) return false;
        CFStringRef query_string = CFStringCreateWithBytes(kCFAllocatorDefault,
            (const UInt8 *)query, (CFIndex)query_length, kCFStringEncodingUTF8, false);
        if (!query_string) { CFRelease(fold_locale); return false; }
        folded_query = search_fold_string(query_string, fold_locale);
        CFRelease(query_string);
        if (!folded_query) { CFRelease(fold_locale); return false; }
    }
    char scratch[4096];
    size_t scratch_bytes = row_capacity + query_length + 1;
    char *storage = scratch_bytes <= sizeof(scratch) ? scratch : malloc(scratch_bytes);
    if (!storage) {
        if (folded_query) CFRelease(folded_query);
        if (fold_locale) CFRelease(fold_locale);
        return false;
    }
    char *text = storage;
    char *lowered = storage + row_capacity;
    for (size_t index = 0; index < query_length; index++) {
        char c = query[index];
        lowered[index] = (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c;
    }
    lowered[query_length] = '\0';
    // View offsets count display rows, which exclude folded ranges; reveal folds so the match maps exactly.
    clear_folds(session);
    long total = (long)session->history_count + session->rows;
    long start = *cursor;
    if (start < 0 || start >= total) start = backward ? total : -1;
    for (long step = 1; step <= total; step++) {
        long row = backward ? start - step : start + step;
        row = ((row % total) + total) % total;
        size_t text_length = find_row_text(session, (size_t)row, text, row_capacity);
        bool matched = false;
        if (query_is_ascii && !contains_non_ascii_bytes(text, text_length)) {
            matched = strstr(text, lowered) != NULL;
        } else {
            if (!fold_locale) fold_locale = search_fold_locale();
            if (!folded_query) {
                CFStringRef query_string = CFStringCreateWithBytes(kCFAllocatorDefault,
                    (const UInt8 *)query, (CFIndex)query_length, kCFStringEncodingUTF8, false);
                if (query_string) {
                    folded_query = fold_locale ? search_fold_string(query_string, fold_locale) : NULL;
                    CFRelease(query_string);
                }
            }
            CFStringRef row_string = CFStringCreateWithBytes(kCFAllocatorDefault,
                (const UInt8 *)text, (CFIndex)text_length, kCFStringEncodingUTF8, false);
            if (row_string && folded_query) {
                CFMutableStringRef folded_row = fold_locale ? search_fold_string(row_string, fold_locale) : NULL;
                if (folded_row) {
                    CFRange found_range = CFStringFind(folded_row, folded_query, 0);
                    matched = found_range.location != kCFNotFound;
                    CFRelease(folded_row);
                }
            }
            if (row_string) CFRelease(row_string);
        }
        if (!matched) continue;
        *cursor = row;
        // Scroll so the match sits mid-view; rows on the live screen need no scrolling.
        long from_bottom = total - 1 - row;
        long target = from_bottom < session->rows ? 0 : from_bottom - session->rows / 2;
        if (target > (long)display_history_count(session)) target = (long)display_history_count(session);
        session->view_offset = (size_t)target;
        session->revision++;
        if (storage != scratch) free(storage);
        if (folded_query) CFRelease(folded_query);
        if (fold_locale) CFRelease(fold_locale);
        return true;
    }
    if (storage != scratch) free(storage);
    if (folded_query) CFRelease(folded_query);
    if (fold_locale) CFRelease(fold_locale);
    return false;
}

void mica_session_set_light_theme(MicaSession *session, bool light) {
    if (!session) return;
    configure_terminal_colors(session, light);
    session->revision++;
}

void mica_session_clear_scrollback(MicaSession *session) {
    if (!session) return;
    history_clear(session);
    session->revision++;
}

void mica_session_scroll_to_bottom(MicaSession *session) { if (session) session->view_offset = 0; }
int mica_session_rows(const MicaSession *session) { return session ? session->rows : 0; }
int mica_session_cols(const MicaSession *session) { return session ? session->cols : 0; }
int mica_session_view_offset(const MicaSession *session) { return session ? (int)session->view_offset : 0; }
size_t mica_session_history_lines(const MicaSession *session) { return session ? session->history_count : 0; }
size_t mica_session_history_storage_bytes(const MicaSession *session) { return session ? session->history_storage_bytes : 0; }
size_t mica_session_display_history_lines(const MicaSession *session) { return display_history_count(session); }

bool mica_session_fold_visible_rows(MicaSession *session, int start_row, int end_row) {
    if (!session || start_row < 0 || end_row <= start_row || end_row >= session->rows ||
        session->fold_count >= MICA_FOLD_LIMIT)
        return false;
    size_t display_count = display_history_count(session);
    if (session->view_offset > display_count) return false;
    size_t first_display = display_count - session->view_offset + (size_t)start_row;
    size_t end_display = display_count - session->view_offset + (size_t)end_row + 1;
    if (end_display > display_count) return false;
    size_t start = history_index_for_display_row(session, first_display, NULL);
    size_t end = end_display == display_count
        ? session->history_count
        : history_index_for_display_row(session, end_display, NULL);
    if (end <= start + 1) return false;
    for (size_t i = 0; i < session->fold_count; i++)
        if (start < session->folds[i].end && end > session->folds[i].start) return false;
    if (session->fold_count == session->fold_capacity) {
        size_t next_capacity = session->fold_capacity ? session->fold_capacity * 2 : 4;
        if (next_capacity > MICA_FOLD_LIMIT) next_capacity = MICA_FOLD_LIMIT;
        MicaFold *grown = realloc(session->folds, next_capacity * sizeof(*grown));
        if (!grown) return false;
        session->folds = grown;
        session->fold_capacity = next_capacity;
    }
    size_t insert_at = 0;
    while (insert_at < session->fold_count && session->folds[insert_at].start < start) insert_at++;
    if (insert_at < session->fold_count)
        memmove(&session->folds[insert_at + 1], &session->folds[insert_at],
                (session->fold_count - insert_at) * sizeof(*session->folds));
    session->folds[insert_at] = (MicaFold){ .start = start, .end = end };
    session->fold_count++;
    size_t new_display_count = display_history_count(session);
    if (session->view_offset > new_display_count) session->view_offset = new_display_count;
    return true;
}

bool mica_session_toggle_fold_at_view_row(MicaSession *session, int row) {
    if (!session || row < 0 || row >= session->rows) return false;
    size_t display_count = display_history_count(session);
    if (session->view_offset > display_count) return false;
    size_t display_row = display_count - session->view_offset + (size_t)row;
    if (display_row >= display_count) return false;
    bool is_placeholder = false;
    size_t history_row = history_index_for_display_row(session, display_row, &is_placeholder);
    if (!is_placeholder) return false;
    for (size_t i = 0; i < session->fold_count; i++) {
        if (session->folds[i].start != history_row) continue;
        remove_fold_at(session, i);
        return true;
    }
    return false;
}

bool mica_session_fold_info_at_view_row(const MicaSession *session, int row, size_t *hidden_rows) {
    if (!session || row < 0 || row >= session->rows) return false;
    size_t display_count = display_history_count(session);
    if (session->view_offset > display_count) return false;
    size_t display_row = display_count - session->view_offset + (size_t)row;
    if (display_row >= display_count) return false;
    bool is_placeholder = false;
    size_t history_row = history_index_for_display_row(session, display_row, &is_placeholder);
    if (!is_placeholder) return false;
    for (size_t i = 0; i < session->fold_count; i++) {
        MicaFold fold = session->folds[i];
        if (fold.start != history_row) continue;
        if (hidden_rows) *hidden_rows = fold.end - fold.start - 1;
        return true;
    }
    return false;
}

bool mica_session_is_running(const MicaSession *session) { return session && session->running; }
const char *mica_session_hook_token(const MicaSession *session) { return session ? session->hook_token : NULL; }
int mica_session_exit_status(const MicaSession *session) { return session && !session->running ? session->exit_status : -1; }
uint64_t mica_session_command_completion_count(const MicaSession *session) { return session ? session->command_completion_count : 0; }
int mica_session_command_exit_status(const MicaSession *session) { return session ? session->command_exit_status : -1; }
int mica_session_osc133_state(const MicaSession *session) { return session ? session->osc133_state : 0; }
uint64_t mica_session_osc133_count(const MicaSession *session) { return session ? session->osc133_count : 0; }
uint8_t mica_session_row_landmark(const MicaSession *session, int row, int *status) {
    if (!session || row < 0 || row >= session->rows) return 0;
    size_t count = display_history_count(session);
    size_t displayed = count - (session->view_offset > count ? count : session->view_offset) + (size_t)row;
    uint8_t mark = 0; int result = 0;
    if (displayed < count && session->history_capacity) {
        size_t index = history_index_for_display_row(session, displayed, NULL);
        size_t slot = (session->history_start + index) % session->history_capacity;
        mark = session->history[slot].landmark; result = session->history[slot].landmark_status;
    } else {
        size_t live = displayed - count;
        if (live < (size_t)session->rows && session->screen_landmarks) {
            mark = session->screen_landmarks[live]; result = session->screen_landmark_status[live];
        }
    }
    if (status) *status = result;
    return mark;
}
bool mica_session_jump_prompt(MicaSession *session, int direction) {
    if (!session || !direction) return false;
    size_t count = display_history_count(session);
    size_t displayed = count - (session->view_offset > count ? count : session->view_offset) + (size_t)session->rows - 1;
    for (size_t step = 0; step < count + (size_t)session->rows; step++) {
        if (direction < 0) { if (!displayed) break; displayed--; }
        else { if (displayed + 1 >= count + (size_t)session->rows) break; displayed++; }
        uint8_t mark = 0;
        if (displayed < count && session->history_capacity) {
            size_t index = history_index_for_display_row(session, displayed, NULL);
            size_t slot = (session->history_start + index) % session->history_capacity;
            mark = session->history[slot].landmark;
        } else {
            size_t live = displayed - count;
            if (live < (size_t)session->rows && session->screen_landmarks) mark = session->screen_landmarks[live];
        }
        if (mark & MICA_LANDMARK_PROMPT) {
            size_t target_offset = count + (size_t)session->rows - 1 - displayed;
            if (target_offset > count) target_offset = count;
            session->view_offset = target_offset; session->revision++; return true;
        }
    }
    return false;
}
bool mica_session_reports_mouse(const MicaSession *session) { return session && session->mouse_mode != VTERM_PROP_MOUSE_NONE; }
bool mica_session_reports_focus(const MicaSession *session) { return session && session->focus_report; }
bool mica_session_cursor_visible(const MicaSession *session) { return session && session->cursor_visible; }
void mica_session_cursor(const MicaSession *session, int *row, int *col) {
    if (!session || !session->state) return;
    VTermPos pos = {0, 0};
    vterm_state_get_cursorpos(session->state, &pos);
    if (row) *row = pos.row;
    if (col) *col = pos.col;
}
uint64_t mica_session_revision(const MicaSession *session) { return session ? session->revision : 0; }
bool mica_session_take_dirty_rows(MicaSession *session, MicaDirtyRows *rows) {
    if (!session || !session->has_dirty_rows) return false;
    if (rows) *rows = session->dirty_rows;
    session->has_dirty_rows = false;
    session->dirty_rows = (MicaDirtyRows){0};
    return true;
}
bool mica_session_alt_screen(const MicaSession *session) { return session && session->alt_screen; }
bool mica_session_bracketed_paste(const MicaSession *session) { return session && session->bracketed_paste; }
bool mica_session_sync_output_active(const MicaSession *session) {
    return session && session->sync_output && monotonic_seconds() - session->sync_output_started < MICA_SYNC_TIMEOUT;
}
char *mica_session_take_notification(MicaSession *session) {
    if (!session || !session->notification_ready) return NULL;
    session->notification_ready = false;
    return strdup(session->notification_text);
}
char *mica_session_take_clipboard_write(MicaSession *session) {
    if (!session || !session->clipboard_ready || !session->clipboard_text) return NULL;
    session->clipboard_ready = false;
    return strdup(session->clipboard_text);
}
uint64_t mica_session_scrolled_lines(const MicaSession *session) { return session ? session->scrolled_total : 0; }
uint64_t mica_session_attention_count(const MicaSession *session) { return session ? session->attention_count : 0; }
pid_t mica_session_pid(const MicaSession *session) { return session ? session->child_pid : -1; }
bool mica_session_working_directory(const MicaSession *session, char *buffer, size_t capacity) {
    if (!session || !session->running || session->child_pid <= 0 || !buffer || capacity == 0) return false;
    struct proc_vnodepathinfo paths;
    int bytes = proc_pidinfo(session->child_pid, PROC_PIDVNODEPATHINFO, 0, &paths, sizeof(paths));
    if (bytes < (int)sizeof(paths) || paths.pvi_cdir.vip_path[0] == '\0') return false;
    size_t length = strnlen(paths.pvi_cdir.vip_path, sizeof(paths.pvi_cdir.vip_path));
    if (length == 0 || length >= capacity) return false;
    memcpy(buffer, paths.pvi_cdir.vip_path, length + 1);
    return true;
}
const char *mica_session_command(const MicaSession *session) { return session ? session->command : ""; }
const char *mica_session_title(const MicaSession *session) { return session && session->title ? session->title : ""; }
const char *mica_session_current_command(const MicaSession *session) { return session && session->current_command ? session->current_command : ""; }

bool mica_session_get_cell(const MicaSession *session, int row, int col, MicaCell *cell) {
    if (!session || !cell || row < 0 || row >= session->rows || col < 0 || col >= session->cols) return false;
    size_t visible_history_count = display_history_count(session);
    if (session->view_offset > visible_history_count) return false;
    size_t display_row = visible_history_count - session->view_offset + (size_t)row;
    VTermScreenCell source;
    if (display_row < visible_history_count) {
        if (!session->history_capacity || !session->history) return false;
        size_t history_row_index = history_index_for_display_row(session, display_row, NULL);
        size_t slot = (session->history_start + history_row_index) % session->history_capacity;
        source = history_blank_cell();
        MicaHistoryRow *history_row = &session->history[slot];
        if ((size_t)col < history_row->cols) source = history_cell_at(history_row, (size_t)col);
    } else {
        VTermPos pos = { .row = (int)(display_row - visible_history_count), .col = col };
        if (pos.row < 0 || pos.row >= session->rows || !vterm_screen_get_cell(session->screen, pos, &source))
            return false;
    }
    memcpy(cell->chars, source.chars, sizeof(cell->chars));
    cell->fg = source.fg;
    cell->bg = source.bg;
    bool default_fg = VTERM_COLOR_IS_DEFAULT_FG(&cell->fg);
    bool default_bg = VTERM_COLOR_IS_DEFAULT_BG(&cell->bg);
    convert_screen_color(session, &cell->fg);
    convert_screen_color(session, &cell->bg);
    if (default_fg) cell->fg.type |= VTERM_COLOR_DEFAULT_FG;
    if (default_bg) cell->bg.type |= VTERM_COLOR_DEFAULT_BG;
    cell->attrs = source.attrs;
    cell->width = source.width;
    cell->hyperlink_id = 0;
    if (display_row < visible_history_count) {
        size_t history_row_index = history_index_for_display_row(session, display_row, NULL);
        size_t slot = (session->history_start + history_row_index) % session->history_capacity;
        MicaHistoryRow *history_row = &session->history[slot];
        if (history_row->hyperlinks && (size_t)col < history_row->cols)
            cell->hyperlink_id = history_row->hyperlinks[col];
    } else if (session->screen_link_ids) {
        cell->hyperlink_id = session->screen_link_ids[(size_t)(display_row - visible_history_count) *
            (size_t)session->cols + (size_t)col];
    }
    return true;
}

bool mica_session_row_continues(const MicaSession *session, int row) {
    if (!session || row <= 0 || row >= session->rows) return false;
    size_t count = display_history_count(session);
    if (session->view_offset > count) return false;
    size_t displayed = count - session->view_offset + (size_t)row;
    bool placeholder = false, previous_placeholder = false;
    size_t current = displayed < count
        ? history_index_for_display_row(session, displayed, &placeholder)
        : session->history_count + displayed - count;
    size_t previous = displayed - 1 < count
        ? history_index_for_display_row(session, displayed - 1, &previous_placeholder)
        : session->history_count + displayed - 1 - count;
    if (placeholder || previous_placeholder || current != previous + 1) return false;
    if (current < session->history_count) {
        // History has not yet been reflowed to a different column width.
        // Avoid joining truncated rows into a misleading URL after narrowing.
        size_t slot = (session->history_start + current) % session->history_capacity;
        if (session->history[slot].screen_cols != (size_t)session->cols) return false;
        return session->history[slot].continuation;
    }
    if (current == session->history_count && session->alt_screen) return false;
    const VTermLineInfo *info = vterm_state_get_lineinfo(session->state,
        (int)(current - session->history_count));
    return info && info->continuation;
}

const char *mica_session_hyperlink_uri(const MicaSession *session, uint32_t hyperlink_id) {
    if (!session || hyperlink_id == 0 || hyperlink_id > session->hyperlink_count) return NULL;
    return session->hyperlink_uris[hyperlink_id - 1];
}
