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

#ifdef MICA_SESSION_TESTING
void mica_session_test_fail_next_history_resize_allocation(void);
void mica_session_test_fail_next_resize_link_snapshot_allocation(void);
#endif

static unsigned cleanupStageStarts;
static unsigned cleanupStageEnds;
static bool cleanupObservedPTYClose;

static void record_cleanup_stage(pid_t pid, const char *stage, bool started, double elapsed_ms) {
    (void)pid;
    (void)elapsed_ms;
    if (started) cleanupStageStarts++;
    else cleanupStageEnds++;
    if (!started && strcmp(stage, "close_pty") == 0) cleanupObservedPTYClose = true;
}

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
        for (int attempt = 0; attempt < 1000 && !screen_contains(session, "git status"); attempt++)
            mica_session_poll(session, 10);
        if (!screen_contains(session, "git status")) print_screen(session);
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

    MicaSessionOutputMetrics outputMetrics = {0};
    assert(mica_session_take_output_metrics(session, &outputMetrics));
    assert(outputMetrics.bytes_read > 0 && outputMetrics.read_calls > 0 && outputMetrics.largest_read > 0);

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
    long unicode_cursor = -1;
    assert(mica_session_find(unicode_session, "界🙂", true, &unicode_cursor));
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
    unicode_cursor = -1;
    assert(mica_session_find(emoji_session, "👍🏽", true, &unicode_cursor));
    unicode_cursor = -1;
    assert(mica_session_find(emoji_session, "👩‍💻", true, &unicode_cursor));
    unicode_cursor = -1;
    assert(mica_session_find(emoji_session, "❤️", true, &unicode_cursor));
    mica_session_destroy(emoji_session);

    MicaSession *combining_session = mica_session_create("/tmp",
        "printf 'ACCENT-cafe\\314\\201-END\\n'; sleep 0.1; printf '\\n\\n\\n\\n\\n\\n'; sleep 1", 6, 80);
    assert(combining_session != NULL);
    unicode_cursor = -1;
    for (int i = 0; i < 200 && !screen_contains(combining_session, "ACCENT-"); i++)
        mica_session_poll(combining_session, 1);
    assert(mica_session_find(combining_session, "cafe\xcc\x81-END", true, &unicode_cursor));
    for (int i = 0; i < 300 && mica_session_history_lines(combining_session) == 0; i++)
        mica_session_poll(combining_session, 10);
    assert(mica_session_history_lines(combining_session) > 0);
    unicode_cursor = -1;
    assert(mica_session_find(combining_session, "cafe\xcc\x81-END", false, &unicode_cursor));
    assert(unicode_cursor < (long)mica_session_history_lines(combining_session));
    mica_session_destroy(combining_session);

    MicaSession *unicode_case_session = mica_session_create("/tmp",
        "printf 'UNICODE-CAFÉ-Σ-Straße-END\\n'; sleep 0.1; printf '\\n\\n\\n\\n\\n\\n\\n'; sleep 1",
        6, 80);
    assert(unicode_case_session != NULL);
    for (int i = 0; i < 300 && !screen_contains(unicode_case_session, "UNICODE-"); i++)
        mica_session_poll(unicode_case_session, 10);
    assert(screen_contains(unicode_case_session, "UNICODE-"));
    unicode_cursor = -1;
    assert(mica_session_find(unicode_case_session,
        "unicode-cafe\xcc\x81-\xcf\x83-strasse-end", true, &unicode_cursor));
    unicode_cursor = -1;
    assert(!mica_session_find(unicode_case_session, "cafe", true, &unicode_cursor));
    unicode_cursor = -1;
    assert(mica_session_find(unicode_case_session, "STRASSE", true, &unicode_cursor));
    unicode_cursor = -1;
    assert(mica_session_find(unicode_case_session, "\xcf\x82", true, &unicode_cursor));
    for (int i = 0; i < 300 && mica_session_history_lines(unicode_case_session) == 0; i++)
        mica_session_poll(unicode_case_session, 10);
    assert(mica_session_history_lines(unicode_case_session) > 0);
    unicode_cursor = -1;
    assert(mica_session_find(unicode_case_session,
        "unicode-cafe\xcc\x81-\xcf\x83-strasse-end", false, &unicode_cursor));
    assert(unicode_cursor < (long)mica_session_history_lines(unicode_case_session));
    mica_session_destroy(unicode_case_session);

    MicaSession *long_search_session = mica_session_create("/tmp",
        "perl -e 'print \"x\" x 1100, \"TAIL-MARKER\\n\"'; sleep 1; printf '\\n\\n\\n\\n\\n\\n'", 6, 1200);
    assert(long_search_session != NULL);
    for (int i = 0; i < 300 && !screen_contains(long_search_session, "TAIL-MARKER"); i++)
        mica_session_poll(long_search_session, 10);
    assert(screen_contains(long_search_session, "TAIL-MARKER"));
    char long_query[302];
    memset(long_query, 'x', 300);
    long_query[300] = 'Z'; long_query[301] = '\0';
    unicode_cursor = -1;
    assert(!mica_session_find(long_search_session, long_query, true, &unicode_cursor));
    long_query[300] = '\0';
    assert(mica_session_find(long_search_session, long_query, true, &unicode_cursor));
    unicode_cursor = -1;
    assert(mica_session_find(long_search_session, "TAIL-MARKER", true, &unicode_cursor));
    for (int i = 0; i < 300 && mica_session_command_completion_count(long_search_session) == 0; i++)
        mica_session_poll(long_search_session, 10);
    assert(mica_session_command_completion_count(long_search_session) > 0);
    unicode_cursor = -1;
    assert(mica_session_find(long_search_session, "TAIL-MARKER", false, &unicode_cursor));
    assert(unicode_cursor < (long)mica_session_history_lines(long_search_session));
    mica_session_destroy(long_search_session);

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

    char paste_attack_directory[] = "/tmp/mica-paste-attack-XXXXXX";
    char *paste_attack_root = mkdtemp(paste_attack_directory);
    assert(paste_attack_root != NULL);
    char paste_marker[PATH_MAX];
    assert(snprintf(paste_marker, sizeof(paste_marker), "%s/EXECUTED", paste_attack_root) > 0);
    char paste_ready_command[PATH_MAX + 64];
    assert(snprintf(paste_ready_command, sizeof(paste_ready_command),
        "stty -echo; printf 'PASTE-ATTACK-READY\\n'; sleep 0.1") > 0);
    MicaSession *paste_attack_session = mica_session_create("/tmp", paste_ready_command, 6, 100);
    assert(paste_attack_session != NULL);
    for (int i = 0; i < 500 && !screen_contains(paste_attack_session, "PASTE-ATTACK-READY"); i++)
        mica_session_poll(paste_attack_session, 10);
    assert(screen_contains(paste_attack_session, "PASTE-ATTACK-READY"));
    poll_for(paste_attack_session, 250);
    char paste_attack[PATH_MAX + 64];
    int paste_attack_length = snprintf(paste_attack, sizeof(paste_attack), "\033[201~touch '%s'\r", paste_marker);
    assert(paste_attack_length > 0 && (size_t)paste_attack_length < sizeof(paste_attack));
    mica_session_paste(paste_attack_session, paste_attack, (size_t)paste_attack_length);
    poll_for(paste_attack_session, 250);
    assert(access(paste_marker, F_OK) != 0);
    mica_session_destroy(paste_attack_session);
    assert(rmdir(paste_attack_root) == 0);

    MicaSession *exit_session = mica_session_create("/tmp", "printf 'EXIT-READY\\n'; sleep 0.1", 6, 80);
    assert(exit_session != NULL);
    for (int i = 0; i < 500 && !screen_contains(exit_session, "[command exited: 0]"); i++) mica_session_poll(exit_session, 10);
    assert(screen_contains(exit_session, "[command exited: 0]"));
    const char readiness_command[] = "printf 'SHELL-READY\\n'; PS1=$'\\x4dICA-SHELL-PROMPT> '\n";
    mica_session_write(exit_session, readiness_command, sizeof(readiness_command) - 1);
    for (int i = 0; i < 1000 && !screen_contains(exit_session, "MICA-SHELL-PROMPT>"); i++)
        mica_session_poll(exit_session, 10);
    assert(screen_contains(exit_session, "MICA-SHELL-PROMPT>"));
    mica_session_write(exit_session, "exit\n", 5);
    for (int i = 0; i < 1500 && mica_session_is_running(exit_session); i++) mica_session_poll(exit_session, 10);
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
    cleanupStageStarts = cleanupStageEnds = 0;
    cleanupObservedPTYClose = false;
    mica_session_set_cleanup_logger(record_cleanup_stage);
    mica_session_destroy(cleanup_session);
    mica_session_set_cleanup_logger(NULL);
    assert(cleanupStageStarts >= 5 && cleanupStageEnds == cleanupStageStarts && cleanupObservedPTYClose);
    errno = 0;
    assert(kill(cleanup_pid, 0) == -1 && errno == ESRCH);

    char orphanPIDTemplate[] = "/tmp/mica-orphan-pid-XXXXXX";
    int orphanPIDFD = mkstemp(orphanPIDTemplate);
    assert(orphanPIDFD >= 0);
    close(orphanPIDFD);
    unlink(orphanPIDTemplate);
    char orphanCommand[1024];
    snprintf(orphanCommand, sizeof(orphanCommand),
        "sh -c 'trap \"\" HUP; echo $$ > %s; exec sleep 30' & "
        "printf 'GROUP-CLEANUP-READY\\n'; wait", orphanPIDTemplate);
    MicaSession *groupCleanupSession = mica_session_create("/tmp", orphanCommand, 6, 80);
    assert(groupCleanupSession != NULL);
    pid_t groupCleanupShellPID = mica_session_pid(groupCleanupSession);
    pid_t groupCleanupDescendantPID = -1;
    for (int attempt = 0; attempt < 200; attempt++) {
        mica_session_poll(groupCleanupSession, 10);
        FILE *pidFile = fopen(orphanPIDTemplate, "r");
        if (pidFile) {
            (void)fscanf(pidFile, "%d", &groupCleanupDescendantPID);
            fclose(pidFile);
        }
        if (groupCleanupDescendantPID > 0) break;
    }
    assert(groupCleanupDescendantPID > 0);
    mica_session_destroy(groupCleanupSession);
    unlink(orphanPIDTemplate);
    bool groupCleanupProcessesGone = false;
    for (int attempt = 0; attempt < 200; attempt++) {
        errno = 0;
        bool shellGone = kill(groupCleanupShellPID, 0) < 0 && errno == ESRCH;
        errno = 0;
        bool descendantGone = kill(groupCleanupDescendantPID, 0) < 0 && errno == ESRCH;
        if (shellGone && descendantGone) {
            groupCleanupProcessesGone = true;
            break;
        }
        usleep(10000);
    }
    assert(groupCleanupProcessesGone);

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

    MicaSession *link_session = mica_session_create("/tmp",
        "printf 'PLAIN '; printf '\\033]8;id=example;https://example.test/path\\033\\\\'; "
        "printf 'CLICKABLE'; printf '\\033]8;;\\033\\\\'; printf ' UNLINKED\\n'; sleep 1",
        8, 80);
    assert(link_session != NULL);
    for (int i = 0; i < 300 && !screen_contains(link_session, "CLICKABLE UNLINKED"); i++)
        mica_session_poll(link_session, 10);
    bool clickable_link_found = false;
    bool plain_text_unlinked = true;
    for (int row = 0; row < mica_session_rows(link_session); row++) {
        for (int col = 0; col < mica_session_cols(link_session); col++) {
            MicaCell cell;
            if (!mica_session_get_cell(link_session, row, col, &cell)) continue;
            if (cell.chars[0] == 'C' && cell.hyperlink_id) {
                const char *uri = mica_session_hyperlink_uri(link_session, cell.hyperlink_id);
                clickable_link_found = uri && strcmp(uri, "https://example.test/path") == 0;
            }
            if (cell.chars[0] == 'P' || cell.chars[0] == 'U')
                if (cell.hyperlink_id) plain_text_unlinked = false;
        }
    }
    assert(screen_contains(link_session, "CLICKABLE UNLINKED"));
    assert(clickable_link_found && plain_text_unlinked);
    mica_session_destroy(link_session);

    MicaSession *wrap_session = mica_session_create("/tmp",
        "printf 'https://example.test/abcdefghijklmnopqrstuvwxyz0123456789\\nHARD-NEWLINE\\n'; sleep 1", 6, 24);
    assert(wrap_session != NULL);
    for (int i = 0; i < 300 && !screen_contains(wrap_session, "HARD-NEWLINE"); i++)
        mica_session_poll(wrap_session, 10);
    bool saw_soft_wrap = false, hard_line_stays_separate = true;
    for (int row = 1; row < mica_session_rows(wrap_session); row++) {
        if (mica_session_row_continues(wrap_session, row)) saw_soft_wrap = true;
        if (screen_contains(wrap_session, "HARD-NEWLINE") && mica_session_row_continues(wrap_session, row)) {
            MicaCell first;
            if (mica_session_get_cell(wrap_session, row, 0, &first) && first.chars[0] == 'H')
                hard_line_stays_separate = false;
        }
    }
    assert(saw_soft_wrap && hard_line_stays_separate);
    mica_session_destroy(wrap_session);

    MicaSession *history_wrap = mica_session_create("/tmp",
        "printf 'https://example.test/abcdefghijklmnopqrstuvwxyz0123456789\\nHARD-NEWLINE\\n'; "
        "printf '\\n\\n\\n\\n\\n\\nDONE-WRAP\\n'; sleep 1", 6, 24);
    assert(history_wrap);
    for (int i = 0; i < 600 && !screen_contains(history_wrap, "DONE-WRAP"); i++)
        mica_session_poll(history_wrap, 10);
    assert(screen_contains(history_wrap, "DONE-WRAP"));
    mica_session_scroll(history_wrap, INT_MAX);
    assert(mica_session_row_continues(history_wrap, 1));
    assert(mica_session_row_continues(history_wrap, 2));
    assert(!mica_session_row_continues(history_wrap, 3));
    assert(mica_session_fold_visible_rows(history_wrap, 1, 3));
    assert(!mica_session_row_continues(history_wrap, 1));
    assert(!mica_session_row_continues(history_wrap, 2));
    mica_session_resize(history_wrap, 20, 24);
    mica_session_scroll(history_wrap, -INT_MAX);
    assert(screen_contains(history_wrap, "https://example.test/"));
    assert(mica_session_row_continues(history_wrap, 1));
    assert(mica_session_row_continues(history_wrap, 2));
    assert(!mica_session_row_continues(history_wrap, 3));
    mica_session_destroy(history_wrap);

    // A wrapped line can straddle primary history and live output. Switching
    // to a separately wrapped alternate screen must break that connection.
    MicaSession *boundary_wrap = mica_session_create("/tmp",
        "exec perl -e '$|=1; print \"https://example.test/abcdefghijklmnopqrstuvwxyz0123456789\\nLIVE-READY\\n\"; "
        "scalar <STDIN>; print \"\\e[?1049h\", \"q\" x 100, \"\\nALT-READY\\n\"; scalar <STDIN>'", 4, 24);
    assert(boundary_wrap);
    for (int i = 0; i < 600 && !screen_contains(boundary_wrap, "LIVE-READY"); i++)
        mica_session_poll(boundary_wrap, 10);
    assert(screen_contains(boundary_wrap, "LIVE-READY"));
    assert(mica_session_history_lines(boundary_wrap) == 1);
    mica_session_scroll(boundary_wrap, 1);
    assert(mica_session_row_continues(boundary_wrap, 1));
    assert(mica_session_row_continues(boundary_wrap, 2));
    assert(!mica_session_row_continues(boundary_wrap, 3));
    mica_session_scroll(boundary_wrap, -INT_MAX);
    mica_session_write(boundary_wrap, "go\n", 3);
    for (int i = 0; i < 600 && !screen_contains(boundary_wrap, "ALT-READY"); i++)
        mica_session_poll(boundary_wrap, 10);
    assert(screen_contains(boundary_wrap, "ALT-READY"));
    mica_session_scroll(boundary_wrap, 1);
    assert(!mica_session_row_continues(boundary_wrap, 1));
    mica_session_destroy(boundary_wrap);

    MicaSession *scroll_link_session = mica_session_create("/tmp",
        "printf '\\033]8;;https://example.test/scroll\\033\\\\SCROLLED-LINK\\033]8;;\\033\\\\\\n'; "
        "i=1; while [ $i -le 12 ]; do printf 'AFTER-LINK-%02d\\n' $i; i=$((i+1)); done; sleep 1",
        4, 80);
    assert(scroll_link_session != NULL);
    for (int i = 0; i < 300 && !screen_contains(scroll_link_session, "AFTER-LINK-12"); i++)
        mica_session_poll(scroll_link_session, 10);
    assert(screen_contains(scroll_link_session, "AFTER-LINK-12"));
    assert(mica_session_history_lines(scroll_link_session) > 0);
    mica_session_scroll(scroll_link_session, 100);
    bool scrollback_link_preserved = false;
    int scrollback_link_row = -1, scrollback_link_col = -1;
    for (int row = 0; row < mica_session_rows(scroll_link_session); row++) {
        for (int col = 0; col < mica_session_cols(scroll_link_session); col++) {
            MicaCell cell;
            if (!mica_session_get_cell(scroll_link_session, row, col, &cell) || cell.chars[0] != 'S') continue;
            const char *uri = mica_session_hyperlink_uri(scroll_link_session, cell.hyperlink_id);
            if (uri && strcmp(uri, "https://example.test/scroll") == 0) {
                scrollback_link_preserved = true;
                scrollback_link_row = row;
                scrollback_link_col = col;
            }
        }
    }
    assert(scrollback_link_preserved);
#ifdef MICA_SESSION_TESTING
    mica_session_test_fail_next_history_resize_allocation();
    assert(!mica_session_resize(scroll_link_session, 4, 160));
    MicaCell link_after_failed_resize;
    assert(mica_session_cols(scroll_link_session) == 80);
    assert(mica_session_get_cell(scroll_link_session, scrollback_link_row, scrollback_link_col,
        &link_after_failed_resize));
    const char *link_uri_after_failed_resize = mica_session_hyperlink_uri(
        scroll_link_session, link_after_failed_resize.hyperlink_id);
    assert(link_uri_after_failed_resize && strcmp(link_uri_after_failed_resize,
        "https://example.test/scroll") == 0);
#endif
#ifdef MICA_SESSION_TESTING
    mica_session_test_fail_next_resize_link_snapshot_allocation();
    assert(!mica_session_resize(scroll_link_session, 4, 100));
    assert(mica_session_cols(scroll_link_session) == 80);
    MicaCell link_after_snapshot_failure;
    assert(mica_session_get_cell(scroll_link_session, scrollback_link_row, scrollback_link_col,
        &link_after_snapshot_failure));
    const char *link_uri_after_snapshot_failure = mica_session_hyperlink_uri(
        scroll_link_session, link_after_snapshot_failure.hyperlink_id);
    assert(link_uri_after_snapshot_failure && strcmp(link_uri_after_snapshot_failure,
        "https://example.test/scroll") == 0);
#endif
    assert(mica_session_resize(scroll_link_session, 4, 100));
    mica_session_scroll(scroll_link_session, INT_MAX);
    bool retained_link_survives_width_change = false;
    for (int row = 0; row < mica_session_rows(scroll_link_session); row++) {
        for (int col = 0; col < mica_session_cols(scroll_link_session); col++) {
            MicaCell cell;
            if (!mica_session_get_cell(scroll_link_session, row, col, &cell) || cell.chars[0] != 'S') continue;
            const char *uri = mica_session_hyperlink_uri(scroll_link_session, cell.hyperlink_id);
            if (uri && strcmp(uri, "https://example.test/scroll") == 0)
                retained_link_survives_width_change = true;
        }
    }
    assert(retained_link_survives_width_change);
    assert(mica_session_resize(scroll_link_session, 4, 40));
    mica_session_scroll(scroll_link_session, INT_MAX);
    bool retained_link_survives_width_shrink = false;
    for (int row = 0; row < mica_session_rows(scroll_link_session); row++) {
        for (int col = 0; col < mica_session_cols(scroll_link_session); col++) {
            MicaCell cell;
            if (!mica_session_get_cell(scroll_link_session, row, col, &cell) || cell.chars[0] != 'S') continue;
            const char *uri = mica_session_hyperlink_uri(scroll_link_session, cell.hyperlink_id);
            if (uri && strcmp(uri, "https://example.test/scroll") == 0)
                retained_link_survives_width_shrink = true;
        }
    }
    assert(retained_link_survives_width_shrink);
    mica_session_destroy(scroll_link_session);

    // Rows pushed by libvterm's resize callback keep their corresponding OSC 8
    // sidecar IDs, even when multiple differently linked rows are captured.
    MicaSession *resize_link_session = mica_session_create("/tmp",
        "printf '\\033]8;;https://example.test/resize-first\\033\\\\A_RESIZE_LINK\\033]8;;\\033\\\\'; "
        "printf '\\033[2;1H\\033]8;;https://example.test/resize-second\\033\\\\B_RESIZE_LINK\\033]8;;\\033\\\\'; "
        "printf '\\033[3;1HROW-THREE\\033[4;1HRESIZE-READY'; sleep 1",
        4, 80);
    assert(resize_link_session != NULL);
    for (int i = 0; i < 300 && !screen_contains(resize_link_session, "RESIZE-READY"); i++)
        mica_session_poll(resize_link_session, 10);
    assert(screen_contains(resize_link_session, "RESIZE-READY"));
    assert(mica_session_resize(resize_link_session, 2, 80));
    assert(mica_session_history_lines(resize_link_session) > 0);
    mica_session_scroll(resize_link_session, INT_MAX);
    bool resize_pushed_first_link_preserved = false;
    bool resize_pushed_second_link_preserved = false;
    for (int row = 0; row < mica_session_rows(resize_link_session); row++) {
        for (int col = 0; col < mica_session_cols(resize_link_session); col++) {
            MicaCell cell;
            if (!mica_session_get_cell(resize_link_session, row, col, &cell)) continue;
            const char *uri = mica_session_hyperlink_uri(resize_link_session, cell.hyperlink_id);
            if (cell.chars[0] == 'A' && uri &&
                strcmp(uri, "https://example.test/resize-first") == 0)
                resize_pushed_first_link_preserved = true;
            if (cell.chars[0] == 'B' && uri &&
                strcmp(uri, "https://example.test/resize-second") == 0)
                resize_pushed_second_link_preserved = true;
        }
    }
    assert(resize_pushed_first_link_preserved && resize_pushed_second_link_preserved);
    mica_session_destroy(resize_link_session);


    // Scalar history rows share common style/color metadata, while a row with
    // more styles than the bounded palette falls back without losing data.
    MicaSession *styled_history = mica_session_create("/tmp",
        "exec perl -e '$|=1; print \"\\e[1;38;2;12;34;56mA\\e[0m\"; "
        "print \"\\e[4;48;5;25mB\\e[0m\\n\"; "
        "for (1..20) { printf(\"\\e[38;2;%d;2;3m%c\", $_, 64 + $_); } "
        "print \"\\e[0m\\n\"; print \"PAD\\n\" x 10; print \"STYLE-READY\\n\"; sleep 1'",
        4, 80);
    assert(styled_history != NULL);
    for (int i = 0; i < 500 && !screen_contains(styled_history, "STYLE-READY"); i++)
        mica_session_poll(styled_history, 10);
    assert(screen_contains(styled_history, "STYLE-READY"));
    assert(mica_session_history_lines(styled_history) > 0);
    mica_session_scroll(styled_history, INT_MAX);
    MicaCell styled_a, styled_b;
    assert(find_cell_starting_with(styled_history, 'A', &styled_a));
    assert(styled_a.attrs.bold);
    assert(VTERM_COLOR_IS_RGB(&styled_a.fg) && styled_a.fg.rgb.red == 12 &&
        styled_a.fg.rgb.green == 34 && styled_a.fg.rgb.blue == 56);
    assert(find_cell_starting_with(styled_history, 'B', &styled_b));
    assert(styled_b.attrs.underline == VTERM_UNDERLINE_SINGLE);
    bool high_entropy_first = false, high_entropy_last = false;
    for (int row = 0; row < mica_session_rows(styled_history); row++)
        for (int col = 0; col < mica_session_cols(styled_history); col++) {
            MicaCell cell;
            if (!mica_session_get_cell(styled_history, row, col, &cell) || !VTERM_COLOR_IS_RGB(&cell.fg)) continue;
            if (cell.chars[0] == 'A' && cell.fg.rgb.red == 1) high_entropy_first = true;
            if (cell.chars[0] == 'T' && cell.fg.rgb.red == 20) high_entropy_last = true;
        }
    assert(high_entropy_first && high_entropy_last);
    mica_session_destroy(styled_history);

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
#ifdef MICA_SESSION_TESTING
    assert(mica_session_fold_visible_rows(fold_session, 1, 3));
    size_t rows_before_failed_resize = mica_session_display_history_lines(fold_session);
    int fold_row_before_failed_resize = -1;
    for (int row = 0; row < mica_session_rows(fold_session); row++)
        if (mica_session_fold_info_at_view_row(fold_session, row, NULL)) {
            fold_row_before_failed_resize = row;
            break;
        }
    assert(fold_row_before_failed_resize >= 0);
    mica_session_test_fail_next_history_resize_allocation();
    assert(!mica_session_resize(fold_session, 6, 160));
    size_t failed_resize_fold_rows = 0;
    assert(mica_session_rows(fold_session) == 6 && mica_session_cols(fold_session) == 80);
    assert(mica_session_display_history_lines(fold_session) == rows_before_failed_resize);
    assert(mica_session_fold_info_at_view_row(fold_session, fold_row_before_failed_resize, &failed_resize_fold_rows));
    assert(failed_resize_fold_rows == 2);
    assert(mica_session_resize(fold_session, 6, 160));
    assert(mica_session_cols(fold_session) == 160);
    assert(!mica_session_fold_info_at_view_row(fold_session, 1, NULL));
#endif
    mica_session_destroy(fold_session);

    MicaSession *history_session = mica_session_create("/tmp",
        "perl -e 'for (1..5000) { printf \"STRESS-%05d\\n\", $_; } sleep 1'",
        6, 80);
    assert(history_session != NULL);
    for (int i = 0; i < 1000 && !screen_contains(history_session, "STRESS-05000"); i++)
        mica_session_poll(history_session, 10);
    assert(screen_contains(history_session, "STRESS-05000"));
    size_t history_bytes = mica_session_history_storage_bytes(history_session);
    assert(history_bytes <= MICA_HISTORY_LIMIT_BYTES);
    assert(mica_session_history_lines(history_session) > 0);
    assert(history_bytes < mica_session_history_lines(history_session) * 80u * sizeof(VTermScreenCell) / 2);
    // Once scrollback is full the monotonic counter keeps growing while the stored count stays capped.
    assert(mica_session_scrolled_lines(history_session) > mica_session_history_lines(history_session));
    long find_cursor = -1;
    assert(mica_session_find(history_session, "stress-05000", true, &find_cursor));
    find_cursor = -1;
    assert(mica_session_find(history_session, "STRESS-04950", true, &find_cursor));
    assert(mica_session_view_offset(history_session) > 0);
    find_cursor = -1;
    // Search must still see default spaces omitted from compact row storage.
    assert(mica_session_find(history_session, "STRESS-04950    ", true, &find_cursor));
    find_cursor = -1;
    assert(mica_session_find(history_session, "STRESS-04950    ", false, &find_cursor));
    find_cursor = -1;
    assert(!mica_session_find(history_session, "no-such-text-anywhere", true, &find_cursor));
    mica_session_clear_scrollback(history_session);
    assert(mica_session_history_lines(history_session) == 0);
    assert(mica_session_history_storage_bytes(history_session) == 0);
    mica_session_resize(history_session, 8, 160);
    history_bytes = mica_session_history_storage_bytes(history_session);
    assert(history_bytes <= MICA_HISTORY_LIMIT_BYTES);
    mica_session_destroy(history_session);

    MicaSession *resize_history_session = mica_session_create("/tmp",
        "printf 'LEFT-012345678901234567890123456789012345678901234567890123456789-RIGHT-END\\n\\n\\n\\n\\n\\n\\n'; sleep 1",
        6, 80);
    assert(resize_history_session != NULL);
    for (int i = 0; i < 300 && mica_session_history_lines(resize_history_session) == 0; i++)
        mica_session_poll(resize_history_session, 10);
    assert(mica_session_history_lines(resize_history_session) > 0);
    mica_session_scroll(resize_history_session, INT_MAX);
    assert(screen_contains(resize_history_session, "RIGHT-END"));
    mica_session_resize(resize_history_session, 6, 40);
    mica_session_resize(resize_history_session, 12, 40);
    mica_session_resize(resize_history_session, 12, 100);
    mica_session_scroll(resize_history_session, INT_MAX);
    assert(screen_contains(resize_history_session, "RIGHT-END"));
    mica_session_destroy(resize_history_session);
    // A larger allowance keeps early output reachable and searchable; a smaller one drops it. Restore the default after.
    mica_set_history_limit_lines(5000);
    MicaSession *long_history = mica_session_create("/tmp",
        "perl -e 'printf(\"LINE-%05d\\n\", $_) for 1..4000'; sleep 3", 24, 80);
    assert(long_history != NULL);
    for (int i = 0; i < 600 && !screen_contains(long_history, "LINE-04000"); i++) mica_session_poll(long_history, 10);
    for (int i = 0; i < 30; i++) mica_session_poll(long_history, 10);
    assert(mica_session_history_lines(long_history) >= 3900);
    long cursor_match = -1;
    assert(mica_session_find(long_history, "LINE-00001", true, &cursor_match));
    mica_session_scroll(long_history, 1000000);
    assert(screen_contains(long_history, "LINE-00001") || mica_session_scrolled_lines(long_history) > 3900);
    mica_session_destroy(long_history);
    mica_set_history_limit_lines(1000);
    MicaSession *short_history = mica_session_create("/tmp",
        "perl -e 'printf(\"LINE-%05d\\n\", $_) for 1..4000'; sleep 3", 24, 80);
    assert(short_history != NULL);
    for (int i = 0; i < 600 && !screen_contains(short_history, "LINE-04000"); i++) mica_session_poll(short_history, 10);
    for (int i = 0; i < 30; i++) mica_session_poll(short_history, 10);
    assert(mica_session_history_lines(short_history) <= 1000);
    long dropped = -1;
    assert(!mica_session_find(short_history, "LINE-00001", true, &dropped));
    mica_session_destroy(short_history);
    // Reused ring slots must release the larger Unicode representation when
    // subsequent dense scalar output replaces every retained row.
    // Odd capacity forces ring slots to alternate between interned and
    // expanded scalar rows as their sequence numbers wrap.
    mica_set_history_limit_lines(101);
    MicaSession *reuse_history = mica_session_create("/tmp",
        "exec perl -e '$|=1; for (1..300) { print \"e\\xcc\\x81\", \"x\" x 69, \"\\n\"; } "
        "print \"FULL-READY\\n\"; scalar <STDIN>; "
        "for (1..300) { print \"e\", \"x\" x 69, \"\\n\"; } "
        "print \"SCALAR-READY\\n\"; scalar <STDIN>; "
        "for (1..300) { print \"e\\xcc\\x81\", \"x\" x 69, \"\\n\"; } "
        "print \"FULL-AGAIN\\n\"; scalar <STDIN>; "
        "for (1..120) { if ($_ % 2) { printf(\"\\e[1;31mINDEXED-%03d\\e[0m\\n\", $_); } "
        "else { for my $j (1..20) { printf(\"\\e[38;2;%d;2;3m%c\", $j, 64 + $j); } "
        "print \"\\e[0m\\n\"; } } print \"PALETTE-READY\\n\"; scalar <STDIN>'", 6, 80);
    assert(reuse_history != NULL);
    for (int i = 0; i < 600 && !screen_contains(reuse_history, "FULL-READY"); i++)
        mica_session_poll(reuse_history, 10);
    assert(screen_contains(reuse_history, "FULL-READY"));
    size_t full_history_bytes = mica_session_history_storage_bytes(reuse_history);
    mica_session_write(reuse_history, "go\n", 3);
    for (int i = 0; i < 600 && !screen_contains(reuse_history, "SCALAR-READY"); i++)
        mica_session_poll(reuse_history, 10);
    assert(screen_contains(reuse_history, "SCALAR-READY"));
    size_t scalar_history_bytes = mica_session_history_storage_bytes(reuse_history);
    assert(scalar_history_bytes < full_history_bytes * 65 / 100);
    mica_session_write(reuse_history, "go\n", 3);
    for (int i = 0; i < 600 && !screen_contains(reuse_history, "FULL-AGAIN"); i++)
        mica_session_poll(reuse_history, 10);
    assert(screen_contains(reuse_history, "FULL-AGAIN"));
    assert(mica_session_history_storage_bytes(reuse_history) > scalar_history_bytes * 3 / 2);
    long reused_cursor = -1;
    assert(mica_session_find(reuse_history, "e\xcc\x81xxx", false, &reused_cursor));
    assert(reused_cursor < (long)mica_session_history_lines(reuse_history));
    mica_session_scroll(reuse_history, -INT_MAX);
    mica_session_write(reuse_history, "go\n", 3);
    for (int i = 0; i < 1200 && !screen_contains(reuse_history, "PALETTE-READY"); i++)
        mica_session_poll(reuse_history, 10);
    assert(screen_contains(reuse_history, "PALETTE-READY"));
    mica_session_scroll(reuse_history, INT_MAX);
    bool reused_interned = false, reused_expanded = false;
    for (int row = 0; row < mica_session_rows(reuse_history); row++)
        for (int col = 0; col < mica_session_cols(reuse_history); col++) {
            MicaCell cell;
            if (!mica_session_get_cell(reuse_history, row, col, &cell)) continue;
            if (cell.chars[0] == 'I' && cell.attrs.bold && VTERM_COLOR_IS_RGB(&cell.fg) &&
                cell.fg.rgb.red == 244 && cell.fg.rgb.green == 135 && cell.fg.rgb.blue == 113)
                reused_interned = true;
            if (cell.chars[0] == 'T' && VTERM_COLOR_IS_RGB(&cell.fg) && cell.fg.rgb.red == 20)
                reused_expanded = true;
        }
    assert(reused_interned && reused_expanded);
    mica_session_destroy(reuse_history);
    // Full Unicode cells plus OSC 8 metadata must share the history budget.
    MicaSession *linked_budget = mica_session_create("/tmp",
        "exec perl -e 'for (1..400) { print \"\\e]8;;https://example.test/budget\\e\\\\\", "
        "\"e\\xcc\\x81\" x 80, \"\\e]8;;\\e\\\\\\n\"; } "
        "print \"BUDGET-READY\\n\"; scalar <STDIN>'", 6, 80);
    assert(linked_budget != NULL);
    for (int i = 0; i < 600 && !screen_contains(linked_budget, "BUDGET-READY"); i++)
        mica_session_poll(linked_budget, 10);
    assert(screen_contains(linked_budget, "BUDGET-READY"));
    assert(mica_session_history_lines(linked_budget) > 0);
    assert(mica_session_history_storage_bytes(linked_budget) <= mica_history_limit_bytes());
    long budget_cursor = -1;
    assert(mica_session_find(linked_budget, "e\xcc\x81", false, &budget_cursor));
    assert(budget_cursor < (long)mica_session_history_lines(linked_budget));
    MicaCell budget_cell;
    assert(find_cell_starting_with(linked_budget, 'e', &budget_cell));
    assert(budget_cell.chars[0] == 'e' && budget_cell.chars[1] == 0x301);
    const char *budget_uri = mica_session_hyperlink_uri(linked_budget, budget_cell.hyperlink_id);
    assert(budget_uri && strcmp(budget_uri, "https://example.test/budget") == 0);
    mica_session_destroy(linked_budget);
    // Output must not move the row being read when the history ring is full.
    MicaSession *anchored_history = mica_session_create("/tmp",
        "exec perl -e '$|=1; printf \"ANCHOR-%05d\\n\", $_ for 1..150; "
        "print \"ANCHOR-READY\\n\"; scalar <STDIN>; "
        "printf \"ANCHOR-%05d\\n\", $_ for 151..160; "
        "print \"ANCHOR-MORE\\n\"; scalar <STDIN>; "
        "printf \"ANCHOR-%05d\\n\", $_ for 161..400; "
        "print \"ANCHOR-DONE\\n\"; scalar <STDIN>'", 6, 80);
    assert(anchored_history != NULL);
    for (int i = 0; i < 600 && !screen_contains(anchored_history, "ANCHOR-READY"); i++)
        mica_session_poll(anchored_history, 10);
    assert(screen_contains(anchored_history, "ANCHOR-READY"));
    mica_session_scroll(anchored_history, 30);
    MicaCell anchored_row[80];
    for (int col = 0; col < 80; col++)
        assert(mica_session_get_cell(anchored_history, 0, col, &anchored_row[col]));
    uint64_t before_anchor_output = mica_session_scrolled_lines(anchored_history);
    mica_session_write(anchored_history, "go\n", 3);
    // The readiness marker is offscreen while reading history; observe output
    // through the monotonic counter instead of scrolling back to the live view.
    for (int i = 0; i < 600 && mica_session_scrolled_lines(anchored_history) < before_anchor_output + 12; i++)
        mica_session_poll(anchored_history, 10);
    assert(mica_session_scrolled_lines(anchored_history) >= before_anchor_output + 12);
    for (int col = 0; col < 80; col++) {
        MicaCell cell;
        assert(mica_session_get_cell(anchored_history, 0, col, &cell));
        assert(memcmp(cell.chars, anchored_row[col].chars, sizeof(cell.chars)) == 0);
        assert(cell.width == anchored_row[col].width);
    }
    mica_session_write(anchored_history, "go\n", 3);
    for (int i = 0; i < 600 && mica_session_scrolled_lines(anchored_history) < before_anchor_output + 254; i++)
        mica_session_poll(anchored_history, 10);
    assert(mica_session_scrolled_lines(anchored_history) >= before_anchor_output + 254);
    assert(mica_session_view_offset(anchored_history) == (int)mica_session_display_history_lines(anchored_history));
    mica_session_scroll(anchored_history, -INT_MAX);
    assert(mica_session_view_offset(anchored_history) == 0);
    assert(screen_contains(anchored_history, "ANCHOR-DONE"));
    mica_session_destroy(anchored_history);
    // Ring replacement must retain the wrap flags for a later multirow URL.
    MicaSession *ring_wrap = mica_session_create("/tmp",
        "exec perl -e '$|=1; print \"OLD-$_\\n\" for 1..500; "
        "print \"https://example.test/abcdefghijklmnopqrstuvwxyz0123456789\\nHARD-RING\\n\", "
        "\"\\n\" x 10, \"RING-READY\\n\"; scalar <STDIN>'", 6, 24);
    assert(ring_wrap);
    for (int i = 0; i < 600 && !screen_contains(ring_wrap, "RING-READY"); i++)
        mica_session_poll(ring_wrap, 10);
    assert(screen_contains(ring_wrap, "RING-READY"));
    assert(mica_session_scrolled_lines(ring_wrap) > mica_session_history_lines(ring_wrap));
    long ring_cursor = -1;
    assert(mica_session_find(ring_wrap, "https://example.test/", false, &ring_cursor));
    assert(ring_cursor < (long)mica_session_history_lines(ring_wrap));
    int ring_row = (int)(ring_cursor - ((long)mica_session_history_lines(ring_wrap) -
        mica_session_view_offset(ring_wrap)));
    assert(ring_row >= 0 && ring_row + 3 < mica_session_rows(ring_wrap));
    assert(mica_session_row_continues(ring_wrap, ring_row + 1));
    assert(mica_session_row_continues(ring_wrap, ring_row + 2));
    assert(!mica_session_row_continues(ring_wrap, ring_row + 3));
    assert(mica_session_history_storage_bytes(ring_wrap) <= mica_history_limit_bytes());
    mica_session_destroy(ring_wrap);
    mica_set_history_limit_lines(MICA_HISTORY_LIMIT_BYTES / (80u * sizeof(VTermScreenCell)));
    printf("the scrollback allowance can grow to thousands of lines and shrink again\n");
    printf("scrollback allocation stays within %u bytes per session\n", MICA_HISTORY_LIMIT_BYTES);

    // A forged command marker (no per-session secret) must not change tab state.
    MicaSession *forge_session = mica_session_create("/tmp",
        "printf '\\033]777;mica;command-started;forged\\033\\\\FORGE-DONE\\n'; sleep 1", 6, 80);
    assert(forge_session != NULL);
    for (int i = 0; i < 300 && !screen_contains(forge_session, "FORGE-DONE"); i++)
        mica_session_poll(forge_session, 10);
    assert(screen_contains(forge_session, "FORGE-DONE"));
    assert(strcmp(mica_session_current_command(forge_session), "forged") != 0);
    mica_session_destroy(forge_session);
    printf("forged command markers are ignored\n");

    // Bracketed paste (mode 2004) is tracked so multi-line pastes can be confirmed when it is off.
    MicaSession *bracketed_session = mica_session_create("/tmp",
        "printf '\\033[?2004hPASTE-ON'; sleep 2", 6, 80);
    assert(bracketed_session != NULL);
    for (int i = 0; i < 300 && !screen_contains(bracketed_session, "PASTE-ON"); i++)
        mica_session_poll(bracketed_session, 10);
    assert(mica_session_bracketed_paste(bracketed_session));
    mica_session_destroy(bracketed_session);
    printf("bracketed paste mode is tracked\n");

    // Full-screen programs enter the alternate screen; the tab spinner keys off this.
    MicaSession *alt_session = mica_session_create("/tmp",
        "printf 'PLAIN'; sleep 0.3; printf '\\033[?1049hALT-ON'; sleep 2", 6, 80);
    assert(alt_session != NULL);
    assert(!mica_session_alt_screen(alt_session));
    for (int i = 0; i < 300 && !screen_contains(alt_session, "ALT-ON"); i++)
        mica_session_poll(alt_session, 10);
    assert(mica_session_alt_screen(alt_session));
    mica_session_destroy(alt_session);
    printf("alternate screen is tracked\n");

    // Switching to the light theme repaints existing ANSI colours from the light palette.
    MicaSession *theme_session = mica_session_create("/tmp", "printf '\\033[31mRED\\033[0m'; sleep 2", 6, 80);
    assert(theme_session != NULL);
    for (int i = 0; i < 300 && !screen_contains(theme_session, "RED"); i++)
        mica_session_poll(theme_session, 10);
    MicaCell red_cell;
    assert(mica_session_get_cell(theme_session, 0, 0, &red_cell));
    VTermColor dark_red = red_cell.fg;
    mica_session_set_light_theme(theme_session, true);
    assert(mica_session_get_cell(theme_session, 0, 0, &red_cell));
    assert(VTERM_COLOR_IS_RGB(&red_cell.fg) && red_cell.fg.rgb.red == 0xcf && red_cell.fg.rgb.green == 0x22);
    assert(!(VTERM_COLOR_IS_RGB(&dark_red) && dark_red.rgb.red == 0xcf));
    mica_session_destroy(theme_session);
    printf("light theme swaps the ANSI palette\n");

    // Notification text from OSC 9 / 777 is kept for the app to show; control characters are removed.
    MicaSession *notify_session = mica_session_create("/tmp",
        "printf '\\033]9;Build finished\\007NOTE1\\n'; sleep 0.3; printf '\\033]777;notify;Codex;Needs your input\\033\\\\NOTE2\\n'; sleep 2", 6, 80);
    assert(notify_session != NULL);
    for (int i = 0; i < 300 && !screen_contains(notify_session, "NOTE2"); i++)
        mica_session_poll(notify_session, 10);
    char *note = mica_session_take_notification(notify_session);
    assert(note != NULL && strcmp(note, "Codex: Needs your input") == 0);
    free(note);
    assert(mica_session_take_notification(notify_session) == NULL);
    mica_session_destroy(notify_session);
    printf("agent notification text is captured\n");

    // A missing start folder falls back to the nearest existing parent, decided before fork.
    MicaSession *missing_folder_session = mica_session_create("/tmp/mica-no-such-folder-xyz/sub", "pwd; sleep 1", 6, 100);
    assert(missing_folder_session != NULL);
    for (int i = 0; i < 300 && !screen_contains(missing_folder_session, "using /tmp"); i++)
        mica_session_poll(missing_folder_session, 10);
    assert(screen_contains(missing_folder_session, "cannot enter /tmp/mica-no-such-folder-xyz/sub"));
    assert(screen_contains(missing_folder_session, "using /tmp"));
    mica_session_destroy(missing_folder_session);
    printf("a missing start folder falls back to the nearest parent\n");

    // Synchronized output (mode 2026): a frame is held back until it ends, so it is never seen half drawn.
    MicaSession *sync_session = mica_session_create("/tmp",
        "printf 'OLD-FRAME\\033[?2026h\\033[2J\\033[HFRAME-PART'; sleep 0.6; printf '-DONE\\033[?2026l'; sleep 2", 6, 80);
    assert(sync_session != NULL);
    for (int i = 0; i < 300 && !screen_contains(sync_session, "OLD-FRAME"); i++)
        mica_session_poll(sync_session, 10);
    for (int i = 0; i < 20; i++) mica_session_poll(sync_session, 10);
    assert(mica_session_sync_output_active(sync_session));
    assert(screen_contains(sync_session, "OLD-FRAME"));   // still the previous frame
    assert(!screen_contains(sync_session, "FRAME-PART"));
    for (int i = 0; i < 300 && !screen_contains(sync_session, "FRAME-PART-DONE"); i++)
        mica_session_poll(sync_session, 10);
    assert(screen_contains(sync_session, "FRAME-PART-DONE"));
    assert(!screen_contains(sync_session, "OLD-FRAME"));
    assert(!mica_session_sync_output_active(sync_session));
    mica_session_destroy(sync_session);
    // A begin marker split across two reads is still recognized.
    MicaSession *split_session = mica_session_create("/tmp",
        "stty -echo; printf 'BEFORE\\033[?20'; IFS= read -r release; printf '26hSPLIT-FRAME'; stty echo; sleep 2", 6, 80);
    assert(split_session != NULL);
    for (int i = 0; i < 300 && !screen_contains(split_session, "BEFORE"); i++)
        mica_session_poll(split_session, 10);
    assert(screen_contains(split_session, "BEFORE"));
    mica_session_write(split_session, "\n", 1);
    for (int i = 0; i < 300 && !mica_session_sync_output_active(split_session); i++)
        mica_session_poll(split_session, 10);
    assert(mica_session_sync_output_active(split_session));
    assert(!screen_contains(split_session, "SPLIT-FRAME"));
    mica_session_destroy(split_session);
    // A frame that never ends is released after a second instead of freezing the screen.
    MicaSession *stuck_session = mica_session_create("/tmp",
        "printf '\\033[?2026hSTUCK-FRAME'; sleep 3", 6, 80);
    assert(stuck_session != NULL);
    for (int i = 0; i < 300 && !screen_contains(stuck_session, "STUCK-FRAME"); i++)
        mica_session_poll(stuck_session, 10);
    assert(screen_contains(stuck_session, "STUCK-FRAME"));
    mica_session_destroy(stuck_session);
    printf("synchronized output frames are held until they end\n");

    // OSC 52 writes surface as clipboard text; queries never answer.
    MicaSession *clip_session = mica_session_create("/tmp",
        "printf '\\033]52;c;aGVsbG8gbWljYQ==\\007CLIPDONE\\n'; sleep 1", 6, 80);
    assert(clip_session != NULL);
    for (int i = 0; i < 300 && !screen_contains(clip_session, "CLIPDONE"); i++)
        mica_session_poll(clip_session, 10);
    char *clip_text = mica_session_take_clipboard_write(clip_session);
    assert(clip_text != NULL && strcmp(clip_text, "hello mica") == 0);
    free(clip_text);
    assert(mica_session_take_clipboard_write(clip_session) == NULL);
    mica_session_destroy(clip_session);
    printf("OSC 52 clipboard writes are captured for the app to approve\n");

    // The shell environment is built before fork: NO_COLOR is removed, Mica's variables are set,
    // and a missing locale gets a UTF-8 fallback.
    char *saved_no_startup = copy_env("MICA_TEST_NO_STARTUP");
    char *saved_no_color = copy_env("NO_COLOR");
    char *saved_lang = copy_env("LANG");
    char *saved_lc_all = copy_env("LC_ALL");
    char *saved_lc_ctype = copy_env("LC_CTYPE");
    assert(setenv("MICA_TEST_NO_STARTUP", "1", 1) == 0);
    assert(setenv("NO_COLOR", "1", 1) == 0);
    unsetenv("LANG"); unsetenv("LC_ALL"); unsetenv("LC_CTYPE");
    MicaSession *env_session = mica_session_create("/tmp",
        "printf 'ENVCHECK[%s][%s][%s][%s]\\n' \"$TERM_PROGRAM\" \"${NO_COLOR-unset}\" \"$COLORTERM\" \"$LANG\"; sleep 1",
        6, 100);
    assert(env_session != NULL);
    for (int i = 0; i < 300 && !screen_contains(env_session, "ENVCHECK["); i++)
        mica_session_poll(env_session, 10);
    assert(screen_contains(env_session, "ENVCHECK[Mica][unset][truecolor][en_US.UTF-8]"));
    mica_session_destroy(env_session);
    restore_env("MICA_TEST_NO_STARTUP", saved_no_startup);
    restore_env("NO_COLOR", saved_no_color);
    restore_env("LANG", saved_lang);
    restore_env("LC_ALL", saved_lc_all);
    restore_env("LC_CTYPE", saved_lc_ctype);
    printf("child shell environment is prepared before fork\n");

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
    for (int i = 0; i < 3000 && !screen_contains(prefilled_claude, "claude --continue"); i++)
        mica_session_poll(prefilled_claude, 10);
    assert(screen_contains(prefilled_claude, "claude --continue"));
    assert(!screen_contains(prefilled_claude, "MICA-CLAUDE:"));
    mica_session_key(prefilled_claude, VTERM_KEY_ENTER, VTERM_MOD_NONE);
    for (int i = 0; i < 3000 && !screen_contains(prefilled_claude, "MICA-CLAUDE:"); i++)
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

    char custom_zdotdir[PATH_MAX], custom_zprofile_path[PATH_MAX];
    char custom_zshrc_path[PATH_MAX], custom_zlogin_path[PATH_MAX], custom_zcompdump_path[PATH_MAX];
    char custom_zcompdump_compiled_path[PATH_MAX], profile_zshenv_path[PATH_MAX];
    assert(snprintf(custom_zdotdir, sizeof(custom_zdotdir), "%s/custom-zdotdir", profile_dir) > 0);
    assert(mkdir(custom_zdotdir, 0700) == 0);
    assert(snprintf(profile_zshenv_path, sizeof(profile_zshenv_path), "%s/.zshenv", profile_dir) > 0);
    assert(snprintf(custom_zprofile_path, sizeof(custom_zprofile_path), "%s/.zprofile", custom_zdotdir) > 0);
    assert(snprintf(custom_zshrc_path, sizeof(custom_zshrc_path), "%s/.zshrc", custom_zdotdir) > 0);
    assert(snprintf(custom_zlogin_path, sizeof(custom_zlogin_path), "%s/.zlogin", custom_zdotdir) > 0);
    assert(snprintf(custom_zcompdump_path, sizeof(custom_zcompdump_path), "%s/.zcompdump", custom_zdotdir) > 0);
    assert(snprintf(custom_zcompdump_compiled_path, sizeof(custom_zcompdump_compiled_path),
        "%s/.zcompdump.zwc", custom_zdotdir) > 0);
    char custom_zshenv_contents[PATH_MAX + 32];
    assert(snprintf(custom_zshenv_contents, sizeof(custom_zshenv_contents),
        "export ZDOTDIR='%s'\n", custom_zdotdir) > 0);
    write_test_file(profile_zshenv_path, custom_zshenv_contents, 0600);
    write_test_file(custom_zprofile_path, "export MICA_CUSTOM_PROFILE=loaded\n", 0600);
    write_test_file(custom_zshrc_path, "export MICA_CUSTOM_RC=loaded\n", 0600);
    write_test_file(custom_zlogin_path, "export MICA_CUSTOM_LOGIN=loaded\n", 0600);
    MicaSession *custom_zdot_session = mica_session_create(profile_dir,
        "printf 'MICA-CUSTOM-ZDOTDIR:%s|%s|%s\\n' \"$MICA_CUSTOM_PROFILE\" \"$MICA_CUSTOM_RC\" \"$MICA_CUSTOM_LOGIN\"; sleep 0.5",
        8, 120);
    assert(custom_zdot_session != NULL);
    for (int i = 0; i < 500 && !screen_contains(custom_zdot_session, "MICA-CUSTOM-ZDOTDIR:"); i++)
        mica_session_poll(custom_zdot_session, 10);
    if (!screen_contains(custom_zdot_session, "MICA-CUSTOM-ZDOTDIR:loaded|loaded|loaded"))
        print_screen(custom_zdot_session);
    assert(screen_contains(custom_zdot_session, "MICA-CUSTOM-ZDOTDIR:loaded|loaded|loaded"));
    mica_session_destroy(custom_zdot_session);
    unlink(profile_zshenv_path);
    unlink(custom_zprofile_path);
    unlink(custom_zshrc_path);
    unlink(custom_zlogin_path);
    unlink(custom_zcompdump_path);
    unlink(custom_zcompdump_compiled_path);
    assert(rmdir(custom_zdotdir) == 0);

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
    mica_session_write(zsh_completion_session, "unset CLAUDECODE && sleep 1.5\n",
                       strlen("unset CLAUDECODE && sleep 1.5\n"));
    bool command_started = false;
    for (int i = 0; i < 400 && !command_started; i++) {
        mica_session_poll(zsh_completion_session, 10);
        command_started = strcmp(mica_session_current_command(zsh_completion_session), "sleep") == 0;
    }
    assert(command_started);
    for (int i = 0; i < 600 &&
         (mica_session_command_completion_count(zsh_completion_session) == completion_baseline ||
          mica_session_current_command(zsh_completion_session)[0] != '\0'); i++)
        mica_session_poll(zsh_completion_session, 10);
    assert(mica_session_command_completion_count(zsh_completion_session) > completion_baseline);
    assert(mica_session_current_command(zsh_completion_session)[0] == '\0');
    assert(mica_session_osc133_count(zsh_completion_session) >= 4);
    assert(mica_session_osc133_state(zsh_completion_session) == 'A' ||
           mica_session_osc133_state(zsh_completion_session) == 'C' ||
           mica_session_osc133_state(zsh_completion_session) == 'D');
    mica_session_destroy(zsh_completion_session);

    MicaSession *completion_session = mica_session_create(profile_dir, "sleep 0.5; false", 8, 120);
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
