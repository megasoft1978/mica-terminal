#include "mica_agent_detect.h"
#include <ctype.h>
#include <string.h>

static int classify_token(const char *token) {
    const char *base = strrchr(token, '/'); base = base ? base + 1 : token;
    size_t n = strlen(base);
    if (!strcmp(base, "claude") || !strcmp(base, "claude-code") ||
        (!strcmp(base, "codex") || !strcmp(base, "codex.js")))
        return base[0] == 'c' && base[1] == 'l' ? 1 : 2;
    if (strstr(token, "/node_modules/@anthropic-ai/claude-code/") || !strcmp(token, "@anthropic-ai/claude-code")) return 1;
    if (strstr(token, "/node_modules/@openai/codex/") || !strcmp(token, "@openai/codex")) return 2;
    (void)n;
    return 0;
}

int mica_agent_kind_from_commands(const char *lines) {
    if (!lines) return 0;
    char copy[8192]; size_t n = strlen(lines); if (n >= sizeof(copy)) n = sizeof(copy)-1;
    memcpy(copy, lines, n); copy[n] = 0;
    for (char *line = strtok(copy, "\n"); line; line = strtok(NULL, "\n")) {
        char *save = NULL;
        for (char *token = strtok_r(line, " \t\r", &save); token; token = strtok_r(NULL, " \t\r", &save)) {
            int kind = classify_token(token);
            if (kind) return kind;
        }
    }
    return 0;
}
