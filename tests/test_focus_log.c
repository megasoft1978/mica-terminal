#define _DARWIN_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#include "mica_focus_log.h"
#include <assert.h>
#include <math.h>
#include <float.h>
#include <locale.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int main(void) {
    MicaFocusLog *l = mica_focus_log_new(); assert(l);
    assert(mica_focus_log_add(l, "20261031", "z", "main", 10));
    assert(mica_focus_log_add(l, "20261031", "z", "main", 5));
    assert(mica_focus_log_add(l, "20261031", "z", "dev", 15));
    assert(mica_focus_log_add(l, "20261031", "a", NULL, 15));
    MicaFocusLogEntry entries[64]; assert(mica_focus_log_entries_for_day(l, "20261031", entries, 64) == 3);
    assert(!strcmp(entries[0].project, "a") && !strcmp(entries[1].branch, "dev") && entries[2].sessions == 2);
    assert(mica_focus_log_total_for_day(l, "20261031") == 45);
    assert(!mica_focus_log_add(l, "2026103x", "x", NULL, 1));
    assert(!mica_focus_log_add(l, "20261031", "x", NULL, NAN));
    assert(!mica_focus_log_add(l, "20261031", "x", NULL, -1));
    assert(!mica_focus_log_add(l, "20261031", "x", NULL, 86401));
    assert(!mica_focus_log_add(l, "20261031", NULL, NULL, 1));
    assert(mica_focus_log_total_for_day(l, "20261031") == 45);
    mica_focus_log_free(l); l = mica_focus_log_new(); assert(l);
    for (int i = 0; i < 31; i++) { char day[9]; snprintf(day, sizeof(day), "%08d", 20260001 + i); assert(mica_focus_log_add(l, day, "p", NULL, 1)); }
    assert(mica_focus_log_total_for_day(l, "20260001") == 0); assert(mica_focus_log_total_for_day(l, "20260031") == 1);
    assert(mica_focus_log_add(l, "20250001", "p", NULL, 1)); assert(mica_focus_log_total_for_day(l, "20250001") == 0);
    mica_focus_log_free(l); l = mica_focus_log_new(); assert(l);
    for (int i = 0; i < 65; i++) { char name[20]; snprintf(name, sizeof(name), "project%d", i); assert(mica_focus_log_add(l, "20261031", name, NULL, 1)); }
    assert(mica_focus_log_entries_for_day(l, "20261031", entries, 64) == 64); assert(mica_focus_log_total_for_day(l, "20261031") == 65);
    assert(!strcmp(entries[0].project, "Other") && entries[0].sessions == 2 && entries[0].seconds == 2);
    mica_focus_log_free(l); l = mica_focus_log_new(); assert(l);
    char longname[140]; memset(longname, 'a', 127); memcpy(longname + 127, "\xc3\xa9", 3);
    assert(mica_focus_log_add(l, "20261031", longname, longname, 1));
    assert(mica_focus_log_entries_for_day(l, "20261031", entries, 64) == 1); assert(strlen(entries[0].project) == 127 && strlen(entries[0].branch) == 127);
    assert(mica_focus_log_add(l, "20261031", "quote\" slash\\ newline\n caf\xc3\xa9", "\tbranch", 42));
    char *json = mica_focus_log_to_json(l); assert(json); MicaFocusLog *copy = mica_focus_log_new(); assert(copy); assert(mica_focus_log_from_json(copy, json, strlen(json)));
    assert(mica_focus_log_total_for_day(copy, "20261031") == 43); assert(mica_focus_log_entries_for_day(copy, "20261031", entries, 1) == 2);
    assert(!strcmp(entries[0].project, "quote\" slash\\ newline\n caf\xc3\xa9") && !strcmp(entries[0].branch, "\tbranch"));
    const char *bad[] = {"", "{", "{}", "{\"version\":1,\"days\":", "{\"version\":1,\"days\":{},}", "{\"version\":1,\"days\":{\"20261031\":[{\"project\":\"x\",\"branch\":\"\",\"seconds\":1,\"sessions\":0}]}}"};
    const char *excess = "{\"version\":1,\"days\":{\"20261031\":[{\"project\":\"x\",\"branch\":\"\",\"seconds\":86401,\"sessions\":1}]}}";
    assert(!mica_focus_log_from_json(copy, excess, strlen(excess))); assert(mica_focus_log_total_for_day(copy, "20261031") == 43);
    for (size_t i = 0; i < sizeof(bad)/sizeof(bad[0]); i++) { assert(!mica_focus_log_from_json(copy, bad[i], strlen(bad[i]))); assert(mica_focus_log_total_for_day(copy, "20261031") == 43); }
    for (size_t i = 0; i < strlen(json); i++) { assert(!mica_focus_log_from_json(copy, json, i)); assert(mica_focus_log_total_for_day(copy, "20261031") == 43); }
    char dir[] = "/tmp/mica-focus-test-XXXXXX"; assert(mkdtemp(dir)); char path[256]; snprintf(path, sizeof(path), "%s/log.json", dir);
    assert(mica_focus_log_load(copy, path)); assert(mica_focus_log_total_for_day(copy, "20261031") == 0);
    assert(mica_focus_log_save(l, path)); struct stat st; assert(stat(path, &st) == 0 && (st.st_mode & 0777) == 0600);
    assert(mica_focus_log_load(copy, path)); assert(mica_focus_log_total_for_day(copy, "20261031") == 43);
    assert(unlink(path) == 0);
    MicaFocusLog *tiny = mica_focus_log_new(); assert(tiny);
    assert(mica_focus_log_add(tiny, "20261031", "tiny", "", DBL_TRUE_MIN));
    char *tiny_json = mica_focus_log_to_json(tiny); assert(tiny_json);
    assert(mica_focus_log_from_json(copy, tiny_json, strlen(tiny_json)));
    assert(mica_focus_log_total_for_day(copy, "20261031") == DBL_TRUE_MIN);
    free(tiny_json); mica_focus_log_free(tiny);
    const char *locales[] = {"de_DE.UTF-8", "de_DE.utf8", "fr_FR.UTF-8", "fr_FR.utf8", "it_IT.UTF-8"};
    for (size_t i = 0; i < sizeof(locales)/sizeof(locales[0]); i++) {
        if (setlocale(LC_NUMERIC, locales[i])) {
            MicaFocusLog *localized = mica_focus_log_new(); assert(localized);
            assert(mica_focus_log_add(localized, "20261031", "test", "", 1.5));
            char *localized_json = mica_focus_log_to_json(localized); assert(localized_json);
            assert(strstr(localized_json, "1.5"));
            assert(mica_focus_log_from_json(copy, localized_json, strlen(localized_json)));
            assert(mica_focus_log_total_for_day(copy, "20261031") == 1.5);
            free(localized_json); mica_focus_log_free(localized); break;
        }
    }
    assert(setlocale(LC_NUMERIC, "C"));
    MicaFocusLog *large = mica_focus_log_new(); assert(large);
    for (int i = 0; i < 30; i++) {
        char day[9]; snprintf(day, sizeof(day), "%08d", 20260001 + i);
        for (int j = 0; j < 64; j++) {
            char name[129], branch[129]; memset(name, 1, 128); memset(branch, 1, 128); name[128] = branch[128] = 0;
            name[0] = (char)('A' + j / 26); name[1] = (char)('A' + j % 26);
            assert(mica_focus_log_add(large, day, name, branch, 1));
        }
    }
    assert(!mica_focus_log_save(large, path)); assert(access(path, F_OK) != 0); mica_focus_log_free(large);
    assert(rmdir(dir) == 0);
    free(json); mica_focus_log_free(copy); mica_focus_log_free(l); puts("focus log tests passed"); return 0;
}
