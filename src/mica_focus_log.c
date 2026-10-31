#define _POSIX_C_SOURCE 200809L
#include "mica_focus_log.h"
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define MAX_DAYS 30
#define MAX_ENTRIES 64
#define MAX_JSON (1024u * 1024u)
typedef struct { char key[9]; size_t count; MicaFocusLogEntry entries[MAX_ENTRIES]; } Day;
struct MicaFocusLog { size_t count; Day days[MAX_DAYS]; };
MicaFocusLog *mica_focus_log_new(void) { return calloc(1, sizeof(MicaFocusLog)); }
void mica_focus_log_free(MicaFocusLog *log) { free(log); }
static bool valid_day(const char *s) {
    if (!s || strlen(s) != 8) return false;
    for (int i = 0; i < 8; i++) if (s[i] < '0' || s[i] > '9') return false;
    return true;
}
/* Retain only complete UTF-8 sequences; malformed input is rejected. */
static bool copy_name(char dst[129], const char *src) {
    size_t n = 0; bool full = false; const unsigned char *p = (const unsigned char *)src;
    if (!src) return false;
    while (*p) {
        size_t k; unsigned c = *p;
        if (c < 0x80) k = 1;
        else if (c >= 0xc2 && c <= 0xdf) k = 2;
        else if (c >= 0xe0 && c <= 0xef) k = 3;
        else if (c >= 0xf0 && c <= 0xf4) k = 4;
        else return false;
        for (size_t j = 1; j < k; j++) if (!p[j] || (p[j] & 0xc0) != 0x80) return false;
        if ((c == 0xe0 && p[1] < 0xa0) || (c == 0xed && p[1] >= 0xa0) || (c == 0xf0 && p[1] < 0x90) || (c == 0xf4 && p[1] >= 0x90)) return false;
        if (!full && n + k <= 128) { memcpy(dst + n, p, k); n += k; }
        else full = true;
        p += k;
    }
    dst[n] = 0; return true;
}
static Day *find_day(MicaFocusLog *log, const char *key) {
    for (size_t i = 0; i < log->count; i++) if (!strcmp(log->days[i].key, key)) return &log->days[i];
    return NULL;
}
static bool insert(MicaFocusLog *log, const char *key, const char *project, const char *branch, double seconds, unsigned sessions) {
    char p[129], b[129]; Day *d;
    if (!log || !valid_day(key) || !project || !copy_name(p, project) || !copy_name(b, branch ? branch : "") || !isfinite(seconds) || seconds <= 0 || !sessions) return false;
    d = find_day(log, key);
    if (!d) {
        if (log->count == MAX_DAYS) {
            size_t oldest = 0;
            for (size_t i = 1; i < log->count; i++) if (strcmp(log->days[i].key, log->days[oldest].key) < 0) oldest = i;
            if (strcmp(key, log->days[oldest].key) < 0) return true;
            d = &log->days[oldest];
        } else d = &log->days[log->count++];
        memset(d, 0, sizeof(*d)); memcpy(d->key, key, 9);
    }
    MicaFocusLogEntry *e = NULL;
    for (size_t i = 0; i < d->count; i++) if (!strcmp(d->entries[i].project, p) && !strcmp(d->entries[i].branch, b)) { e = &d->entries[i]; break; }
    if (!e && d->count == MAX_ENTRIES) {
        for (size_t i = 0; i < d->count; i++) if (!strcmp(d->entries[i].project, "Other") && !d->entries[i].branch[0]) { e = &d->entries[i]; break; }
        if (!e) {
            e = &d->entries[MAX_ENTRIES - 1];
            if (!isfinite(e->seconds + seconds) || UINT_MAX - e->sessions < sessions) return false;
            strcpy(e->project, "Other"); e->branch[0] = 0;
        }
    }
    if (!e) { e = &d->entries[d->count++]; memset(e, 0, sizeof(*e)); strcpy(e->project, p); strcpy(e->branch, b); }
    if (!isfinite(e->seconds + seconds) || UINT_MAX - e->sessions < sessions) return false;
    e->seconds += seconds; e->sessions += sessions; return true;
}
bool mica_focus_log_add(MicaFocusLog *log, const char *day, const char *project, const char *branch, double seconds) {
    if (!isfinite(seconds) || seconds <= 0 || seconds > 86400) return false;
    return insert(log, day, project, branch, seconds, 1);
}
double mica_focus_log_total_for_day(const MicaFocusLog *log, const char *key) {
    double total = 0; if (!log || !valid_day(key)) return 0;
    for (size_t i = 0; i < log->count; i++) if (!strcmp(log->days[i].key, key)) for (size_t j = 0; j < log->days[i].count; j++) total += log->days[i].entries[j].seconds;
    return total;
}
static int entry_cmp(const void *a, const void *b) {
    const MicaFocusLogEntry *x = a, *y = b;
    if (x->seconds != y->seconds) return x->seconds > y->seconds ? -1 : 1;
    int c = strcmp(x->project, y->project); return c ? c : strcmp(x->branch, y->branch);
}
size_t mica_focus_log_entries_for_day(const MicaFocusLog *log, const char *key, MicaFocusLogEntry *out, size_t cap) {
    if (!log || !valid_day(key)) return 0;
    for (size_t i = 0; i < log->count; i++) if (!strcmp(log->days[i].key, key)) {
        MicaFocusLogEntry sorted[MAX_ENTRIES]; size_t n = log->days[i].count;
        memcpy(sorted, log->days[i].entries, n * sizeof(*sorted)); qsort(sorted, n, sizeof(*sorted), entry_cmp);
        if (out) memcpy(out, sorted, (cap < n ? cap : n) * sizeof(*out)); return n;
    }
    return 0;
}
typedef struct { char *p; size_t len, cap; bool ok; } Buffer;
static void append(Buffer *b, const char *s, size_t n) {
    if (!b->ok || n > SIZE_MAX - b->len - 1) { b->ok = false; return; }
    if (b->len + n + 1 > b->cap) {
        size_t cap = b->cap ? b->cap : 256; while (cap < b->len + n + 1) { if (cap > SIZE_MAX / 2) { b->ok = false; return; } cap *= 2; }
        char *p = realloc(b->p, cap); if (!p) { b->ok = false; return; } b->p = p; b->cap = cap;
    }
    memcpy(b->p + b->len, s, n); b->len += n; b->p[b->len] = 0;
}
static void literal(Buffer *b, const char *s) { append(b, s, strlen(s)); }
static void string_json(Buffer *b, const char *s) {
    literal(b, "\""); for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        if (*p == '"' || *p == '\\') { char c[2] = {'\\', (char)*p}; append(b, c, 2); }
        else if (*p < 32) { char c[7]; snprintf(c, sizeof(c), "\\u%04x", *p); append(b, c, 6); }
        else append(b, (const char *)p, 1);
    } literal(b, "\"");
}
/* Discover printf's decimal separator without changing or querying the locale. */
static bool decimal_separator(char sep[32], size_t *len) {
    char probe[40]; int n = snprintf(probe, sizeof(probe), "%.1f", 1.5);
    if (n < 3 || (size_t)n >= sizeof(probe) || probe[0] != '1' || probe[n - 1] != '5' || n - 2 >= 32) return false;
    *len = (size_t)n - 2; memcpy(sep, probe + 1, *len); sep[*len] = 0; return true;
}
static bool json_double(char *out, size_t size, double value) {
    char raw[128], sep[32]; size_t sep_len;
    int n = snprintf(raw, sizeof(raw), "%.17g", value);
    if (n < 0 || (size_t)n >= sizeof(raw) || !decimal_separator(sep, &sep_len)) return false;
    char *point = strstr(raw, sep);
    if (!point) { if ((size_t)n >= size) return false; memcpy(out, raw, (size_t)n + 1); return true; }
    size_t prefix = (size_t)(point - raw), suffix = strlen(point + sep_len);
    if (prefix + 1 + suffix >= size) return false;
    memcpy(out, raw, prefix); out[prefix] = '.'; memcpy(out + prefix + 1, point + sep_len, suffix + 1); return true;
}
char *mica_focus_log_to_json(const MicaFocusLog *log) {
    if (!log) return NULL; Buffer b = { .ok = true }; literal(&b, "{\"version\":1,\"days\":{");
    for (size_t i = 0; i < log->count; i++) {
        const Day *d = &log->days[i]; if (i) literal(&b, ","); string_json(&b, d->key); literal(&b, ":[");
        for (size_t j = 0; j < d->count; j++) {
            const MicaFocusLogEntry *e = &d->entries[j]; char num[160], value[128]; if (j) literal(&b, ",");
            literal(&b, "{\"project\":"); string_json(&b, e->project); literal(&b, ",\"branch\":"); string_json(&b, e->branch);
            if (!json_double(value, sizeof(value), e->seconds)) { b.ok = false; break; }
            snprintf(num, sizeof(num), ",\"seconds\":%s,\"sessions\":%u}", value, e->sessions); literal(&b, num);
        } literal(&b, "]");
    } literal(&b, "}}"); if (!b.ok) { free(b.p); return NULL; } return b.p;
}
typedef struct { const char *p, *end; } Parser;
static void ws(Parser *p) { while (p->p < p->end && (*p->p == ' ' || *p->p == '\n' || *p->p == '\r' || *p->p == '\t')) p->p++; }
static bool take(Parser *p, char c) { ws(p); if (p->p == p->end || *p->p != c) return false; p->p++; return true; }
static int hex(char c) { if (c >= '0' && c <= '9') return c-'0'; if (c >= 'a' && c <= 'f') return c-'a'+10; if (c >= 'A' && c <= 'F') return c-'A'+10; return -1; }
static bool codepoint(Parser *p, unsigned *v) {
    if (p->end - p->p < 4) return false; *v = 0;
    for (int i = 0; i < 4; i++) { int h = hex(*p->p++); if (h < 0) return false; *v = *v * 16 + (unsigned)h; } return true;
}
static char *parse_string(Parser *p) {
    if (!take(p, '"')) return NULL; Buffer b = {.ok = true};
    while (p->p < p->end && *p->p != '"') {
        unsigned char c = (unsigned char)*p->p++; if (c < 32) goto fail;
        if (c != '\\') { append(&b, (const char *)&c, 1); continue; }
        if (p->p == p->end) goto fail; c = (unsigned char)*p->p++;
        if (c == '"' || c == '\\' || c == '/') append(&b, (const char *)&c, 1);
        else if (c == 'b' || c == 'f' || c == 'n' || c == 'r' || c == 't') { char v = c == 'b' ? '\b' : c == 'f' ? '\f' : c == 'n' ? '\n' : c == 'r' ? '\r' : '\t'; append(&b, &v, 1); }
        else if (c == 'u') {
            unsigned v; if (!codepoint(p, &v)) goto fail;
            if (v >= 0xd800 && v <= 0xdbff) { unsigned low; if (p->end - p->p < 6 || p->p[0] != '\\' || p->p[1] != 'u') goto fail; p->p += 2; if (!codepoint(p, &low) || low < 0xdc00 || low > 0xdfff) goto fail; v = 0x10000 + ((v-0xd800) << 10) + low-0xdc00; }
            else if (v >= 0xdc00 && v <= 0xdfff) goto fail;
            if (!v) goto fail;
            char buf[4]; size_t n;
            if (v < 0x80) { buf[0] = (char)v; n = 1; }
            else if (v < 0x800) { buf[0] = (char)(0xc0 | v >> 6); buf[1] = (char)(0x80 | (v & 63)); n = 2; }
            else if (v < 0x10000) { buf[0] = (char)(0xe0 | v >> 12); buf[1] = (char)(0x80 | ((v >> 6) & 63)); buf[2] = (char)(0x80 | (v & 63)); n = 3; }
            else { buf[0] = (char)(0xf0 | v >> 18); buf[1] = (char)(0x80 | ((v >> 12) & 63)); buf[2] = (char)(0x80 | ((v >> 6) & 63)); buf[3] = (char)(0x80 | (v & 63)); n = 4; } append(&b, buf, n);
        } else goto fail;
    }
    if (p->p == p->end || !b.ok) goto fail; p->p++; if (!b.p) { b.p = calloc(1, 1); if (!b.p) return NULL; } return b.p;
fail: free(b.p); return NULL;
}
static bool number(Parser *p, double *out, bool integer) {
    ws(p); const char *start = p->p;
    if (p->p < p->end && *p->p == '-') p->p++;
    if (p->p == p->end) return false;
    if (*p->p == '0') p->p++; else { if (*p->p < '1' || *p->p > '9') return false; while (p->p < p->end && *p->p >= '0' && *p->p <= '9') p->p++; }
    if (p->p < p->end && *p->p == '.') { if (integer) return false; p->p++; const char *s = p->p; while (p->p < p->end && *p->p >= '0' && *p->p <= '9') p->p++; if (s == p->p) return false; }
    if (p->p < p->end && (*p->p == 'e' || *p->p == 'E')) { if (integer) return false; p->p++; if (p->p < p->end && (*p->p == '+' || *p->p == '-')) p->p++; const char *s = p->p; while (p->p < p->end && *p->p >= '0' && *p->p <= '9') p->p++; if (s == p->p) return false; }
    size_t len = (size_t)(p->p - start); if (len > 127) return false;
    char buf[160], sep[32]; size_t sep_len; if (!decimal_separator(sep, &sep_len)) return false;
    const char *dot = memchr(start, '.', len); size_t used = len;
    if (dot) { size_t prefix = (size_t)(dot - start); used = len - 1 + sep_len; if (used >= sizeof(buf)) return false; memcpy(buf, start, prefix); memcpy(buf + prefix, sep, sep_len); memcpy(buf + prefix + sep_len, dot + 1, len - prefix - 1); }
    else memcpy(buf, start, len);
    buf[used] = 0; char *end; errno = 0; *out = strtod(buf, &end); return end == buf + used && isfinite(*out);
}
static bool parse_entry(Parser *p, MicaFocusLog *log, const char *day) {
    char *project = NULL, *branch = NULL; double seconds = 0, sessions = 0; unsigned seen = 0; bool ok = false;
    if (!take(p, '{')) return false;
    do {
        char *key = parse_string(p); if (!key || !take(p, ':')) { free(key); goto done; }
        unsigned bit = !strcmp(key, "project") ? 1 : !strcmp(key, "branch") ? 2 : !strcmp(key, "seconds") ? 4 : !strcmp(key, "sessions") ? 8 : 0; free(key);
        if (!bit || (seen & bit)) goto done; seen |= bit;
        if (bit == 1) { project = parse_string(p); if (!project) goto done; }
        else if (bit == 2) { branch = parse_string(p); if (!branch) goto done; }
        else if (!number(p, bit == 4 ? &seconds : &sessions, bit == 8)) goto done;
        ws(p); if (p->p < p->end && *p->p == ',') { p->p++; continue; } break;
    } while (true);
    if (seen != 15 || !take(p, '}') || sessions < 1 || sessions > UINT_MAX || seconds > 86400.0 * sessions) goto done;
    ok = insert(log, day, project, branch, seconds, (unsigned)sessions);
done: free(project); free(branch); return ok;
}
static bool parse_days(Parser *p, MicaFocusLog *log) {
    if (!take(p, '{')) return false; ws(p); if (take(p, '}')) return true;
    do {
        char *day = parse_string(p); if (!day || !valid_day(day) || !take(p, ':') || !take(p, '[')) { free(day); return false; }
        ws(p); if (!take(p, ']')) {
            do { if (!parse_entry(p, log, day)) { free(day); return false; } ws(p); if (p->p < p->end && *p->p == ',') { p->p++; continue; } break; } while (true);
            if (!take(p, ']')) { free(day); return false; }
        }
        free(day); ws(p); if (p->p < p->end && *p->p == ',') { p->p++; continue; } break;
    } while (true);
    return take(p, '}');
}
bool mica_focus_log_from_json(MicaFocusLog *log, const char *json, size_t len) {
    if (!log || !json || !len || len > MAX_JSON) return false; MicaFocusLog *tmp = mica_focus_log_new(); if (!tmp) return false;
    Parser p = { json, json + len }; unsigned seen = 0; bool ok = false;
    if (!take(&p, '{')) goto done;
    do {
        char *key = parse_string(&p); if (!key || !take(&p, ':')) { free(key); goto done; }
        unsigned bit = !strcmp(key, "version") ? 1 : !strcmp(key, "days") ? 2 : 0; free(key); if (!bit || (seen & bit)) goto done; seen |= bit;
        if (bit == 1) { double v; if (!number(&p, &v, true) || v != 1) goto done; } else if (!parse_days(&p, tmp)) goto done;
        ws(&p); if (p.p < p.end && *p.p == ',') { p.p++; continue; } break;
    } while (true);
    if (seen != 3 || !take(&p, '}')) goto done; ws(&p); if (p.p != p.end) goto done;
    *log = *tmp; ok = true;
done: free(tmp); return ok;
}
bool mica_focus_log_save(const MicaFocusLog *log, const char *path) {
    if (!log || !path) return false; char *json = mica_focus_log_to_json(log); if (!json) return false;
    if (strlen(json) > MAX_JSON) { free(json); return false; }
    size_t n = strlen(path); if (n > SIZE_MAX - 40) { free(json); return false; } char *tmp = malloc(n + 40); if (!tmp) { free(json); return false; }
    snprintf(tmp, n + 40, "%s.tmp-%ld", path, (long)getpid()); int fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, 0600); bool ok = fd >= 0;
    size_t len = strlen(json), off = 0; while (ok && off < len) { ssize_t written = write(fd, json + off, len - off); if (written < 0 && errno == EINTR) continue; if (written <= 0) { ok = false; break; } off += (size_t)written; }
    if (ok && fsync(fd) != 0) ok = false; if (fd >= 0 && close(fd) != 0) ok = false; if (ok && rename(tmp, path) != 0) ok = false; if (!ok && fd >= 0) unlink(tmp);
    free(tmp); free(json); return ok;
}
bool mica_focus_log_load(MicaFocusLog *log, const char *path) {
    if (!log || !path) return false; int fd = open(path, O_RDONLY); if (fd < 0) { if (errno == ENOENT) { memset(log, 0, sizeof(*log)); return true; } return false; }
    char *buf = malloc(MAX_JSON + 1); if (!buf) { close(fd); return false; } size_t n = 0; bool ok = true;
    while (n <= MAX_JSON) { ssize_t r = read(fd, buf + n, MAX_JSON + 1 - n); if (r < 0 && errno == EINTR) continue; if (r < 0) { ok = false; break; } if (!r) break; n += (size_t)r; }
    if (close(fd) != 0) ok = false; if (n > MAX_JSON) ok = false; if (ok) ok = mica_focus_log_from_json(log, buf, n); free(buf); return ok;
}
