#include "mica_pomodoro.h"

#include <math.h>
#include <string.h>

void mica_pomodoro_reset(MicaPomodoro *timer) {
    if (timer) memset(timer, 0, sizeof(*timer));
}

bool mica_pomodoro_start(MicaPomodoro *timer, double now, double focus_seconds) {
    if (!timer || !isfinite(now) || !isfinite(focus_seconds) || focus_seconds <= 0 ||
        timer->phase != MICA_POMODORO_IDLE) return false;
    timer->phase = MICA_POMODORO_FOCUS;
    timer->deadline = now + focus_seconds;
    timer->paused_remaining = 0;
    return true;
}

bool mica_pomodoro_toggle_pause(MicaPomodoro *timer, double now) {
    if (!timer || !isfinite(now)) return false;
    if (timer->phase == MICA_POMODORO_FOCUS || timer->phase == MICA_POMODORO_BREAK) {
        timer->paused_remaining = fmax(0, timer->deadline - now);
        timer->phase = timer->phase == MICA_POMODORO_FOCUS
            ? MICA_POMODORO_PAUSED_FOCUS : MICA_POMODORO_PAUSED_BREAK;
        return true;
    }
    if (timer->phase == MICA_POMODORO_PAUSED_FOCUS || timer->phase == MICA_POMODORO_PAUSED_BREAK) {
        timer->deadline = now + fmax(0, timer->paused_remaining);
        timer->paused_remaining = 0;
        timer->phase = timer->phase == MICA_POMODORO_PAUSED_FOCUS
            ? MICA_POMODORO_FOCUS : MICA_POMODORO_BREAK;
        return true;
    }
    return false;
}

bool mica_pomodoro_advance(MicaPomodoro *timer, double now,
                           double focus_seconds, double break_seconds) {
    return mica_pomodoro_advance_with_options(timer, now, focus_seconds, break_seconds, true, true);
}

bool mica_pomodoro_advance_with_options(MicaPomodoro *timer, double now,
                           double focus_seconds, double break_seconds,
                           bool auto_start_break, bool auto_start_focus) {
    if (!timer || !isfinite(now) || !isfinite(focus_seconds) || !isfinite(break_seconds) ||
        focus_seconds <= 0 || break_seconds <= 0 || now < timer->deadline) return false;
    if (timer->phase == MICA_POMODORO_FOCUS) {
        timer->completed_focuses++;
        timer->phase = auto_start_break ? MICA_POMODORO_BREAK : MICA_POMODORO_PAUSED_BREAK;
        timer->deadline = auto_start_break ? now + break_seconds : 0;
        timer->paused_remaining = auto_start_break ? 0 : break_seconds;
        return true;
    }
    if (timer->phase == MICA_POMODORO_BREAK) {
        timer->phase = auto_start_focus ? MICA_POMODORO_FOCUS : MICA_POMODORO_PAUSED_FOCUS;
        timer->deadline = auto_start_focus ? now + focus_seconds : 0;
        timer->paused_remaining = auto_start_focus ? 0 : focus_seconds;
        return true;
    }
    return false;
}

double mica_pomodoro_remaining(const MicaPomodoro *timer, double now) {
    if (!timer) return 0;
    if (timer->phase == MICA_POMODORO_PAUSED_FOCUS || timer->phase == MICA_POMODORO_PAUSED_BREAK)
        return fmax(0, timer->paused_remaining);
    if (timer->phase == MICA_POMODORO_FOCUS || timer->phase == MICA_POMODORO_BREAK)
        return fmax(0, timer->deadline - now);
    return 0;
}

bool mica_pomodoro_is_running(const MicaPomodoro *timer) {
    return timer && (timer->phase == MICA_POMODORO_FOCUS || timer->phase == MICA_POMODORO_BREAK);
}

bool mica_pomodoro_is_paused(const MicaPomodoro *timer) {
    return timer && (timer->phase == MICA_POMODORO_PAUSED_FOCUS ||
                     timer->phase == MICA_POMODORO_PAUSED_BREAK);
}
