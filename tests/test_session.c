#define _DARWIN_C_SOURCE
#include "mica.h"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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

static void poll_for(MicaSession *session, unsigned milliseconds) {
    for (unsigned elapsed = 0; elapsed < milliseconds; elapsed += 10) {
        mica_session_poll(session, 10);
    }
}

int main(void) {
    setenv("MICA_TEST_NO_STARTUP", "1", 1);
    MicaSession *session = mica_session_create("/tmp", "i=1; while [ $i -le 20 ]; do printf 'row-%02d\\n' $i; i=$((i+1)); done; printf '\\033[31mRED-TEXT\\033[0m\\n'; printf '\\033[?1049h\\033[?1000hALT-BUFFER'; printf '\\007'; printf '\\033]9;Codex done\\007'; printf '\\033]9;4;1;42\\007'; printf '\\033]777;notify;Claude;Needs input\\033\\\\'; sleep 1; printf '\\033[?1000l\\033[?1049l'", 6, 32);
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
    mica_session_scroll_to_bottom(session);
    assert(mica_session_view_offset(session) == 0);

    for (int i = 0; i < 200 && mica_session_reports_mouse(session); i++) mica_session_poll(session, 10);
    assert(!mica_session_reports_mouse(session));
    assert(screen_contains(session, "row-20"));
    assert(screen_contains(session, "RED-TEXT"));

    for (int row = 0; row < mica_session_rows(session); row++) {
        for (int col = 0; col < mica_session_cols(session); col++) {
            MicaCell cell;
            if (mica_session_get_cell(session, row, col, &cell) && cell.chars[0] == 'R') {
                assert(VTERM_COLOR_IS_RGB(&cell.fg));
                assert(cell.fg.rgb.red > cell.fg.rgb.green * 2);
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

    MicaSession *exit_session = mica_session_create("/tmp", "printf 'EXIT-READY\\n'; sleep 0.1", 6, 80);
    assert(exit_session != NULL);
    for (int i = 0; i < 500 && !screen_contains(exit_session, "[command exited: 0]"); i++) mica_session_poll(exit_session, 10);
    assert(screen_contains(exit_session, "[command exited: 0]"));
    mica_session_write(exit_session, "exit\n", 5);
    for (int i = 0; i < 100 && mica_session_is_running(exit_session); i++) mica_session_poll(exit_session, 10);
    assert(!mica_session_is_running(exit_session));
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

    puts("session tests passed");
    return 0;
}
