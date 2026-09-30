// Direct regressions for the continuation-aware libvterm callback backport.
#include <vterm.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>

typedef struct {
    int count;
    int legacy_count;
    int pop_count;
    int popped_destination_row[16];
    bool continuation[16];
    char text[16][9];
} Capture;

static int push_legacy(int cols, const VTermScreenCell *cells, void *user) {
    (void)cols; (void)cells;
    ((Capture *)user)->legacy_count++;
    return 1;
}

static int push_continuation(int cols, const VTermScreenCell *cells, bool continuation, void *user) {
    Capture *capture = user;
    assert(capture->count < 16 && cols == 8);
    int row = capture->count++;
    capture->continuation[row] = continuation;
    for (int col = 0; col < cols; col++)
        capture->text[row][col] = cells[col].chars[0] ? (char)cells[col].chars[0] : ' ';
    capture->text[row][cols] = 0;
    return 1;
}

static int pop_continuation_common(int cols, VTermScreenCell *cells, bool *continuation,
                                   int destination_row, void *user) {
    Capture *capture = user;
    if (!capture->count) return 0;
    int row = --capture->count;
    assert(cols == 8);
    assert(capture->pop_count < 16);
    capture->popped_destination_row[capture->pop_count++] = destination_row;
    *continuation = capture->continuation[row];
    for (int col = 0; col < cols; col++) {
        cells[col] = (VTermScreenCell){0};
        cells[col].width = 1;
        cells[col].chars[0] = (unsigned char)capture->text[row][col];
    }
    return 1;
}

static int pop_continuation(int cols, VTermScreenCell *cells, bool *continuation, void *user) {
    return pop_continuation_common(cols, cells, continuation, -1, user);
}

static int pop_continuation_with_row(int cols, VTermScreenCell *cells, bool *continuation,
                                     int destination_row, void *user) {
    return pop_continuation_common(cols, cells, continuation, destination_row, user);
}

static int pop_legacy(int cols, VTermScreenCell *cells, void *user) {
    bool ignored;
    return pop_continuation_common(cols, cells, &ignored, -1, user);
}

static void feed(VTerm *vt, VTermScreen *screen, const char *text) {
    assert(vterm_input_write(vt, text, strlen(text)) == strlen(text));
    vterm_screen_flush_damage(screen);
}

static void check_callbacks(VTermDamageSize mode, bool enabled, bool legacy) {
    Capture capture = {0};
    VTerm *vt = vterm_new(3, 8);
    assert(vt);
    VTermScreen *screen = vterm_obtain_screen(vt);
    VTermScreenCallbacks callbacks = {
        .sb_pushline = legacy ? push_legacy : NULL,
        .sb_pushline4 = push_continuation,
    };
    vterm_screen_set_callbacks(screen, &callbacks, &capture);
    if (enabled) vterm_screen_callbacks_has_pushline4(screen);
    vterm_screen_enable_altscreen(screen, 1);
    vterm_screen_set_damage_merge(screen, mode);
    vterm_screen_reset(screen, 1);
    feed(vt, screen, "abcdefghij\r\nHARD\r\nEND\r\nLAST\r\n");
    if (enabled) {
        assert(capture.count == 3 && capture.legacy_count == 0);
        assert(!capture.continuation[0] && capture.continuation[1] && !capture.continuation[2]);
        assert(strcmp(capture.text[0], "abcdefgh") == 0);
        assert(strcmp(capture.text[1], "ij      ") == 0);
        assert(strcmp(capture.text[2], "HARD    ") == 0);
    } else {
        assert(capture.count == 0 && capture.legacy_count == 3);
    }
    int count = capture.count, legacy_count = capture.legacy_count;
    feed(vt, screen, "\033[?1049hALT\r\nALT\r\nALT\r\nALT\r\n\033[?1049l");
    assert(capture.count == count && capture.legacy_count == legacy_count);
    feed(vt, screen, "\033[2;3r\033[3;1HREGION\r\nREGION\r\n");
    assert(capture.count == count && capture.legacy_count == legacy_count);
    vterm_free(vt);
}

static void check_resize(bool enabled, bool legacy, bool destination_row) {
    Capture capture = {0};
    VTerm *vt = vterm_new(3, 8);
    assert(vt);
    VTermScreen *screen = vterm_obtain_screen(vt);
    VTermScreenCallbacks callbacks = {
        .sb_pushline4 = push_continuation,
        .sb_popline = legacy ? pop_legacy : NULL,
        .sb_popline4 = pop_continuation,
        .sb_popline5 = pop_continuation_with_row,
    };
    vterm_screen_set_callbacks(screen, &callbacks, &capture);
    vterm_screen_callbacks_has_pushline4(screen);
    if (enabled) vterm_screen_callbacks_has_popline4(screen);
    if (destination_row) vterm_screen_callbacks_has_popline5(screen);
    vterm_screen_reset(screen, 1);
    feed(vt, screen, "abcdefghij\r\nHARD");
    assert(capture.count == 0);
    vterm_set_size(vt, 1, 8);
    vterm_screen_flush_damage(screen);
    assert(capture.count == 2);
    assert(!capture.continuation[0] && capture.continuation[1]);
    assert(strcmp(capture.text[0], "abcdefgh") == 0);
    assert(strcmp(capture.text[1], "ij      ") == 0);
    vterm_set_size(vt, 3, 8);
    vterm_screen_flush_damage(screen);
    assert(capture.count == 0);
    if (enabled || destination_row) {
        assert(capture.pop_count == 2);
        if (destination_row) {
            assert(capture.popped_destination_row[0] == 1);
            assert(capture.popped_destination_row[1] == 0);
        } else {
            assert(capture.popped_destination_row[0] == -1);
            assert(capture.popped_destination_row[1] == -1);
        }
    }
    VTermState *state = vterm_obtain_state(vt);
    assert(!vterm_state_get_lineinfo(state, 0)->continuation);
    assert(vterm_state_get_lineinfo(state, 1)->continuation == enabled);
    assert(!vterm_state_get_lineinfo(state, 2)->continuation);
    VTermScreenCell cell;
    assert(vterm_screen_get_cell(screen, (VTermPos){0, 0}, &cell) && cell.chars[0] == 'a');
    assert(vterm_screen_get_cell(screen, (VTermPos){1, 0}, &cell) && cell.chars[0] == 'i');
    assert(vterm_screen_get_cell(screen, (VTermPos){2, 0}, &cell) && cell.chars[0] == 'H');
    vterm_free(vt);
}

static void check_wrapped_group_shrink(void) {
    Capture capture = {0};
    VTerm *vt = vterm_new(8, 8);
    assert(vt);
    VTermScreen *screen = vterm_obtain_screen(vt);
    VTermScreenCallbacks callbacks = {
        .sb_pushline4 = push_continuation,
        .sb_popline4 = pop_continuation,
        .sb_popline5 = pop_continuation_with_row,
    };
    vterm_screen_set_callbacks(screen, &callbacks, &capture);
    vterm_screen_callbacks_has_pushline4(screen);
    vterm_screen_callbacks_has_popline4(screen);
    vterm_screen_callbacks_has_popline5(screen);
    vterm_screen_enable_reflow(screen, true);
    vterm_screen_reset(screen, 1);
    feed(vt, screen, "abcdefghijabcdefghijabcdefghij\r\nHARD\r\nTAIL\r\n");
    vterm_set_size(vt, 4, 8);
    vterm_screen_flush_damage(screen);
    assert(capture.count > 0);
    vterm_set_size(vt, 8, 8);
    vterm_screen_flush_damage(screen);
    assert(capture.count == 0);
    const char *expected = "abcdefghijabcdefghijabcdefghij";
    for (int index = 0; index < 30; index++) {
        VTermScreenCell cell;
        assert(vterm_screen_get_cell(screen, (VTermPos){index / 8, index % 8}, &cell));
        assert(cell.chars[0] == (unsigned char)expected[index]);
    }
    for (int row = 1; row < 4; row++)
        assert(vterm_state_get_lineinfo(vterm_obtain_state(vt), row)->continuation);
    assert(!vterm_state_get_lineinfo(vterm_obtain_state(vt), 4)->continuation);
    vterm_free(vt);
}

int main(void) {
    VTermDamageSize modes[] = {VTERM_DAMAGE_CELL, VTERM_DAMAGE_ROW, VTERM_DAMAGE_SCROLL};
    for (size_t i = 0; i < sizeof(modes) / sizeof(modes[0]); i++) {
        check_callbacks(modes[i], false, true);
        check_callbacks(modes[i], true, true);
        check_callbacks(modes[i], true, false);
    }
    check_resize(false, true, false);
    check_resize(true, true, false);
    check_resize(true, false, false);
    check_resize(true, true, true);
    check_resize(true, false, true);
    check_wrapped_group_shrink();
    puts("libvterm continuation callback tests passed");
    return 0;
}
