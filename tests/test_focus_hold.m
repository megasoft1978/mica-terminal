#import <Foundation/Foundation.h>
#import "mica_focus_hold.h"

static int failures = 0;
#define CHECK(...) do { if (!(__VA_ARGS__)) { fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #__VA_ARGS__); failures++; } } while (0)

int main(void) {
    @autoreleasepool {
        MicaFocusHold *hold = [MicaFocusHold new];
        CHECK(!hold.holding);
        CHECK(![hold shouldHoldKind:MicaAttentionDone]);
        MicaPomodoroPhase idle[] = { MICA_POMODORO_IDLE, MICA_POMODORO_BREAK, MICA_POMODORO_PAUSED_BREAK };
        for (int i = 0; i < 3; i++) {
            [hold setPhase:idle[i]];
            CHECK(!hold.holding);
            CHECK(![hold shouldHoldKind:MicaAttentionDone]);
            CHECK(![hold shouldHoldKind:MicaAttentionError]);
            CHECK(![hold shouldHoldKind:MicaAttentionWaitingInput]);
        }
        [hold setPhase:MICA_POMODORO_FOCUS];
        CHECK(hold.holding);
        CHECK([hold shouldHoldKind:MicaAttentionDone]);
        CHECK([hold shouldHoldKind:MicaAttentionError]);
        CHECK([hold shouldHoldKind:MicaAttentionWaitingInput]);
        CHECK(![hold shouldHoldKind:MicaAttentionWaitingPermission]);
        CHECK(![hold shouldHoldKind:MicaAttentionTimerEnd]);
        CHECK(![hold shouldHoldKind:MicaAttentionHighMemory]);
        // Pausing a focus session releases the hold.
        [hold setPhase:MICA_POMODORO_PAUSED_FOCUS];
        CHECK(!hold.holding);
        CHECK(![hold shouldHoldKind:MicaAttentionDone]);

        // Leaving focus does not auto-clear.
        [hold setPhase:MICA_POMODORO_FOCUS];
        [hold queueKind:MicaAttentionDone tabID:1 title:@"a"];
        [hold setPhase:MICA_POMODORO_BREAK];
        CHECK(!hold.holding);
        MicaFocusHoldSummary *s = [hold releaseSummary];
        CHECK(s.finished.count == 1 && !s.isEmpty);
        CHECK([s.text isEqualToString:@"1 finished"]);
        CHECK([hold releaseSummary].isEmpty);
        CHECK([[hold releaseSummary].text isEqualToString:@""]);

        // Ordering + categories + dedupe (waiting > error > finished).
        [hold queueKind:MicaAttentionDone tabID:10 title:@"ten"];
        [hold queueKind:MicaAttentionError tabID:20 title:@"twenty"];
        [hold queueKind:MicaAttentionWaitingInput tabID:30 title:@"thirty"];
        [hold queueKind:MicaAttentionDone tabID:40 title:@"forty"];
        [hold queueKind:MicaAttentionTimerEnd tabID:50 title:@"ignored"];
        [hold queueKind:MicaAttentionDone tabID:20 title:@"twenty-b"];      // lower: keeps error
        [hold queueKind:MicaAttentionError tabID:10 title:@"ten-b"];         // upgrade finished -> error
        [hold queueKind:MicaAttentionWaitingInput tabID:10 title:@"ten-c"];  // upgrade -> waiting
        [hold queueKind:MicaAttentionError tabID:30 title:@"thirty-b"];      // lower: keeps waiting
        s = [hold releaseSummary];
        CHECK(s.finished.count == 1 && s.finished[0].tabID == 40 && [s.finished[0].title isEqualToString:@"forty"]);
        CHECK(s.waiting.count == 2 && s.waiting[0].tabID == 10 && s.waiting[1].tabID == 30);
        CHECK([s.waiting[0].title isEqualToString:@"ten-c"]);
        CHECK(s.errors.count == 1 && s.errors[0].tabID == 20 && [s.errors[0].title isEqualToString:@"twenty-b"]);
        CHECK([s.text isEqualToString:@"1 finished · 2 waiting · 1 error"]);
        CHECK([hold releaseSummary].isEmpty);

        // Plural / singular.
        for (uint64_t t = 1; t <= 2; t++) { [hold queueKind:MicaAttentionDone tabID:t title:@"x"]; [hold queueKind:MicaAttentionError tabID:t + 10 title:@"x"]; }
        CHECK([[hold releaseSummary].text isEqualToString:@"2 finished · 2 errors"]);
        [hold queueKind:MicaAttentionWaitingPermission tabID:9 title:@"p"];
        CHECK([[hold releaseSummary].text isEqualToString:@"1 waiting"]);

        // forgetTabID.
        [hold queueKind:MicaAttentionDone tabID:1 title:@"a"];
        [hold queueKind:MicaAttentionDone tabID:2 title:@"b"];
        [hold forgetTabID:1];
        [hold forgetTabID:99];
        s = [hold releaseSummary];
        CHECK(s.finished.count == 1 && s.finished[0].tabID == 2);

        // Cap: 128 distinct, oldest dropped.
        for (uint64_t t = 1; t <= 130; t++) [hold queueKind:MicaAttentionDone tabID:t title:@"t"];
        s = [hold releaseSummary];
        CHECK(s.finished.count == 128);
        CHECK(s.finished[0].tabID == 3 && s.finished[127].tabID == 130);
        CHECK([s.text isEqualToString:@"128 finished"]);
    }
    if (failures) { fprintf(stderr, "%d focus hold test failure(s)\n", failures); return 1; }
    puts("focus hold tests passed");
    return 0;
}
