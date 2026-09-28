#define _DARWIN_C_SOURCE
#include "mica.h"

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

static const uint32_t mica_ansi_palette[16] = {
    0x1e1e1e, 0xf48771, 0x90c978, 0xf5d67a,
    0x57c7ff, 0xc792ea, 0x89ddff, 0xd4d4d4,
    0x4a4a4a, 0xff5370, 0xc3e88d, 0xffcb6b,
    0x82aaff, 0xc792ea, 0x89ddff, 0xffffff,
};

typedef struct {
    size_t start;
    size_t end;
} MicaFold;

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
    uint64_t command_completion_count;
    MicaSessionOutputMetrics output_metrics;
    bool focus_report;
    VTerm *vt;
    VTermScreen *screen;
    VTermState *state;
    VTermScreenCell *history;
    size_t history_cols;
    size_t history_capacity;
    size_t history_start;
    size_t history_count;
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
};

static MicaSessionCleanupLogger cleanup_logger;

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

static void adjust_folds_after_history_push(MicaSession *session) {
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

static void configure_terminal_colors(MicaSession *session) {
    for (int index = 0; index < 16; index++) {
        uint32_t rgb = mica_ansi_palette[index];
        VTermColor color;
        vterm_color_rgb(&color, (uint8_t)(rgb >> 16), (uint8_t)(rgb >> 8), (uint8_t)rgb);
        vterm_state_set_palette_color(session->state, index, &color);
    }
    VTermColor foreground, background;
    vterm_color_rgb(&foreground, 0xd4, 0xd4, 0xd4);
    vterm_color_rgb(&background, 0x1e, 0x1e, 0x1e);
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
        title[copied++] = (char)byte;
    }
    title[copied] = '\0';
    return title;
}

static VTermScreenCell *allocate_history(size_t capacity, int cols) {
    if (capacity == 0 || cols <= 0 || capacity > SIZE_MAX / (size_t)cols ||
        capacity * (size_t)cols > SIZE_MAX / sizeof(VTermScreenCell)) return NULL;
    return calloc(capacity * (size_t)cols, sizeof(VTermScreenCell));
}

static size_t history_limit_lines(int cols) {
    if (cols <= 0 || (size_t)cols > SIZE_MAX / sizeof(VTermScreenCell)) return 0;
    size_t bytes_per_line = (size_t)cols * sizeof(VTermScreenCell);
    return MICA_HISTORY_LIMIT_BYTES / bytes_per_line;
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

static char *create_prefill_startup_dir(void) {
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
        "[[ -n $HISTFILE ]] || HISTFILE=\"$original/.zsh_history\"\n"
        "if [[ -n $MICA_INITIAL_COMMAND ]]; then\n"
        "    print -z -- \"$MICA_INITIAL_COMMAND\"\n"
        "    unset MICA_INITIAL_COMMAND\n"
        "fi\n"
        "fi\n"
        "function _mica_command_started() {\n"
        "    local mica_command=\"${1##[[:space:]]#}\"\n"
        "    mica_command=\"${mica_command#unset CLAUDECODE && }\"\n"
        "    mica_command=\"${mica_command##[[:space:]]#}\"\n"
        "    mica_command=\"${mica_command%%[[:space:]]*}\"\n"
        "    [[ -n $mica_command ]] || return\n"
        "    MICA_COMMAND_ACTIVE=1\n"
        "    printf '\\033]777;mica;command-started;%s\\033\\\\' \"$mica_command\"\n"
        "}\n"
        "function _mica_command_finished() {\n"
        "    local mica_status=$?\n"
        "    [[ $MICA_COMMAND_ACTIVE == 1 ]] || return\n"
        "    unset MICA_COMMAND_ACTIVE\n"
        "    printf '\\033]777;mica;command-finished;%d\\033\\\\' $mica_status\n"
        "}\n"
        "autoload -Uz add-zsh-hook\n"
        "add-zsh-hook preexec _mica_command_started\n"
        "add-zsh-hook precmd _mica_command_finished\n"
        "if [[ -n $MICA_TEST_ZLE_DIR ]]; then\n"
        "    function mica_test_prompt_ready() { : > \"$MICA_TEST_ZLE_DIR/$$.ready\"; }\n"
        "    function mica_test_capture_buffer() { print -r -- \"$BUFFER\" > \"$MICA_TEST_ZLE_DIR/$$.buffer\"; }\n"
        "    function mica_test_raw_transcript() { : > \"$MICA_TEST_ZLE_DIR/$$.executed\"; }\n"
        "    zle -N mica_test_capture_buffer\n"
        "    bindkey '^X^B' mica_test_capture_buffer\n"
        "    autoload -Uz add-zle-hook-widget\n"
        "    add-zle-hook-widget zle-line-init mica_test_prompt_ready\n"
        "fi\n"
        "if [[ \"$MICA_TEST_NO_STARTUP\" != 1 ]] && (( ! $+functions[compdef] )); then\n"
        "    export ZDOTDIR=\"$MICA_ORIGINAL_ZDOTDIR\"\n"
        "    autoload -Uz compinit\n"
        "    compinit -i\n"
        "    export ZDOTDIR=\"$MICA_ZSH_WRAPPER\"\n"
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

static int bell_callback(void *user) {
    MicaSession *session = user;
    if (session) session->attention_count++;
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
    if (overflow) return 1;
    static const char started_prefix[] = "mica;command-started;";
    static const char completion_prefix[] = "mica;command-finished;";
    if (session && command == 777 && fragment.final && fragment.str &&
        fragment.len > (int)(sizeof(started_prefix) - 1) &&
        memcmp(fragment.str, started_prefix, sizeof(started_prefix) - 1) == 0) {
        size_t start = sizeof(started_prefix) - 1;
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
        fragment.len > (int)(sizeof(completion_prefix) - 1) &&
        memcmp(fragment.str, completion_prefix, sizeof(completion_prefix) - 1) == 0) {
        int status = 0;
        bool valid = true;
        for (int i = (int)(sizeof(completion_prefix) - 1); i < fragment.len; i++) {
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
        if (notification) session->attention_count++;
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

static int history_push(int cols, const VTermScreenCell *cells, void *user) {
    MicaSession *session = user;
    if (!session || cols <= 0 || (size_t)cols != (size_t)session->cols) return 1;
    size_t old_display_count = display_history_count(session);
    if (session->history_cols == 0) session->history_cols = (size_t)session->cols;
    size_t limit = history_limit_lines((int)session->history_cols);
    if (session->history_count == session->history_capacity && session->history_capacity < limit) {
        size_t next_capacity = session->history_capacity ? session->history_capacity * 2 : MICA_HISTORY_INITIAL;
        if (next_capacity > limit) next_capacity = limit;
        VTermScreenCell *grown = allocate_history(next_capacity, (int)session->history_cols);
        if (grown) {
            for (size_t i = 0; i < session->history_count; i++) {
                size_t old_slot = (session->history_start + i) % session->history_capacity;
                memcpy(grown + i * session->history_cols,
                       session->history + old_slot * session->history_cols,
                       session->history_cols * sizeof(*grown));
            }
            free(session->history);
            session->history = grown;
            session->history_capacity = next_capacity;
            session->history_start = 0;
        }
    }
    if (session->history_capacity == 0) return 1;
    size_t slot;
    if (session->history_count < session->history_capacity) {
        slot = (session->history_start + session->history_count) % session->history_capacity;
        session->history_count++;
    } else {
        adjust_folds_after_history_push(session);
        slot = session->history_start;
        session->history_start = (session->history_start + 1) % session->history_capacity;
    }
    VTermScreenCell *destination = session->history + slot * session->history_cols;
    memset(destination, 0, session->history_cols * sizeof(*destination));
    memcpy(destination, cells, (size_t)session->cols * sizeof(*cells));
    size_t new_display_count = display_history_count(session);
    if (new_display_count > old_display_count && session->view_offset > 0 &&
        session->view_offset < new_display_count)
        session->view_offset++;
    if (session->view_offset > new_display_count) session->view_offset = new_display_count;
    return 1;
}

static int history_pop(int cols, VTermScreenCell *cells, void *user) {
    MicaSession *session = user;
    if (!session || session->history_count == 0 || cols != session->cols ||
        session->history_cols > (size_t)cols) return 0;
    size_t slot = (session->history_start + session->history_count - 1) % session->history_capacity;
    memcpy(cells, session->history + slot * session->history_cols,
           (size_t)session->cols * sizeof(*cells));
    session->history_count--;
    adjust_folds_after_history_pop(session);
    if (session->history_count == 0) session->history_start = 0;
    size_t display_count = display_history_count(session);
    if (session->view_offset > display_count) session->view_offset = display_count;
    return 1;
}

static int history_clear(void *user) {
    MicaSession *session = user;
    if (!session) return 1;
    free(session->history);
    session->history = NULL;
    session->history_capacity = 0;
    session->history_cols = 0;
    session->history_start = 0;
    session->history_count = 0;
    session->view_offset = 0;
    clear_folds(session);
    return 1;
}

static const VTermScreenCallbacks screen_callbacks = {
    .damage = damage_callback,
    .movecursor = cursor_callback,
    .settermprop = property_callback,
    .bell = bell_callback,
    .sb_pushline = history_push,
    .sb_popline = history_pop,
    .sb_clear = history_clear,
};

static bool change_to_requested_directory(const char *requested) {
    if (!requested || !requested[0] || chdir(requested) == 0) return true;
    int original_error = errno;
    char *candidate = strdup(requested);
    if (!candidate) {
        dprintf(STDERR_FILENO, "mica: could not resolve the requested folder; using the home folder\r\n");
        candidate = strdup("");
    }

    while (candidate && candidate[0]) {
        size_t length;
        length = strlen(candidate);
        while (length > 1 && candidate[length - 1] == '/') candidate[--length] = '\0';
        char *separator = strrchr(candidate, '/');
        if (!separator) {
            candidate[0] = '.';
            candidate[1] = '\0';
        } else if (separator == candidate) {
            candidate[1] = '\0';
        } else {
            *separator = '\0';
        }

        if (chdir(candidate) == 0) {
            char resolved[PATH_MAX];
            const char *fallback = getcwd(resolved, sizeof(resolved)) ? resolved : candidate;
            dprintf(STDERR_FILENO, "mica: cannot enter %s: %s; using %s\r\n",
                    requested, strerror(original_error), fallback);
            free(candidate);
            return true;
        }
        if (strcmp(candidate, ".") == 0 || strcmp(candidate, "/") == 0) break;
    }
    free(candidate);

    const char *home = getenv("HOME");
    if (home && home[0] && chdir(home) == 0) {
        dprintf(STDERR_FILENO, "mica: cannot enter %s: %s; using %s\r\n",
                requested, strerror(original_error), home);
        return true;
    }
    dprintf(STDERR_FILENO, "mica: cannot enter %s or a parent folder: %s\r\n",
            requested, strerror(original_error));
    return false;
}

static const VTermStateFallbacks screen_fallbacks = { .osc = notification_osc };

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
    session->command = command ? strdup(command) : strdup("/bin/zsh -l -i");
    session->startup_dir = create_prefill_startup_dir();
    session->vt = vterm_new(rows, cols);
    if (!session->command || !session->vt || (prefilled && command && !session->startup_dir)) goto fail;

    vterm_set_utf8(session->vt, 1);
    session->state = vterm_obtain_state(session->vt);
    session->screen = vterm_obtain_screen(session->vt);
    vterm_screen_set_callbacks(session->screen, &screen_callbacks, session);
    vterm_screen_set_unrecognised_fallbacks(session->screen, &screen_fallbacks, session);
    vterm_screen_set_damage_merge(session->screen, VTERM_DAMAGE_ROW);
    vterm_screen_enable_reflow(session->screen, true);
    vterm_screen_enable_altscreen(session->screen, 1);
    vterm_output_set_callback(session->vt, output_callback, session);
    vterm_screen_reset(session->screen, 1);
    configure_terminal_colors(session);
    vterm_input_write(session->vt, "\x1b[0m", 4);

    struct winsize window_size = { .ws_row = (unsigned short)rows, .ws_col = (unsigned short)cols };
    int master = -1;
    pid_t pid = forkpty(&master, NULL, NULL, &window_size);
    if (pid < 0) goto fail;
    if (pid == 0) {
        struct termios terminal_settings;
        if (tcgetattr(STDIN_FILENO, &terminal_settings) == 0) {
            terminal_settings.c_iflag &= (tcflag_t)~(IXON | IXOFF);
            (void)tcsetattr(STDIN_FILENO, TCSANOW, &terminal_settings);
        }
        if (!change_to_requested_directory(cwd)) _exit(126);
        setenv("TERM", "xterm-256color", 1);
        setenv("COLORTERM", "truecolor", 1);
        setenv("TERM_PROGRAM", "Mica", 1);
        setenv("TERM_PROGRAM_VERSION", MICA_VERSION, 1);
        setenv("TERM_PROGRAM_REVISION", MICA_REVISION, 1);
        setenv("CLICOLOR", "1", 1);
        // GUI launchers can inherit NO_COLOR from an unrelated parent shell.
        // Mica advertises a color-capable xterm-256color terminal.
        unsetenv("NO_COLOR");
        if (session->startup_dir) {
            const char *original_zdotdir = getenv("MICA_ORIGINAL_ZDOTDIR");
            if (!original_zdotdir || !original_zdotdir[0]) original_zdotdir = getenv("ZDOTDIR");
            if (!original_zdotdir || !original_zdotdir[0]) original_zdotdir = getenv("HOME");
            if (!original_zdotdir || !original_zdotdir[0]) original_zdotdir = ".";
            setenv("MICA_ORIGINAL_ZDOTDIR", original_zdotdir, 1);
            setenv("MICA_ZSH_WRAPPER", session->startup_dir, 1);
            setenv("ZDOTDIR", session->startup_dir, 1);
            if (prefilled && command) {
                setenv("MICA_INITIAL_COMMAND", command, 1);
                execl("/bin/zsh", "zsh", "-l", "-i", (char *)NULL);
            }
        }
        const char *test_mode = getenv("MICA_TEST_NO_STARTUP");
        bool skip_user_startup = test_mode && strcmp(test_mode, "1") == 0;
        // Some UI tests need Mica's temporary ZDOTDIR wrapper to install a
        // ZLE probe, while still suppressing every user startup file.
        bool test_zle_probe = skip_user_startup && getenv("MICA_TEST_ZLE_DIR") != NULL;
        if (command) {
            if (skip_user_startup && !test_zle_probe) {
                execl("/bin/zsh", "zsh", "-f", "-i", "-c",
                      "mica_command=$1; mica_label=${mica_command#unset CLAUDECODE && }; mica_label=${mica_label##[[:space:]]#}; mica_label=${mica_label%%[[:space:]]*}; printf '\\033]777;mica;command-started;%s\\033\\\\' \"$mica_label\"; eval \"$mica_command\"; mica_status=$?; printf '\\n[command exited: %d]\\n' \"$mica_status\"; printf '\\033]777;mica;command-finished;%d\\033\\\\' \"$mica_status\"; exec /bin/zsh -f -i",
                      "mica", command, (char *)NULL);
            } else {
                execl("/bin/zsh", "zsh", "-l", "-i", "-c",
                      "mica_command=$1; mica_label=${mica_command#unset CLAUDECODE && }; mica_label=${mica_label##[[:space:]]#}; mica_label=${mica_label%%[[:space:]]*}; printf '\\033]777;mica;command-started;%s\\033\\\\' \"$mica_label\"; eval \"$mica_command\"; mica_status=$?; printf '\\n[command exited: %d]\\n' \"$mica_status\"; printf '\\033]777;mica;command-finished;%d\\033\\\\' \"$mica_status\"; exec /bin/zsh -l -i",
                      "mica", command, (char *)NULL);
            }
        } else {
            if (skip_user_startup && !test_zle_probe) execl("/bin/zsh", "zsh", "-f", "-i", (char *)NULL);
            else execl("/bin/zsh", "zsh", "-l", "-i", (char *)NULL);
        }
        dprintf(STDERR_FILENO, "mica: cannot start zsh: %s\r\n", strerror(errno));
        _exit(127);
    }
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
    free(session->history);
    clear_folds(session);
    clear_pending_input(session);
    free(session->command);
    free(session->current_command);
    free(session->title);
    remove_prefill_startup_dir(session->startup_dir);
    cleanup_stage_end(pid, "release_session_resources", release_started);
    free(session);
}

int mica_session_poll(MicaSession *session, int timeout_ms) {
    if (!session) return -1;
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
                    vterm_input_write(session->vt, buffer, (size_t)n);
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
        }
    }
    return 0;
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
        if ((unsigned char)utf8[index] != 0x1b) safe[safe_length++] = utf8[index];
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

void mica_session_resize(MicaSession *session, int rows, int cols) {
    if (!session) return;
    mica_session_resize_pixels(session, rows, cols, session->pixel_width, session->pixel_height);
}

void mica_session_resize_pixels(MicaSession *session, int rows, int cols, int pixel_width, int pixel_height) {
    if (!session || rows < 1 || cols < 1 || pixel_width < 0 || pixel_height < 0) return;
    bool grid_changed = rows != session->rows || cols != session->cols;
    bool pixels_changed = pixel_width != session->pixel_width || pixel_height != session->pixel_height;
    if (!grid_changed && !pixels_changed) return;
    if (grid_changed) {
        clear_folds(session);
        if (session->view_offset > session->history_count)
            session->view_offset = session->history_count;
    }
    if ((size_t)cols > session->history_cols) {
        size_t capacity = session->history_capacity;
        size_t limit = history_limit_lines(cols);
        if (capacity > limit) capacity = limit;
        VTermScreenCell *new_history = capacity ? allocate_history(capacity, cols) : NULL;
        if (capacity && !new_history) return;
        size_t kept = session->history_count;
        if (kept > capacity) kept = capacity;
        size_t skip = session->history_count - kept;
        size_t copy_cols = (size_t)cols < session->history_cols
            ? (size_t)cols : session->history_cols;
        for (size_t i = 0; i < kept; i++) {
            size_t old_slot = (session->history_start + skip + i) % session->history_capacity;
            memcpy(new_history + i * (size_t)cols,
                   session->history + old_slot * session->history_cols,
                   copy_cols * sizeof(*new_history));
        }
        free(session->history);
        session->history = new_history;
        session->history_capacity = capacity;
        session->history_cols = (size_t)cols;
        session->history_count = kept;
        session->history_start = 0;
        if (session->view_offset > kept) session->view_offset = kept;
    }
    session->rows = rows;
    session->cols = cols;
    session->pixel_width = pixel_width;
    session->pixel_height = pixel_height;
    if (grid_changed) vterm_set_size(session->vt, rows, cols);
    struct winsize window_size = {
        .ws_row = (unsigned short)rows,
        .ws_col = (unsigned short)cols,
        .ws_xpixel = (unsigned short)(pixel_width > USHRT_MAX ? USHRT_MAX : pixel_width),
        .ws_ypixel = (unsigned short)(pixel_height > USHRT_MAX ? USHRT_MAX : pixel_height),
    };
    if (session->master_fd >= 0) ioctl(session->master_fd, TIOCSWINSZ, &window_size);
    if (grid_changed) vterm_screen_flush_damage(session->screen);
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

void mica_session_scroll_to_bottom(MicaSession *session) { if (session) session->view_offset = 0; }
int mica_session_rows(const MicaSession *session) { return session ? session->rows : 0; }
int mica_session_cols(const MicaSession *session) { return session ? session->cols : 0; }
int mica_session_view_offset(const MicaSession *session) { return session ? (int)session->view_offset : 0; }
size_t mica_session_history_lines(const MicaSession *session) { return session ? session->history_count : 0; }
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
int mica_session_exit_status(const MicaSession *session) { return session && !session->running ? session->exit_status : -1; }
uint64_t mica_session_command_completion_count(const MicaSession *session) { return session ? session->command_completion_count : 0; }
int mica_session_command_exit_status(const MicaSession *session) { return session ? session->command_exit_status : -1; }
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
uint64_t mica_session_attention_count(const MicaSession *session) { return session ? session->attention_count : 0; }
pid_t mica_session_pid(const MicaSession *session) { return session ? session->child_pid : -1; }
bool mica_session_working_directory(const MicaSession *session, char *buffer, size_t capacity) {
    if (!session || session->child_pid <= 0 || !buffer || capacity == 0) return false;
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
        size_t history_row = history_index_for_display_row(session, display_row, NULL);
        size_t slot = (session->history_start + history_row) % session->history_capacity;
        memset(&source, 0, sizeof(source));
        if ((size_t)col < session->history_cols)
            source = session->history[slot * session->history_cols + (size_t)col];
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
    return true;
}
