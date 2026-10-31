#ifndef MICA_FOCUS_LOG_H
#define MICA_FOCUS_LOG_H
#include <stdbool.h>
#include <stddef.h>
typedef struct MicaFocusLog MicaFocusLog;
typedef struct MicaFocusLogEntry {
    char project[129];
    char branch[129];
    double seconds;
    unsigned sessions;
} MicaFocusLogEntry;
MicaFocusLog *mica_focus_log_new(void);
void mica_focus_log_free(MicaFocusLog *log);
bool mica_focus_log_add(MicaFocusLog *log, const char *day_key, const char *project, const char *branch, double seconds);
double mica_focus_log_total_for_day(const MicaFocusLog *log, const char *day_key);
size_t mica_focus_log_entries_for_day(const MicaFocusLog *log, const char *day_key, MicaFocusLogEntry *out, size_t cap);
char *mica_focus_log_to_json(const MicaFocusLog *log);
bool mica_focus_log_from_json(MicaFocusLog *log, const char *json, size_t len);
bool mica_focus_log_save(const MicaFocusLog *log, const char *path);
bool mica_focus_log_load(MicaFocusLog *log, const char *path);
#endif
