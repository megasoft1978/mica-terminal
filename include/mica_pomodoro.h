#ifndef MICA_POMODORO_H
#define MICA_POMODORO_H

#include <stdbool.h>
#include <stdint.h>

typedef enum {
    MICA_POMODORO_IDLE = 0,
    MICA_POMODORO_FOCUS,
    MICA_POMODORO_BREAK,
    MICA_POMODORO_PAUSED_FOCUS,
    MICA_POMODORO_PAUSED_BREAK,
} MicaPomodoroPhase;

typedef struct {
    MicaPomodoroPhase phase;
    double deadline;
    double paused_remaining;
    uint64_t completed_focuses;
} MicaPomodoro;

void mica_pomodoro_reset(MicaPomodoro *timer);
bool mica_pomodoro_start(MicaPomodoro *timer, double now, double focus_seconds);
bool mica_pomodoro_toggle_pause(MicaPomodoro *timer, double now);
bool mica_pomodoro_advance(MicaPomodoro *timer, double now,
                           double focus_seconds, double break_seconds);
bool mica_pomodoro_advance_with_options(MicaPomodoro *timer, double now,
                           double focus_seconds, double break_seconds,
                           bool auto_start_break, bool auto_start_focus);
double mica_pomodoro_remaining(const MicaPomodoro *timer, double now);
bool mica_pomodoro_is_running(const MicaPomodoro *timer);
bool mica_pomodoro_is_paused(const MicaPomodoro *timer);

#endif
