#ifndef MICA_HOOK_H
#define MICA_HOOK_H
#include <stdbool.h>
#include <stddef.h>

#define MICA_HOOK_LINE_MAX 16384
#define MICA_HOOK_STRING_MAX 4096
typedef struct {
    char token[33], event[128], session_id[MICA_HOOK_STRING_MAX + 1];
    char cwd[MICA_HOOK_STRING_MAX + 1], notification_type[128];
    char message[MICA_HOOK_STRING_MAX + 1], last_assistant_message[MICA_HOOK_STRING_MAX + 1];
    char agent[16], tool_name[256];
} MicaHookEvent;

// Parses one complete JSON object line. Output is fixed-size and zeroed on failure.
bool mica_hook_parse(const char *json, size_t length, MicaHookEvent *event);
#endif
