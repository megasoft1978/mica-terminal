// Stress and fuzz test for the session core. Feeds random bytes and random escape sequences through a real
// PTY and hammers the public API (resize, scroll, find, folds, paste, clear) between reads. Meant to be run
// under AddressSanitizer and UBSan (`make sanitize`); success is "no crash and no sanitizer report".
#include "mica.h"

#include <assert.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static unsigned int rng_state = 1;
static unsigned int next_random(void) { rng_state = rng_state * 1664525u + 1013904223u; return rng_state >> 8; }
static int between(int low, int high) { return low + (int)(next_random() % (unsigned)(high - low + 1)); }

// Touch every public read path so a corrupted internal state shows up as a sanitizer error.
static void read_everything(MicaSession *session) {
    int rows = mica_session_rows(session), cols = mica_session_cols(session);
    for (int row = 0; row < rows; row++) {
        for (int col = 0; col < cols; col++) {
            MicaCell cell;
            (void)mica_session_get_cell(session, row, col, &cell);
        }
        size_t hidden = 0;
        (void)mica_session_fold_info_at_view_row(session, row, &hidden);
    }
    MicaDirtyRows dirty;
    (void)mica_session_take_dirty_rows(session, &dirty);
    char *clip = mica_session_take_clipboard_write(session);
    free(clip);
    (void)mica_session_history_lines(session);
    (void)mica_session_scrolled_lines(session);
    (void)mica_session_display_history_lines(session);
    (void)mica_session_view_offset(session);
    int cursor_row, cursor_col;
    mica_session_cursor(session, &cursor_row, &cursor_col);
}

static void poke(MicaSession *session) {
    switch (between(0, 13)) {
    case 0: mica_session_resize(session, between(1, 80), between(1, 300)); break;
    case 1: mica_session_resize_pixels(session, between(1, 60), between(2, 200), between(1, 3000), between(1, 2000)); break;
    case 2: mica_session_scroll(session, between(-500, 500)); break;
    case 3: mica_session_scroll(session, between(0, 1) ? INT_MAX : -INT_MAX); break;
    case 4: mica_session_scroll_to_bottom(session); break;
    case 5: { long cursor = -1; (void)mica_session_find(session, between(0, 1) ? "a" : "zz", between(0, 1), &cursor); break; }
    case 6: mica_session_clear_scrollback(session); break;
    case 7: (void)mica_session_fold_visible_rows(session, between(0, 10), between(0, 40)); break;
    case 8: (void)mica_session_toggle_fold_at_view_row(session, between(0, 30)); break;
    case 9: { char text[64]; for (int i = 0; i < 63; i++) text[i] = (char)between(1, 255); mica_session_paste(session, text, 63); break; }
    case 10: mica_session_mouse(session, between(-2, 100), between(-2, 300), between(0, 4), between(0, 1)); break;
    case 11: mica_session_key(session, (VTermKey)between(1, 20), (VTermModifier)between(0, 7)); break;
    case 12: mica_session_text(session, (uint32_t)between(0, 0x10ffff), (VTermModifier)between(0, 7)); break;
    case 13: mica_session_focus(session, between(0, 1)); mica_session_wheel(session, between(0, 50), between(0, 100), between(-1, 1)); break;
    }
    read_everything(session);
}

static void run_case(const char *label, const char *command, int iterations) {
    MicaSession *session = mica_session_create("/tmp", command, between(2, 40), between(2, 200));
    assert(session != NULL);
    for (int i = 0; i < iterations; i++) {
        mica_session_poll(session, 2);
        if (i % 3 == 0) poke(session);
    }
    read_everything(session);
    mica_session_destroy(session);
    printf("fuzz ok: %s\n", label);
}

int main(int argc, char **argv) {
    unsigned int seed = argc > 1 ? (unsigned)strtoul(argv[1], NULL, 10) : (unsigned)time(NULL);
    rng_state = seed;
    printf("fuzz seed %u\n", seed);
    setenv("MICA_TEST_NO_STARTUP", "1", 1);

    // Exactly one codepoint slot remains when an incomplete UTF-8 lead is followed by ASCII.
    // The decoder must emit U+FFFD and leave the ASCII byte for the next call without overrunning tmpbuffer.
    run_case("UTF-8 replacement at the final codepoint slot",
        "perl -e '$|=1; print \"A\" x 1023, \"\\xC2\".\"B\"'; sleep 1", 100);
    // Pure random bytes: exercises UTF-8 decoding, control characters and unknown sequences.
    // perl with a fixed srand keeps the byte stream identical for a given seed, so failures replay.
    char random_command[256];
    snprintf(random_command, sizeof(random_command),
        "perl -e 'srand(%u); $|=1; print pack(\"C*\", map { int(rand(256)) } 1..600000)'; sleep 1", seed);
    run_case("random bytes", random_command, 400);
    // Random but well-formed escape sequences with extreme parameters, OSC strings, and DCS/APC payloads.
    run_case("random escape sequences",
        "perl -e 'srand(" "7" "); my @t=(\"\\e[\",\"\\e]\",\"\\eP\",\"\\e_\",\"\\e^\",\"\\eX\",\"\\e(\",\"\\e#\"); "
        "for(1..40000){ print $t[rand @t]; print join(\";\", map { int(rand(70000)) } 1..int(rand(6))); "
        "print chr(32+int(rand(95))); print chr(7) if rand()<.1; print \"\\e\\\\\" if rand()<.1; print chr(int(rand(256))) if rand()<.2; }'; sleep 1", 400);
    // Random OSC 133 phases, unknown parameters and oversized decimal statuses.
    run_case("random OSC 133 payloads",
        "perl -e '$|=1; @p=(\"A\",\"B\",\"C\",\"D;0\",\"D;999999999999999999999\",\"Q;garbage\"); "
        "for(1..12000){ $x=$p[int(rand(@p))]; print \"\\e]133;$x\\e\\\\\"; }'; sleep 1", 500);
    // Heavy scrolling with wide, combining and invalid UTF-8 mixed in.
    run_case("scroll and unicode",
        "perl -e 'for(1..6000){ print \"line $_ \\x{1F469}\\x{200D}\\x{1F4BB} e\\x{301} \\x{FFFD} \\xc3\\x28 \\x{4E2D}\\x{6587}\\n\"; }'; sleep 1", 600);
    // Mode toggles: alt screen, mouse, bracketed paste, sync output, scroll regions, resize while in each.
    run_case("modes",
        "perl -e 'for(1..800){ print \"\\e[?1049h\\e[?1000h\\e[?2004h\\e[?2026h\\e[1;\".int(rand(30)).\"r\"; print \"x\" x int(rand(400)); "
        "print \"\\e[?2026l\\e[?1049l\\e[r\\e[3J\\e[2J\\e[H\"; print \"\\e]52;c;\".(\"QUJD\" x int(rand(900))).\"\\a\"; print \"\\e]8;;http://a/\".int(rand(9)).\"\\e\\\\link\\e]8;;\\e\\\\\"; }'; sleep 1", 600);
    // Synchronized-output frames with the begin/end markers cut at every possible byte position, mixed with
    // scrolling, alternate-screen switches and the whole poke() API (resize, find, fold, clear) in between.
    run_case("sync markers split at random points",
        "perl -e 'srand(11); $|=1; @m=(\"\\e[?2026h\",\"\\e[?2026l\"); for(1..1500){ $x=$m[int(rand(2))]; "
        "$c=int(rand(length($x)+1)); print substr($x,0,$c); print \"filler \" x int(rand(40)) if rand()<.4; print substr($x,$c); "
        "print \"\\n\" x int(rand(5)); print \"\\e[?1049\".(rand()<.5?\"h\":\"l\") if rand()<.2; print \"line $_\\n\" }'; sleep 1", 800);
    run_case("sync frames with clears and scrolling",
        "perl -e '$|=1; for $i (1..600){ print \"\\e[?2026h\\e[2J\\e[H\"; print \"row $_\\n\" for 1..int(rand(60)); "
        "print \"\\e[?2026l\"; print \"after $i\\n\" x int(rand(3)); }'; sleep 1", 800);
    // Regression for sync_hold lifetime: force scrollback reallocations while one large synchronized frame
    // is still buffered, then append and release the frame. This caught history_push freeing sync_hold.
    run_case("sync hold survives scrollback growth",
        "perl -e '$|=1; print \"\\e[?2026h\"; for(1..12000){ print \"sync-scroll-$_\\n\"; } "
        "print \"\\e[?2026l\"'; sleep 1", 3000);
    // A frame that never ends and grows past the hold limit must be released, not grow without bound.
    run_case("unterminated oversized sync frame",
        "perl -e '$|=1; print \"\\e[?2026h\"; print \"x\" x 65536, \"\\n\" for 1..90'; sleep 1", 600);
    // Alternate-screen programs that exit without leaving, redraw constantly, and get resized mid-frame.
    run_case("full-screen program churn",
        "perl -e '$|=1; for $i (1..400){ print \"\\e[?1049h\\e[?25l\\e[?2026h\\e[H\\e[2J\"; print \"TUI \" x int(rand(200)); "
        "print \"\\e[?2026l\"; print \"\\e[?1049l\" if rand()<.5; }'; sleep 1", 800);
    // A large scrollback allowance with heavy output, resizes and searches in between (ring growth and reflow paths).
    mica_set_history_limit_lines(20000);
    run_case("large scrollback",
        "perl -e '$|=1; for(1..30000){ print \"line $_ \" . (\"x\" x int(rand(150))) . \"\\n\" }'; sleep 1", 1200);
    mica_set_history_limit_lines(MICA_HISTORY_LIMIT_BYTES / (80u * sizeof(VTermScreenCell)));
    // Session churn: create and destroy quickly.
    for (int i = 0; i < 25; i++) {
        MicaSession *session = mica_session_create("/tmp", "printf 'hi\\n'; sleep 5", between(1, 30), between(1, 100));
        assert(session != NULL);
        mica_session_poll(session, 5);
        poke(session);
        mica_session_destroy(session);
    }
    printf("fuzz ok: session churn\n");
    printf("all fuzz cases passed (seed %u)\n", seed);
    return 0;
}
