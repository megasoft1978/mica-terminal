#include "mica_pomodoro.h"

#include <assert.h>
#include <math.h>
#include <stdio.h>

int main(void) {
    MicaPomodoro timer = {0};
    assert(timer.phase == MICA_POMODORO_IDLE);
    assert(mica_pomodoro_start(&timer, 100, 60));
    assert(timer.phase == MICA_POMODORO_FOCUS);
    assert(fabs(mica_pomodoro_remaining(&timer, 100) - 60) < 0.001);
    assert(!mica_pomodoro_advance(&timer, 159.9, 60, 15));
    assert(mica_pomodoro_advance(&timer, 160, 60, 15));
    assert(timer.phase == MICA_POMODORO_BREAK && timer.completed_focuses == 1);
    assert(fabs(mica_pomodoro_remaining(&timer, 160) - 15) < 0.001);
    assert(mica_pomodoro_advance(&timer, 175, 60, 15));
    assert(timer.phase == MICA_POMODORO_FOCUS && timer.completed_focuses == 1);

    assert(mica_pomodoro_toggle_pause(&timer, 190));
    assert(timer.phase == MICA_POMODORO_PAUSED_FOCUS);
    assert(fabs(mica_pomodoro_remaining(&timer, 300) - 45) < 0.001);
    assert(mica_pomodoro_toggle_pause(&timer, 500));
    assert(timer.phase == MICA_POMODORO_FOCUS && timer.deadline == 545);
    assert(mica_pomodoro_advance(&timer, 600, 60, 15));
    assert(timer.phase == MICA_POMODORO_BREAK);
    assert(timer.deadline == 615); // A delayed wake starts a full break when noticed.

    mica_pomodoro_reset(&timer);
    assert(mica_pomodoro_start(&timer, 0, 10));
    assert(mica_pomodoro_advance_with_options(&timer, 10, 10, 5, false, true));
    assert(timer.phase == MICA_POMODORO_PAUSED_BREAK && timer.completed_focuses == 1);
    assert(fabs(mica_pomodoro_remaining(&timer, 100) - 5) < 0.001);
    assert(mica_pomodoro_toggle_pause(&timer, 20));
    assert(timer.phase == MICA_POMODORO_BREAK && timer.deadline == 25);
    assert(mica_pomodoro_advance_with_options(&timer, 25, 10, 5, true, false));
    assert(timer.phase == MICA_POMODORO_PAUSED_FOCUS && timer.completed_focuses == 1);
    assert(fabs(mica_pomodoro_remaining(&timer, 100) - 10) < 0.001);

    // A late timer wake still holds the complete next interval when auto-start is off.
    mica_pomodoro_reset(&timer);
    assert(mica_pomodoro_start(&timer, 0, 10));
    assert(mica_pomodoro_advance_with_options(&timer, 500, 10, 5, false, true));
    assert(timer.phase == MICA_POMODORO_PAUSED_BREAK && timer.deadline == 0);
    assert(fabs(mica_pomodoro_remaining(&timer, 500) - 5) < 0.001);

    // Skip is an explicit clock injection: moving the deadline to now advances immediately.
    mica_pomodoro_reset(&timer);
    assert(mica_pomodoro_start(&timer, 1000, 60));
    timer.deadline = 1012;
    assert(mica_pomodoro_advance(&timer, 1012, 60, 15));
    assert(timer.phase == MICA_POMODORO_BREAK && timer.completed_focuses == 1);
    timer.deadline = 1013;
    assert(mica_pomodoro_advance(&timer, 1013, 60, 15));
    assert(timer.phase == MICA_POMODORO_FOCUS && timer.completed_focuses == 1);

    // An expired focus advances once; the caller can persist the paused next phase on relaunch.
    mica_pomodoro_reset(&timer);
    assert(mica_pomodoro_start(&timer, 2000, 10));
    assert(mica_pomodoro_advance_with_options(&timer, 2010, 10, 5, false, true));
    assert(timer.phase == MICA_POMODORO_PAUSED_BREAK && timer.completed_focuses == 1);
    assert(fabs(mica_pomodoro_remaining(&timer, 9000) - 5) < 0.001);

    mica_pomodoro_reset(&timer);
    assert(timer.phase == MICA_POMODORO_IDLE && timer.completed_focuses == 0);
    assert(!mica_pomodoro_start(&timer, 0, 0));
    puts("Pomodoro timer tests passed");
    return 0;
}
