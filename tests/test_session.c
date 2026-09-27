#define _DARWIN_C_SOURCE
#include "mica.h"

#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static bool screen_contains(MicaSession *session, const char *needle) {
    char row_text[2048];
    int rows = mica_session_rows(session), cols = mica_session_cols(session);
    for (int row = 0; row < rows; row++) {
        size_t length = 0;
        for (int col = 0; col < cols && length + VTERM_MAX_CHARS_PER_CELL < sizeof(row_text); col++) {
            MicaCell cell;
            if (!mica_session_get_cell(session, row, col, &cell)) continue;
            for (size_t i = 0; i < VTERM_MAX_CHARS_PER_CELL && cell.chars[i]; i++) {
                uint32_t ch = cell.chars[i];
                row_text[length++] = ch < 128 ? (char)ch : '?';
            }
        }
        row_text[length] = '\0';
        if (strstr(row_text, needle)) return true;
    }
    return false;
}

static void print_screen(MicaSession *session) {
    for (int row = 0; row < mica_session_rows(session); row++) {
        for (int col = 0; col < mica_session_cols(session); col++) {
            MicaCell cell;
            if (!mica_session_get_cell(session, row, col, &cell)) continue;
            for (size_t i = 0; i < VTERM_MAX_CHARS_PER_CELL && cell.chars[i]; i++)
                fputc(cell.chars[i] < 128 ? (int)cell.chars[i] : '?', stderr);
        }
        fputc('\n', stderr);
    }
}

static bool find_cell_starting_with(MicaSession *session, uint32_t codepoint, MicaCell *found) {
    for (int row = 0; row < mica_session_rows(session); row++) {
        for (int col = 0; col < mica_session_cols(session); col++) {
            MicaCell cell;
            if (mica_session_get_cell(session, row, col, &cell) && cell.chars[0] == codepoint) {
                if (found) *found = cell;
                return true;
            }
        }
    }
    return false;
}

static bool screen_has_codepoint(MicaSession *session, uint32_t codepoint) {
    for (int row = 0; row < mica_session_rows(session); row++) {
        for (int col = 0; col < mica_session_cols(session); col++) {
            MicaCell cell;
            if (!mica_session_get_cell(session, row, col, &cell)) continue;
            for (size_t i = 0; i < VTERM_MAX_CHARS_PER_CELL && cell.chars[i]; i++)
                if (cell.chars[i] == codepoint) return true;
        }
    }
    return false;
}

static void poll_for(MicaSession *session, unsigned milliseconds) {
    for (unsigned elapsed = 0; elapsed < milliseconds; elapsed += 10) {
        mica_session_poll(session, 10);
    }
}

static void write_test_file(const char *path, const char *contents, mode_t mode) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, mode);
    assert(fd >= 0);
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
            assert(!"could not write test fixture");
        }
    }
    assert(close(fd) == 0);
}

static char *copy_env(const char *name) {
    const char *value = getenv(name);
    return value ? strdup(value) : NULL;
}

static void restore_env(const char *name, char *value) {
    if (value) {
        assert(setenv(name, value, 1) == 0);
        free(value);
    } else {
        assert(unsetenv(name) == 0);
    }
}

static void test_clean_zsh_completion(void) {
    char profile_template[] = "/tmp/mica-default-completion-XXXXXX";
    char *profile_dir = mkdtemp(profile_template);
    assert(profile_dir != NULL);
    char login_path[PATH_MAX], rc_path[PATH_MAX], dump_path[PATH_MAX];
    char dump_compiled_path[PATH_MAX], history_path[PATH_MAX];
    assert(snprintf(login_path, sizeof(login_path), "%s/.zlogin", profile_dir) > 0);
    assert(snprintf(rc_path, sizeof(rc_path), "%s/.zshrc", profile_dir) > 0);
    assert(snprintf(dump_path, sizeof(dump_path), "%s/.zcompdump", profile_dir) > 0);
    assert(snprintf(dump_compiled_path, sizeof(dump_compiled_path), "%s/.zcompdump.zwc", profile_dir) > 0);
    assert(snprintf(history_path, sizeof(history_path), "%s/.zsh_history", profile_dir) > 0);
    write_test_file(login_path, "print -r -- MICA-ZSH-STARTUP-COMPLETE\n", 0600);

    char *saved_home = copy_env("HOME");
    char *saved_zdotdir = copy_env("ZDOTDIR");
    char *saved_original_zdotdir = copy_env("MICA_ORIGINAL_ZDOTDIR");
    char *saved_wrapper = copy_env("MICA_ZSH_WRAPPER");
    char *saved_test_mode = copy_env("MICA_TEST_NO_STARTUP");
    assert(setenv("HOME", profile_dir, 1) == 0);
    assert(setenv("ZDOTDIR", profile_dir, 1) == 0);
    assert(unsetenv("MICA_ORIGINAL_ZDOTDIR") == 0);
    assert(unsetenv("MICA_ZSH_WRAPPER") == 0);
    assert(setenv("MICA_TEST_NO_STARTUP", "0", 1) == 0);

    for (int launch = 0; launch < 2; launch++) {
        MicaSession *session = mica_session_create("/tmp", NULL, 8, 120);
        assert(session != NULL);
        for (int attempt = 0; attempt < 500 &&
             !screen_contains(session, "MICA-ZSH-STARTUP-COMPLETE"); attempt++)
            mica_session_poll(session, 10);
        assert(screen_contains(session, "MICA-ZSH-STARTUP-COMPLETE"));
        mica_session_write(session, "git stat", strlen("git stat"));
        mica_session_key(session, VTERM_KEY_TAB, VTERM_MOD_NONE);
        for (int attempt = 0; attempt < 300 && !screen_contains(session, "git status"); attempt++)
            mica_session_poll(session, 10);
        assert(screen_contains(session, "git status"));
        if (launch == 0) assert(access(dump_path, F_OK) == 0);
        mica_session_write(session, "\003", 1);
        mica_session_destroy(session);
    }

    assert(access(rc_path, F_OK) != 0);
    restore_env("HOME", saved_home);
    restore_env("ZDOTDIR", saved_zdotdir);
    restore_env("MICA_ORIGINAL_ZDOTDIR", saved_original_zdotdir);
    restore_env("MICA_ZSH_WRAPPER", saved_wrapper);
    restore_env("MICA_TEST_NO_STARTUP", saved_test_mode);
    unlink(login_path);
    unlink(dump_path);
    unlink(dump_compiled_path);
    unlink(history_path);
    assert(rmdir(profile_dir) == 0);
    puts("clean zsh profiles get built-in Tab completion from a persistent compinit cache");
}

int main(void) {
    setenv("MICA_TEST_NO_STARTUP", "1", 1);
    MicaSession *cwd_session = mica_session_create("/tmp", "cd /; sleep 2", 6, 80);
    assert(cwd_session != NULL);
    char working_directory[PATH_MAX];
    bool found_working_directory = false;
    for (int attempt = 0; attempt < 120; attempt++) {
        mica_session_poll(cwd_session, 10);
        if (mica_session_working_directory(cwd_session, working_directory, sizeof(working_directory)) &&
            strcmp(working_directory, "/") == 0) {
            found_working_directory = true;
            break;
        }
    }
    assert(found_working_directory);
    assert(!mica_session_working_directory(cwd_session, working_directory, 1));
    assert(!mica_session_working_directory(NULL, working_directory, sizeof(working_directory)));
    mica_session_destroy(cwd_session);

    MicaSession *session = mica_session_create("/tmp", "i=1; while [ $i -le 20 ]; do printf 'row-%02d\\n' $i; i=$((i+1)); done; printf '\\033[31mRED-TEXT\\033[0m\\n'; printf '\\033[?1049h\\033[?1000hALT-BUFFER'; printf '\\007'; printf '\\033]9;Codex done\\007'; printf '\\033]9;4;1;42\\007'; printf '\\033]777;notify;Claude;Needs input\\033\\\\'; sleep 1; printf '\\033[?1000l\\033[?1049l'; printf '\\033[0m'; printf 'DEFAULT-CHECK\\n'", 6, 32);
    assert(session != NULL);
    for (int i = 0; i < 500 && (!screen_contains(session, "ALT-BUFFER") || mica_session_attention_count(session) < 3); i++) mica_session_poll(session, 10);

    assert(mica_session_rows(session) == 6);
    assert(mica_session_cols(session) == 32);
    assert(mica_session_history_lines(session) >= 10);
    assert(screen_contains(session, "ALT-BUFFER"));
    assert(mica_session_reports_mouse(session));
    assert(mica_session_attention_count(session) == 3);
    mica_session_scroll(session, 4);
    assert(mica_session_view_offset(session) == 4);
    assert(screen_contains(session, "row-"));
    mica_session_scroll(session, INT_MIN);
    assert(mica_session_view_offset(session) == 0);
    mica_session_scroll(session, 4);
    mica_session_scroll_to_bottom(session);
    assert(mica_session_view_offset(session) == 0);

    for (int i = 0; i < 500 &&
         (mica_session_reports_mouse(session) || !screen_contains(session, "DEFAULT-CHECK")); i++)
        mica_session_poll(session, 10);
    assert(!mica_session_reports_mouse(session));
    assert(screen_contains(session, "DEFAULT-CHECK"));
    assert(screen_contains(session, "row-20"));
    assert(screen_contains(session, "RED-TEXT"));
    MicaCell default_cell;
    assert(find_cell_starting_with(session, 'r', &default_cell));
    assert(VTERM_COLOR_IS_DEFAULT_FG(&default_cell.fg));
    assert(VTERM_COLOR_IS_DEFAULT_BG(&default_cell.bg));
    assert(default_cell.fg.rgb.red == 0xd4 && default_cell.fg.rgb.green == 0xd4 && default_cell.fg.rgb.blue == 0xd4);
    MicaCell reset_cell;
    assert(find_cell_starting_with(session, 'C', &reset_cell));
    assert(VTERM_COLOR_IS_DEFAULT_FG(&reset_cell.fg));
    assert(reset_cell.fg.rgb.red == 0xd4 && reset_cell.fg.rgb.green == 0xd4 && reset_cell.fg.rgb.blue == 0xd4);

    for (int row = 0; row < mica_session_rows(session); row++) {
        for (int col = 0; col < mica_session_cols(session); col++) {
            MicaCell cell;
            if (mica_session_get_cell(session, row, col, &cell) && cell.chars[0] == 'R') {
                assert(VTERM_COLOR_IS_RGB(&cell.fg));
                assert(cell.fg.rgb.red == 0xf4 && cell.fg.rgb.green == 0x87 && cell.fg.rgb.blue == 0x71);
                goto color_checked;
            }
        }
    }
    assert(!"colored cell was not found");
color_checked:
    ;

    uint64_t old_revision = mica_session_revision(session);
    mica_session_resize(session, 8, 40);
    poll_for(session, 40);
    assert(mica_session_rows(session) == 8);
    assert(mica_session_cols(session) == 40);
    assert(mica_session_revision(session) >= old_revision);
    mica_session_focus(session, false);
    mica_session_focus(session, true);

    mica_session_destroy(session);

    MicaSession *unicode_session = mica_session_create("/tmp", "printf 'WIDE-界🙂\\n'; sleep 1", 6, 80);
    assert(unicode_session != NULL);
    for (int i = 0; i < 200 && !screen_contains(unicode_session, "WIDE-"); i++)
        mica_session_poll(unicode_session, 10);
    assert(screen_contains(unicode_session, "WIDE-"));
    bool wide_cell_checked = false;
    for (int row = 0; row < mica_session_rows(unicode_session); row++) {
        for (int col = 0; col + 1 < mica_session_cols(unicode_session); col++) {
            MicaCell cell, continuation;
            if (!mica_session_get_cell(unicode_session, row, col, &cell) || cell.chars[0] != 0x754c) continue;
            assert(cell.width == 2);
            assert(mica_session_get_cell(unicode_session, row, col + 1, &continuation));
            assert(continuation.width == 0 || continuation.chars[0] > 0x10ffff);
            wide_cell_checked = true;
        }
    }
    assert(wide_cell_checked);
    mica_session_destroy(unicode_session);

    MicaSession *emoji_session = mica_session_create("/tmp",
        "printf 'EMOJI-🙂-👍🏽-👩‍💻-🇮🇹-❤️\\n'; sleep 1", 6, 80);
    assert(emoji_session != NULL);
    for (int i = 0; i < 200 && !screen_contains(emoji_session, "EMOJI-"); i++)
        mica_session_poll(emoji_session, 10);
    assert(screen_contains(emoji_session, "EMOJI-"));
    MicaCell emoji_cell;
    assert(find_cell_starting_with(emoji_session, 0x1f642, &emoji_cell));
    assert(emoji_cell.width == 2);
    assert(screen_has_codepoint(emoji_session, 0x1f44d));
    assert(screen_has_codepoint(emoji_session, 0x1f3fd));
    assert(screen_has_codepoint(emoji_session, 0x1f469));
    assert(screen_has_codepoint(emoji_session, 0x200d));
    assert(screen_has_codepoint(emoji_session, 0x1f4bb));
    assert(screen_has_codepoint(emoji_session, 0x1f1ee));
    assert(screen_has_codepoint(emoji_session, 0x1f1f9));
    assert(screen_has_codepoint(emoji_session, 0x2764));
    assert(screen_has_codepoint(emoji_session, 0xfe0f));
    mica_session_destroy(emoji_session);

    const size_t paste_length = 256 * 1024;
    MicaSession *paste_session = mica_session_create("/tmp",
        "stty -echo -icanon -isig -ixon; printf 'PASTE-READY\\n'; "
        "dd bs=4096 count=64 of=/dev/null 2>/dev/null; "
        "printf 'LARGE-PASTE-DONE\\n'; sleep 1",
        6, 80);
    assert(paste_session != NULL);
    for (int i = 0; i < 500 && !screen_contains(paste_session, "PASTE-READY"); i++)
        mica_session_poll(paste_session, 10);
    assert(screen_contains(paste_session, "PASTE-READY"));
    char *paste = malloc(paste_length);
    assert(paste != NULL);
    memset(paste, 'x', paste_length);
    mica_session_paste(paste_session, paste, paste_length);
    free(paste);
    for (int i = 0; i < 1000 && !screen_contains(paste_session, "LARGE-PASTE-DONE"); i++)
        mica_session_poll(paste_session, 10);
    assert(screen_contains(paste_session, "LARGE-PASTE-DONE"));
    mica_session_destroy(paste_session);

    MicaSession *exit_session = mica_session_create("/tmp", "printf 'EXIT-READY\\n'; sleep 0.1", 6, 80);
    assert(exit_session != NULL);
    for (int i = 0; i < 500 && !screen_contains(exit_session, "[command exited: 0]"); i++) mica_session_poll(exit_session, 10);
    assert(screen_contains(exit_session, "[command exited: 0]"));
    const char readiness_command[] = "printf 'SHELL-READY\\n'\n";
    mica_session_write(exit_session, readiness_command, sizeof(readiness_command) - 1);
    for (int i = 0; i < 500 && !screen_contains(exit_session, "SHELL-READY"); i++) mica_session_poll(exit_session, 10);
    assert(screen_contains(exit_session, "SHELL-READY"));
    mica_session_write(exit_session, "exit\n", 5);
    for (int i = 0; i < 500 && mica_session_is_running(exit_session); i++) mica_session_poll(exit_session, 10);
    assert(!mica_session_is_running(exit_session));
    assert(mica_session_exit_status(exit_session) == 0);
    mica_session_destroy(exit_session);

    MicaSession *focus_session = mica_session_create("/tmp",
        "printf '\\033[?1004hREADY\\n'; sleep 1",
        6, 80);
    assert(focus_session != NULL);
    for (int i = 0; i < 200 && !screen_contains(focus_session, "READY"); i++) mica_session_poll(focus_session, 10);
    assert(screen_contains(focus_session, "READY"));
    assert(mica_session_reports_focus(focus_session));
    mica_session_focus(focus_session, false);
    mica_session_focus(focus_session, true);
    mica_session_destroy(focus_session);

    setenv("NO_COLOR", "1", 1);
    MicaSession *compat_session = mica_session_create("/tmp",
        "printf '\\033]2;Codex Mica test\\007'; "
        "printf '%s|%s|%s|%s|%s|%s\\n' \"$TERM\" \"$COLORTERM\" \"$TERM_PROGRAM\" "
        "\"$TERM_PROGRAM_VERSION\" \"$TERM_PROGRAM_REVISION\" \"$CLICOLOR\"; "
        "printf '%s\\n' \"${NO_COLOR-unset}\"; "
        "printf '\\033[38;2;12;34;56mTRUECOLOR\\033[0m\\n'; "
        "printf '\\033[31mSGR16-RED\\033[0m\\n'; "
        "printf '\\033[38;5;196mANSI256-RED\\033[0m\\n'; "
        "printf '\\033[48;5;25mBG256-BLUE\\033[0m\\n'; "
        "printf '\\033[38;5;244mQGRAY244\\033[0m\\n'; sleep 1",
        12, 80);
    assert(compat_session != NULL);
    for (int i = 0; i < 200 && !screen_contains(compat_session, "QGRAY244"); i++)
        mica_session_poll(compat_session, 10);
    const char *terminal_environment = "xterm-256color|truecolor|Mica|" MICA_VERSION "|" MICA_REVISION "|1";
    if (!screen_contains(compat_session, terminal_environment)) {
        fprintf(stderr, "terminal environment missing [%s]; screen follows:\n", terminal_environment);
        print_screen(compat_session);
    }
    assert(screen_contains(compat_session, terminal_environment));
    assert(screen_contains(compat_session, "unset"));
    assert(strcmp(mica_session_title(compat_session), "Codex Mica test") == 0);
    bool truecolor_checked = false;
    for (int row = 0; row < mica_session_rows(compat_session); row++) {
        for (int col = 0; col < mica_session_cols(compat_session); col++) {
            MicaCell cell;
            if (!mica_session_get_cell(compat_session, row, col, &cell) || cell.chars[0] != 'T') continue;
            assert(VTERM_COLOR_IS_RGB(&cell.fg));
            assert(cell.fg.rgb.red == 12 && cell.fg.rgb.green == 34 && cell.fg.rgb.blue == 56);
            truecolor_checked = true;
        }
    }
    assert(truecolor_checked);
    assert(screen_contains(compat_session, "ANSI256-RED"));
    assert(screen_contains(compat_session, "SGR16-RED"));
    assert(screen_contains(compat_session, "BG256-BLUE"));
    assert(screen_contains(compat_session, "QGRAY244"));
    MicaCell ansi16_cell, ansi256_cell, bg256_cell, gray_cell;
    assert(find_cell_starting_with(compat_session, 'S', &ansi16_cell));
    assert(VTERM_COLOR_IS_RGB(&ansi16_cell.fg));
    assert(ansi16_cell.fg.rgb.red == 244 && ansi16_cell.fg.rgb.green == 135 && ansi16_cell.fg.rgb.blue == 113);
    assert(find_cell_starting_with(compat_session, 'A', &ansi256_cell));
    assert(VTERM_COLOR_IS_RGB(&ansi256_cell.fg));
    assert(ansi256_cell.fg.rgb.red == 255 && ansi256_cell.fg.rgb.green == 0 && ansi256_cell.fg.rgb.blue == 0);
    assert(find_cell_starting_with(compat_session, 'B', &bg256_cell));
    assert(VTERM_COLOR_IS_RGB(&bg256_cell.bg));
    assert(bg256_cell.bg.rgb.red == 0 && bg256_cell.bg.rgb.green == 95 && bg256_cell.bg.rgb.blue == 175);
    assert(find_cell_starting_with(compat_session, 'Q', &gray_cell));
    assert(VTERM_COLOR_IS_RGB(&gray_cell.fg));
    assert(gray_cell.fg.rgb.red == 128 && gray_cell.fg.rgb.green == 128 && gray_cell.fg.rgb.blue == 128);
    mica_session_destroy(compat_session);
    unsetenv("NO_COLOR");

    MicaSession *cleanup_session = mica_session_create("/tmp", "sleep 30", 6, 80);
    assert(cleanup_session != NULL);
    pid_t cleanup_pid = mica_session_pid(cleanup_session);
    assert(cleanup_pid > 0);
    mica_session_destroy(cleanup_session);
    errno = 0;
    assert(kill(cleanup_pid, 0) == -1 && errno == ESRCH);

    MicaSession *mouse_session = mica_session_create("/tmp",
        "stty -echo -icanon -isig; "
        "printf '\\033[?1000h\\033[?1006hMOUSE-READY\\n'; "
        "dd bs=1 count=20 2>/dev/null | od -An -v -tx1 | tr -d ' \\n'; sleep 1",
        6, 100);
    assert(mouse_session != NULL);
    for (int i = 0; i < 300 && (!screen_contains(mouse_session, "MOUSE-READY") ||
                               !mica_session_reports_mouse(mouse_session)); i++)
        mica_session_poll(mouse_session, 10);
    assert(screen_contains(mouse_session, "MOUSE-READY"));
    assert(mica_session_reports_mouse(mouse_session));
    mica_session_wheel(mouse_session, 1, 2, -1);
    mica_session_wheel(mouse_session, 1, 2, 1);
    for (int i = 0; i < 300 && !screen_contains(mouse_session, "1b5b3c3635"); i++)
        mica_session_poll(mouse_session, 10);
    assert(screen_contains(mouse_session, "1b5b3c36343b333b324d"));
    assert(screen_contains(mouse_session, "1b5b3c36353b333b324d"));
    mica_session_destroy(mouse_session);

    MicaSession *shift_enter_session = mica_session_create("/tmp",
        "stty raw -echo; printf 'SHIFT-ENTER-READY\\n'; "
        "dd bs=1 count=2 2>/dev/null | od -An -v -tx1 | tr -d ' \\n'; sleep 1",
        6, 100);
    assert(shift_enter_session != NULL);
    for (int i = 0; i < 300 && !screen_contains(shift_enter_session, "SHIFT-ENTER-READY"); i++)
        mica_session_poll(shift_enter_session, 10);
    assert(screen_contains(shift_enter_session, "SHIFT-ENTER-READY"));
    mica_session_key(shift_enter_session, VTERM_KEY_ENTER, VTERM_MOD_SHIFT);
    for (int i = 0; i < 300 && !screen_contains(shift_enter_session, "1b0d"); i++)
        mica_session_poll(shift_enter_session, 10);
    assert(screen_contains(shift_enter_session, "1b0d"));
    mica_session_destroy(shift_enter_session);

    MicaSession *pixel_session = mica_session_create("/tmp",
        "python3 -c 'import fcntl,termios,struct,time; time.sleep(.05); "
        "w=struct.unpack(\"HHHH\",fcntl.ioctl(0,termios.TIOCGWINSZ,b\"\\0\"*8)); "
        "print(\"MICA-WINSIZE:%d,%d,%d,%d\" % w,flush=True); time.sleep(1)'",
        6, 32);
    assert(pixel_session != NULL);
    mica_session_resize_pixels(pixel_session, 8, 40, 800, 600);
    for (int i = 0; i < 300 && !screen_contains(pixel_session, "MICA-WINSIZE:8,40,800,600"); i++)
        mica_session_poll(pixel_session, 10);
    assert(screen_contains(pixel_session, "MICA-WINSIZE:8,40,800,600"));
    mica_session_destroy(pixel_session);

    MicaSession *damage_session = mica_session_create("/tmp", "printf 'DAMAGE-ROWS-CHECK\\n'; sleep 1", 8, 80);
    assert(damage_session != NULL);
    for (int i = 0; i < 300 && !screen_contains(damage_session, "DAMAGE-ROWS-CHECK"); i++)
        mica_session_poll(damage_session, 10);
    assert(screen_contains(damage_session, "DAMAGE-ROWS-CHECK"));
    MicaDirtyRows dirty_rows = {0};
    assert(mica_session_take_dirty_rows(damage_session, &dirty_rows));
    assert(dirty_rows.start_row >= 0 && dirty_rows.start_row < dirty_rows.end_row);
    assert(dirty_rows.end_row <= mica_session_rows(damage_session));
    assert(!mica_session_take_dirty_rows(damage_session, NULL));
    mica_session_destroy(damage_session);

    MicaSession *fold_session = mica_session_create("/tmp",
        "i=1; while [ \"$i\" -le 40 ]; do printf 'FOLD-LINE-%04d\\n' \"$i\"; i=$((i+1)); done; sleep 1",
        6, 80);
    assert(fold_session != NULL);
    for (int i = 0; i < 500 && !screen_contains(fold_session, "FOLD-LINE-0040"); i++)
        mica_session_poll(fold_session, 10);
    assert(screen_contains(fold_session, "FOLD-LINE-0040"));
    size_t raw_fold_history = mica_session_history_lines(fold_session);
    assert(raw_fold_history > (size_t)mica_session_rows(fold_session));
    mica_session_scroll(fold_session, (int)raw_fold_history);
    assert(mica_session_view_offset(fold_session) == (int)raw_fold_history);
    size_t visible_fold_history = mica_session_display_history_lines(fold_session);
    assert(mica_session_fold_visible_rows(fold_session, 1, 3));
    assert(mica_session_display_history_lines(fold_session) + 2 == visible_fold_history);
    size_t hidden_fold_rows = 0;
    assert(mica_session_fold_info_at_view_row(fold_session, 1, &hidden_fold_rows));
    assert(hidden_fold_rows == 2);
    assert(screen_contains(fold_session, "FOLD-LINE-0005"));
    assert(mica_session_toggle_fold_at_view_row(fold_session, 1));
    assert(!mica_session_fold_info_at_view_row(fold_session, 1, NULL));
    assert(mica_session_display_history_lines(fold_session) == raw_fold_history);
    mica_session_destroy(fold_session);

    MicaSession *history_session = mica_session_create("/tmp",
        "perl -e 'for (1..5000) { printf \"STRESS-%05d\\n\", $_; } sleep 1'",
        6, 80);
    assert(history_session != NULL);
    for (int i = 0; i < 1000 && !screen_contains(history_session, "STRESS-05000"); i++)
        mica_session_poll(history_session, 10);
    assert(screen_contains(history_session, "STRESS-05000"));
    size_t history_bytes = mica_session_history_lines(history_session) * 80u * sizeof(VTermScreenCell);
    assert(history_bytes <= MICA_HISTORY_LIMIT_BYTES);
    assert(history_bytes == (MICA_HISTORY_LIMIT_BYTES / (80u * sizeof(VTermScreenCell))) *
                            (80u * sizeof(VTermScreenCell)));
    assert(mica_session_history_lines(history_session) > 0);
    mica_session_resize(history_session, 8, 160);
    history_bytes = mica_session_history_lines(history_session) * 160u * sizeof(VTermScreenCell);
    assert(history_bytes <= MICA_HISTORY_LIMIT_BYTES);
    mica_session_destroy(history_session);
    printf("scrollback allocation stays within %u bytes per session\n", MICA_HISTORY_LIMIT_BYTES);

    char profile_template[] = "/tmp/mica-profile-test-XXXXXX";
    char *profile_dir = mkdtemp(profile_template);
    assert(profile_dir != NULL);
    char canonical_profile_dir[PATH_MAX];
    assert(realpath(profile_dir, canonical_profile_dir) != NULL);
    char bin_dir[PATH_MAX], zprofile_path[PATH_MAX], zshrc_path[PATH_MAX];
    char zcompdump_path[PATH_MAX], zhistory_path[PATH_MAX];
    char zlogin_path[PATH_MAX], claude_path[PATH_MAX], codex_path[PATH_MAX], test_path[PATH_MAX * 2];
    assert(snprintf(bin_dir, sizeof(bin_dir), "%s/bin", profile_dir) > 0);
    assert(mkdir(bin_dir, 0700) == 0);
    assert(snprintf(zprofile_path, sizeof(zprofile_path), "%s/.zprofile", profile_dir) > 0);
    assert(snprintf(zshrc_path, sizeof(zshrc_path), "%s/.zshrc", profile_dir) > 0);
    assert(snprintf(zlogin_path, sizeof(zlogin_path), "%s/.zlogin", profile_dir) > 0);
    assert(snprintf(zcompdump_path, sizeof(zcompdump_path), "%s/.zcompdump", profile_dir) > 0);
    assert(snprintf(zhistory_path, sizeof(zhistory_path), "%s/.zsh_history", profile_dir) > 0);
    assert(snprintf(claude_path, sizeof(claude_path), "%s/claude", bin_dir) > 0);
    assert(snprintf(codex_path, sizeof(codex_path), "%s/codex", bin_dir) > 0);
    assert(snprintf(test_path, sizeof(test_path), "%s:/usr/bin:/bin", bin_dir) > 0);
    write_test_file(zprofile_path, "export MICA_PROFILE_MARKER=login\n", 0600);
    write_test_file(zshrc_path,
        "export MICA_RC_MARKER=interactive\n"
        "autoload -Uz compinit\n"
        "compinit -u\n"
        "setopt AUTO_LIST\n"
        "_mica_test_completion() { compadd alpha alpine; }\n"
        "compdef _mica_test_completion mica-test-complete\n"
        "alias mica-claude-alias='claude --from-alias'\n"
        "printf 'MICA-COMPLETION-READY\\n'\n", 0600);
    write_test_file(zlogin_path, "export MICA_LOGIN_MARKER=loaded\n", 0600);
    write_test_file(claude_path,
        "#!/bin/sh\n"
        "if [ -n \"$CLAUDECODE\" ]; then nested=set; else nested=unset; fi\n"
        "printf 'MICA-CLAUDE:%s|%s|%s|%s|%s|%s\\n' \"$MICA_PROFILE_MARKER\" "
        "\"$MICA_RC_MARKER\" \"$MICA_LOGIN_MARKER\" \"$*\" \"$PWD\" \"$nested\"\n"
        "case \"$*\" in *--from-alias*) sleep 0.2 ;; esac\n", 0700);
    write_test_file(codex_path,
        "#!/bin/sh\nprintf 'MICA-CODEX:%s|%s|%s\\n' \"$MICA_PROFILE_MARKER\" \"$MICA_LOGIN_MARKER\" \"$*\"\n",
        0700);
    char *saved_zdotdir = copy_env("ZDOTDIR");
    char *saved_path = copy_env("PATH");
    char *saved_test_mode = copy_env("MICA_TEST_NO_STARTUP");
    char *saved_claudecode = copy_env("CLAUDECODE");
    char *saved_mica_original_zdotdir = copy_env("MICA_ORIGINAL_ZDOTDIR");
    char *saved_mica_zsh_wrapper = copy_env("MICA_ZSH_WRAPPER");
    assert(setenv("ZDOTDIR", profile_dir, 1) == 0);
    assert(unsetenv("MICA_ORIGINAL_ZDOTDIR") == 0);
    assert(unsetenv("MICA_ZSH_WRAPPER") == 0);
    assert(setenv("PATH", test_path, 1) == 0);
    assert(setenv("MICA_TEST_NO_STARTUP", "0", 1) == 0);
    assert(setenv("CLAUDECODE", "outer", 1) == 0);
    MicaSession *prefilled_claude = mica_session_create_prefilled(profile_dir, "claude --continue", 8, 120);
    assert(prefilled_claude != NULL);
    for (int i = 0; i < 500 && !screen_contains(prefilled_claude, "claude --continue"); i++)
        mica_session_poll(prefilled_claude, 10);
    assert(screen_contains(prefilled_claude, "claude --continue"));
    assert(!screen_contains(prefilled_claude, "MICA-CLAUDE:"));
    mica_session_key(prefilled_claude, VTERM_KEY_ENTER, VTERM_MOD_NONE);
    for (int i = 0; i < 500 && !screen_contains(prefilled_claude, "MICA-CLAUDE:"); i++)
        mica_session_poll(prefilled_claude, 10);
    char expected_claude[PATH_MAX + 192];
    assert(snprintf(expected_claude, sizeof(expected_claude),
        "MICA-CLAUDE:login|interactive|loaded|--continue|%s|set", canonical_profile_dir) > 0);
    assert(screen_contains(prefilled_claude, expected_claude));
    mica_session_destroy(prefilled_claude);

    MicaSession *claude_session = mica_session_create(profile_dir, "claude --start", 8, 120);
    assert(claude_session != NULL);
    char expected_claude_start[PATH_MAX + 192];
    assert(snprintf(expected_claude_start, sizeof(expected_claude_start),
        "MICA-CLAUDE:login|interactive|loaded|--start|%s|set", canonical_profile_dir) > 0);
    for (int i = 0; i < 500 && !screen_contains(claude_session, expected_claude_start); i++)
        mica_session_poll(claude_session, 10);
    assert(screen_contains(claude_session, expected_claude_start));
    mica_session_destroy(claude_session);

    char nested_wrapper_template[] = "/tmp/mica-parent-zsh-XXXXXX";
    char *nested_wrapper_dir = mkdtemp(nested_wrapper_template);
    assert(nested_wrapper_dir != NULL);
    char nested_zshrc_path[PATH_MAX];
    assert(snprintf(nested_zshrc_path, sizeof(nested_zshrc_path), "%s/.zshrc", nested_wrapper_dir) > 0);
    write_test_file(nested_zshrc_path, "export MICA_RC_MARKER=nested-wrapper\n", 0600);
    assert(setenv("MICA_ORIGINAL_ZDOTDIR", profile_dir, 1) == 0);
    assert(setenv("MICA_ZSH_WRAPPER", nested_wrapper_dir, 1) == 0);
    assert(setenv("ZDOTDIR", nested_wrapper_dir, 1) == 0);
    MicaSession *nested_alias_session = mica_session_create_prefilled(
        profile_dir, "unset CLAUDECODE && mica-claude-alias --from-alias", 8, 120);
    assert(nested_alias_session != NULL);
    for (int i = 0; i < 500 && !screen_contains(nested_alias_session, "mica-claude-alias --from-alias"); i++)
        mica_session_poll(nested_alias_session, 10);
    // zsh versions differ in how they redraw a print -z command around the
    // initial prompt. The command itself is verified by the alias output and
    // Mica's reported active-command label below.
    mica_session_key(nested_alias_session, VTERM_KEY_ENTER, VTERM_MOD_NONE);
    const char *expected_alias = "MICA-CLAUDE:login|interactive|loaded|--from-alias";
    bool nested_alias_label = false;
    for (int i = 0; i < 500 && (!screen_contains(nested_alias_session, expected_alias) || !nested_alias_label); i++) {
        mica_session_poll(nested_alias_session, 10);
        nested_alias_label = strcmp(mica_session_current_command(nested_alias_session), "mica-claude-alias") == 0;
    }
    assert(screen_contains(nested_alias_session, expected_alias));
    assert(nested_alias_label);
    puts("nested Mica sessions preserve the original zsh startup and show the actual alias command");
    for (int i = 0; i < 500 && mica_session_command_completion_count(nested_alias_session) == 0; i++)
        mica_session_poll(nested_alias_session, 10);
    assert(mica_session_command_completion_count(nested_alias_session) == 1);
    assert(mica_session_command_exit_status(nested_alias_session) == 0);
    mica_session_destroy(nested_alias_session);
    assert(setenv("ZDOTDIR", profile_dir, 1) == 0);
    assert(unsetenv("MICA_ORIGINAL_ZDOTDIR") == 0);
    assert(unsetenv("MICA_ZSH_WRAPPER") == 0);
    unlink(nested_zshrc_path);
    assert(rmdir(nested_wrapper_dir) == 0);

    MicaSession *codex_session = mica_session_create(profile_dir, "codex resume --last", 8, 120);
    assert(codex_session != NULL);
    const char *expected_codex = "MICA-CODEX:login|loaded|resume --last";
    for (int i = 0; i < 500 && !screen_contains(codex_session, expected_codex); i++)
        mica_session_poll(codex_session, 10);
    assert(screen_contains(codex_session, expected_codex));
    mica_session_destroy(codex_session);

    MicaSession *zsh_completion_session = mica_session_create(profile_dir, NULL, 8, 120);
    assert(zsh_completion_session != NULL);
    for (int i = 0; i < 500 && !screen_contains(zsh_completion_session, "MICA-COMPLETION-READY"); i++)
        mica_session_poll(zsh_completion_session, 10);
    assert(screen_contains(zsh_completion_session, "MICA-COMPLETION-READY"));
    mica_session_write(zsh_completion_session, "mica-test-complete al", strlen("mica-test-complete al"));
    mica_session_key(zsh_completion_session, VTERM_KEY_TAB, VTERM_MOD_NONE);
    for (int i = 0; i < 500 &&
         (!screen_contains(zsh_completion_session, "alpha") || !screen_contains(zsh_completion_session, "alpine")); i++)
        mica_session_poll(zsh_completion_session, 10);
    if (!screen_contains(zsh_completion_session, "alpha") || !screen_contains(zsh_completion_session, "alpine")) {
        mica_session_key(zsh_completion_session, VTERM_KEY_TAB, VTERM_MOD_NONE);
        for (int i = 0; i < 200 &&
             (!screen_contains(zsh_completion_session, "alpha") || !screen_contains(zsh_completion_session, "alpine")); i++)
            mica_session_poll(zsh_completion_session, 10);
    }
    assert(screen_contains(zsh_completion_session, "alpha"));
    assert(screen_contains(zsh_completion_session, "alpine"));
    mica_session_text(zsh_completion_session, 'c', VTERM_MOD_CTRL);
    uint64_t completion_baseline = mica_session_command_completion_count(zsh_completion_session);
    mica_session_write(zsh_completion_session, "unset CLAUDECODE && sleep 0.35\n",
                       strlen("unset CLAUDECODE && sleep 0.35\n"));
    bool command_started = false;
    for (int i = 0; i < 100 && !command_started; i++) {
        mica_session_poll(zsh_completion_session, 10);
        command_started = strcmp(mica_session_current_command(zsh_completion_session), "sleep") == 0;
    }
    assert(command_started);
    for (int i = 0; i < 200 &&
         (mica_session_command_completion_count(zsh_completion_session) == completion_baseline ||
          mica_session_current_command(zsh_completion_session)[0] != '\0'); i++)
        mica_session_poll(zsh_completion_session, 10);
    assert(mica_session_command_completion_count(zsh_completion_session) > completion_baseline);
    assert(mica_session_current_command(zsh_completion_session)[0] == '\0');
    mica_session_destroy(zsh_completion_session);

    MicaSession *completion_session = mica_session_create(profile_dir, "sleep 0.05; false", 8, 120);
    assert(completion_session != NULL);
    for (int i = 0; i < 500 && mica_session_command_completion_count(completion_session) == 0; i++)
        mica_session_poll(completion_session, 10);
    assert(mica_session_is_running(completion_session));
    assert(mica_session_command_completion_count(completion_session) == 1);
    assert(mica_session_command_exit_status(completion_session) == 1);
    assert(mica_session_attention_count(completion_session) == 0);
    mica_session_destroy(completion_session);
    restore_env("ZDOTDIR", saved_zdotdir);
    restore_env("PATH", saved_path);
    restore_env("MICA_TEST_NO_STARTUP", saved_test_mode);
    restore_env("CLAUDECODE", saved_claudecode);
    restore_env("MICA_ORIGINAL_ZDOTDIR", saved_mica_original_zdotdir);
    restore_env("MICA_ZSH_WRAPPER", saved_mica_zsh_wrapper);
    unlink(zprofile_path);
    unlink(zshrc_path);
    unlink(zlogin_path);
    unlink(zcompdump_path);
    unlink(zhistory_path);
    unlink(claude_path);
    unlink(codex_path);
    assert(rmdir(bin_dir) == 0);
    assert(rmdir(profile_dir) == 0);

    test_clean_zsh_completion();

    puts("session tests passed");
    return 0;
}
