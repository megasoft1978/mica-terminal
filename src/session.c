#define _DARWIN_C_SOURCE
#include "mica.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

#define MICA_HISTORY_INITIAL 32
#define MICA_READ_BUFFER 16384
#define MICA_TITLE_MAX_BYTES 512

static const uint32_t mica_ansi_palette[16] = {
    0x1e1e1e, 0xf48771, 0x90c978, 0xf5d67a,
    0x57c7ff, 0xc792ea, 0x89ddff, 0xd4d4d4,
    0x4a4a4a, 0xff5370, 0xc3e88d, 0xffcb6b,
    0x82aaff, 0xc792ea, 0x89ddff, 0xffffff,
};

struct MicaSession {
    int master_fd;
    pid_t child_pid;
    int rows;
    int cols;
    int pixel_width;
    int pixel_height;
    bool running;
    bool cursor_visible;
    int mouse_mode;
    int exit_status;
    uint64_t revision;
    uint64_t attention_count;
    bool focus_report;
    VTerm *vt;
    VTermScreen *screen;
    VTermState *state;
    VTermScreenCell *history;
    size_t history_capacity;
    size_t history_start;
    size_t history_count;
    size_t view_offset;
    char *pending_input;
    size_t pending_input_offset;
    size_t pending_input_length;
    size_t pending_input_capacity;
    char *command;
    char *title;
    char *startup_dir;
};

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
        "original=\"$MICA_ORIGINAL_ZDOTDIR\"\n"
        "export ZDOTDIR=\"$original\"\n"
        "[[ -r \"$original/.zshenv\" ]] && source \"$original/.zshenv\"\n"
        "export ZDOTDIR=\"$MICA_ZSH_WRAPPER\"\n";
    static const char profile[] =
        "original=\"$MICA_ORIGINAL_ZDOTDIR\"\n"
        "export ZDOTDIR=\"$original\"\n"
        "[[ -r \"$original/.zprofile\" ]] && source \"$original/.zprofile\"\n"
        "export ZDOTDIR=\"$MICA_ZSH_WRAPPER\"\n";
    static const char interactive[] =
        "original=\"$MICA_ORIGINAL_ZDOTDIR\"\n"
        "export ZDOTDIR=\"$original\"\n"
        "[[ -r \"$original/.zshrc\" ]] && source \"$original/.zshrc\"\n"
        "export ZDOTDIR=\"$MICA_ZSH_WRAPPER\"\n"
        "[[ -n $HISTFILE ]] || HISTFILE=\"$original/.zsh_history\"\n"
        "if [[ -n $MICA_INITIAL_COMMAND ]]; then\n"
        "    print -z -- \"$MICA_INITIAL_COMMAND\"\n"
        "    unset MICA_INITIAL_COMMAND\n"
        "fi\n";
    static const char login[] =
        "original=\"$MICA_ORIGINAL_ZDOTDIR\"\n"
        "export ZDOTDIR=\"$original\"\n"
        "[[ -r \"$original/.zlogin\" ]] && source \"$original/.zlogin\"\n"
        "export ZDOTDIR=\"$MICA_ZSH_WRAPPER\"\n";
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
    (void)rect;
    MicaSession *session = user;
    if (session) session->revision++;
    return 1;
}

static int property_callback(VTermProp prop, VTermValue *value, void *user) {
    MicaSession *session = user;
    if (!session || !value) return 1;
    if (prop == VTERM_PROP_CURSORVISIBLE) session->cursor_visible = value->boolean != 0;
    if (prop == VTERM_PROP_MOUSE) session->mouse_mode = value->number;
    if (prop == VTERM_PROP_FOCUSREPORT) session->focus_report = value->boolean != 0;
    if (prop == VTERM_PROP_TITLE) {
        char *title = copy_title(value->string);
        if (title) {
            if (!session->title || strcmp(session->title, title) != 0) {
                free(session->title);
                session->title = title;
            } else {
                free(title);
            }
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
    if (session->pending_input_offset > 0 && queued > 0)
        memmove(session->pending_input, session->pending_input + session->pending_input_offset, queued);
    session->pending_input_offset = 0;
    session->pending_input_length = queued;
    if (length > SIZE_MAX - queued) return;
    size_t needed = queued + length;
    if (needed > session->pending_input_capacity) {
        size_t capacity = session->pending_input_capacity ? session->pending_input_capacity : 4096;
        while (capacity < needed) {
            if (capacity > SIZE_MAX / 2) { capacity = needed; break; }
            capacity *= 2;
        }
        char *grown = realloc(session->pending_input, capacity);
        if (!grown) return;
        session->pending_input = grown;
        session->pending_input_capacity = capacity;
    }
    memcpy(session->pending_input + queued, bytes, length);
    session->pending_input_length = needed;
}

static void output_callback(const char *bytes, size_t length, void *user) {
    MicaSession *session = user;
    write_nonblocking(session, bytes, length);
}

static int history_push(int cols, const VTermScreenCell *cells, void *user) {
    MicaSession *session = user;
    if (!session || cols <= 0 || (size_t)cols != (size_t)session->cols) return 1;
    size_t limit = history_limit_lines(session->cols);
    if (session->history_count == session->history_capacity && session->history_capacity < limit) {
        size_t next_capacity = session->history_capacity ? session->history_capacity * 2 : MICA_HISTORY_INITIAL;
        if (next_capacity > limit) next_capacity = limit;
        VTermScreenCell *grown = allocate_history(next_capacity, session->cols);
        if (grown) {
            for (size_t i = 0; i < session->history_count; i++) {
                size_t old_slot = (session->history_start + i) % session->history_capacity;
                memcpy(grown + i * (size_t)session->cols,
                       session->history + old_slot * (size_t)session->cols,
                       (size_t)session->cols * sizeof(*grown));
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
        slot = session->history_start;
        session->history_start = (session->history_start + 1) % session->history_capacity;
    }
    memcpy(session->history + slot * (size_t)session->cols, cells,
           (size_t)session->cols * sizeof(*cells));
    if (session->view_offset > 0 && session->view_offset < session->history_count)
        session->view_offset++;
    if (session->view_offset > session->history_count) session->view_offset = session->history_count;
    return 1;
}

static int history_pop(int cols, VTermScreenCell *cells, void *user) {
    MicaSession *session = user;
    if (!session || session->history_count == 0 || cols != session->cols) return 0;
    size_t slot = (session->history_start + session->history_count - 1) % session->history_capacity;
    memcpy(cells, session->history + slot * (size_t)session->cols,
           (size_t)session->cols * sizeof(*cells));
    session->history_count--;
    if (session->history_count == 0) session->history_start = 0;
    return 1;
}

static int history_clear(void *user) {
    MicaSession *session = user;
    if (!session) return 1;
    free(session->history);
    session->history = NULL;
    session->history_capacity = 0;
    session->history_start = 0;
    session->history_count = 0;
    session->view_offset = 0;
    return 1;
}

static const VTermScreenCallbacks screen_callbacks = {
    .damage = damage_callback,
    .settermprop = property_callback,
    .bell = bell_callback,
    .sb_pushline = history_push,
    .sb_popline = history_pop,
    .sb_clear = history_clear,
};

static const VTermStateFallbacks screen_fallbacks = { .osc = notification_osc };

static MicaSession *session_create(const char *cwd, const char *command, int rows, int cols,
                                   bool prefilled) {
    if (rows < 1 || cols < 1) return NULL;
    MicaSession *session = calloc(1, sizeof(*session));
    if (!session) return NULL;
    session->master_fd = -1;
    session->child_pid = -1;
    session->rows = rows;
    session->cols = cols;
    session->running = true;
    session->command = command ? strdup(command) : strdup("/bin/zsh -l");
    if (prefilled && command) session->startup_dir = create_prefill_startup_dir();
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
        if (cwd && cwd[0] && chdir(cwd) != 0) {
            dprintf(STDERR_FILENO, "mica: cannot enter %s: %s\r\n", cwd, strerror(errno));
            _exit(126);
        }
        setenv("TERM", "xterm-256color", 1);
        setenv("COLORTERM", "truecolor", 1);
        setenv("TERM_PROGRAM", "Mica", 1);
        setenv("TERM_PROGRAM_VERSION", "0.1.0", 1);
        setenv("CLICOLOR", "1", 1);
        if (session->startup_dir) {
            const char *original_zdotdir = getenv("ZDOTDIR");
            if (!original_zdotdir || !original_zdotdir[0]) original_zdotdir = getenv("HOME");
            if (!original_zdotdir || !original_zdotdir[0]) original_zdotdir = ".";
            setenv("MICA_ORIGINAL_ZDOTDIR", original_zdotdir, 1);
            setenv("MICA_ZSH_WRAPPER", session->startup_dir, 1);
            setenv("MICA_INITIAL_COMMAND", command, 1);
            setenv("ZDOTDIR", session->startup_dir, 1);
            execl("/bin/zsh", "zsh", "-l", "-i", (char *)NULL);
        }
        if (command) {
            setenv("MICA_INITIAL_COMMAND", command, 1);
            const char *test_mode = getenv("MICA_TEST_NO_STARTUP");
            if (test_mode && strcmp(test_mode, "1") == 0) {
                execl("/bin/zsh", "zsh", "-f", "-i", "-c",
                      "eval \"$MICA_INITIAL_COMMAND\"; mica_status=$?; printf '\\n[command exited: %d]\\n' $mica_status; exec /bin/zsh -f -i",
                      (char *)NULL);
            } else {
                execl("/bin/zsh", "zsh", "-l", "-i", "-c",
                      "eval \"$MICA_INITIAL_COMMAND\"; mica_status=$?; printf '\\n[command exited: %d]\\n' $mica_status; exec /bin/zsh -l -i",
                      (char *)NULL);
            }
        } else {
            const char *test_mode = getenv("MICA_TEST_NO_STARTUP");
            if (test_mode && strcmp(test_mode, "1") == 0) execl("/bin/zsh", "zsh", "-f", "-i", (char *)NULL);
            else execl("/bin/zsh", "zsh", "-l", "-i", (char *)NULL);
        }
        dprintf(STDERR_FILENO, "mica: cannot start zsh: %s\r\n", strerror(errno));
        _exit(127);
    }
    session->master_fd = master;
    session->child_pid = pid;
    int flags = fcntl(master, F_GETFL, 0);
    if (flags >= 0) fcntl(master, F_SETFL, flags | O_NONBLOCK);
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
    if (session->master_fd >= 0) close(session->master_fd);
    if (session->child_pid > 0 && session->running) {
        kill(-session->child_pid, SIGHUP);
        kill(session->child_pid, SIGHUP);
        int status;
        for (int attempt = 0; attempt < 40; attempt++) {
            pid_t result = waitpid(session->child_pid, &status, WNOHANG);
            if (result == session->child_pid || (result < 0 && errno == ECHILD)) break;
            struct timespec pause = { .tv_sec = 0, .tv_nsec = 5000000 };
            nanosleep(&pause, NULL);
        }
        if (waitpid(session->child_pid, &status, WNOHANG) == 0) {
            kill(-session->child_pid, SIGKILL);
            kill(session->child_pid, SIGKILL);
            (void)waitpid(session->child_pid, &status, 0);
        }
    }
    if (session->vt) vterm_free(session->vt);
    free(session->history);
    clear_pending_input(session);
    free(session->command);
    free(session->title);
    remove_prefill_startup_dir(session->startup_dir);
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
            for (;;) {
                ssize_t n = read(session->master_fd, buffer, sizeof(buffer));
                if (n > 0) {
                    vterm_input_write(session->vt, buffer, (size_t)n);
                    vterm_screen_flush_damage(session->screen);
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

void mica_session_write(MicaSession *session, const void *bytes, size_t length) {
    write_nonblocking(session, bytes, length);
}

void mica_session_key(MicaSession *session, VTermKey key, VTermModifier modifiers) {
    if (!session || !session->vt || !session->running) return;
    /* Match the user's Alacritty binding used by Claude Code for multiline input. */
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
    vterm_keyboard_start_paste(session->vt);
    write_nonblocking(session, utf8, length);
    vterm_keyboard_end_paste(session->vt);
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
    if (cols != session->cols) {
        size_t capacity = session->history_capacity;
        size_t limit = history_limit_lines(cols);
        if (capacity > limit) capacity = limit;
        VTermScreenCell *new_history = capacity ? allocate_history(capacity, cols) : NULL;
        if (capacity && !new_history) return;
        size_t kept = session->history_count;
        if (kept > capacity) kept = capacity;
        size_t skip = session->history_count - kept;
        size_t copy_cols = (size_t)(cols < session->cols ? cols : session->cols);
        for (size_t i = 0; i < kept; i++) {
            size_t old_slot = (session->history_start + skip + i) % session->history_capacity;
            memcpy(new_history + i * (size_t)cols,
                   session->history + old_slot * (size_t)session->cols,
                   copy_cols * sizeof(*new_history));
        }
        free(session->history);
        session->history = new_history;
        session->history_capacity = capacity;
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
    if (lines > 0) {
        size_t n = (size_t)lines;
        session->view_offset = n > session->history_count - session->view_offset
            ? session->history_count : session->view_offset + n;
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
bool mica_session_is_running(const MicaSession *session) { return session && session->running; }
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
uint64_t mica_session_attention_count(const MicaSession *session) { return session ? session->attention_count : 0; }
pid_t mica_session_pid(const MicaSession *session) { return session ? session->child_pid : -1; }
const char *mica_session_command(const MicaSession *session) { return session ? session->command : ""; }
const char *mica_session_title(const MicaSession *session) { return session && session->title ? session->title : ""; }

bool mica_session_get_cell(const MicaSession *session, int row, int col, MicaCell *cell) {
    if (!session || !cell || row < 0 || row >= session->rows || col < 0 || col >= session->cols) return false;
    size_t virtual_row = session->history_count - session->view_offset + (size_t)row;
    VTermScreenCell source;
    if (virtual_row < session->history_count) {
        if (!session->history_capacity || !session->history) return false;
        size_t slot = (session->history_start + virtual_row) % session->history_capacity;
        source = session->history[slot * (size_t)session->cols + (size_t)col];
    } else {
        VTermPos pos = { .row = (int)(virtual_row - session->history_count), .col = col };
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
