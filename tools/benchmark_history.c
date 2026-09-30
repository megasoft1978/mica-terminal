#include "mica.h"
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static double milliseconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec * 1000.0 + now.tv_nsec / 1000000.0;
}

int main(void) {
    if (setenv("MICA_TEST_NO_STARTUP", "1", 1) != 0) return 1;
    const char *commands[] = {
        "exec perl -e 'for (1..20000) { printf \"ROW-%05d\\n\", $_ }'",
        "exec perl -e 'for (1..20000) { printf \"ROW-%05d %s\\n\", $_, \"x\" x 60 }'",
        "exec perl -e 'for (1..20000) { printf \"\\e]8;;https://example.test/\\e\\\\ROW-%05d\\e]8;;\\e\\\\\\n\", $_ }'"
    };
    const char *names[] = {"short", "dense", "linked"};
    mica_set_history_limit_lines(20000);
    puts("case,columns,retained_rows,history_bytes,output_ms,search_miss_ms,resize_ms");
    for (int cols = 80; cols <= 200; cols += 120) {
        for (int kind = 0; kind < 3; kind++) {
            MicaSession *session = mica_session_create("/tmp", commands[kind], 24, cols);
            if (!session) return 1;
            double start = milliseconds();
            while (mica_session_is_running(session) && milliseconds() - start < 30000)
                mica_session_poll(session, 1);
            double output_ms = milliseconds() - start;
            if (mica_session_is_running(session) || mica_session_exit_status(session) != 0) {
                fprintf(stderr, "benchmark child failed or timed out: %s/%d\n", names[kind], cols);
                mica_session_destroy(session);
                return 1;
            }
            long cursor = -1;
            if (!mica_session_find(session, "ROW-20000", true, &cursor)) {
                fprintf(stderr, "output incomplete: %s/%d\n", names[kind], cols);
                mica_session_destroy(session);
                return 1;
            }
            size_t rows = mica_session_history_lines(session);
            size_t bytes = mica_session_history_storage_bytes(session);
            start = milliseconds();
            for (int repeat = 0; repeat < 10; repeat++) {
                cursor = -1;
                if (mica_session_find(session, "not-present-in-history", true, &cursor)) {
                    mica_session_destroy(session);
                    return 1;
                }
            }
            double search_ms = (milliseconds() - start) / 10;
            start = milliseconds();
            mica_session_resize(session, 24, cols / 2);
            mica_session_resize(session, 24, cols);
            double resize_ms = milliseconds() - start;
            printf("%s,%d,%zu,%zu,%.3f,%.3f,%.3f\n",
                names[kind], cols, rows, bytes, output_ms, search_ms, resize_ms);
            mica_session_destroy(session);
        }
    }
    return 0;
}
