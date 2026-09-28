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
    assert(timer.phase == MICA_POMODORO_IDLE && timer.completed_focuses == 0);
    assert(!mica_pomodoro_start(&timer, 0, 0));
    puts("Pomodoro timer tests passed");
    return 0;
}
