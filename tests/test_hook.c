#include "mica_hook.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
int main(void){MicaHookEvent e;const char *good="{\"token\":\"0123456789abcdef0123456789ABCDEF\",\"event\":\"Stop\",\"agent\":\"claude\",\"message\":\"ok\"}";
 assert(mica_hook_parse(good,strlen(good),&e));assert(!strcmp(e.event,"Stop")&&!strcmp(e.message,"ok"));
 assert(!mica_hook_parse("{",1,&e));char big[MICA_HOOK_LINE_MAX+1];memset(big,' ',sizeof(big));assert(!mica_hook_parse(big,sizeof(big),&e));
 const char *nested="{\"token\":\"0123456789abcdef0123456789abcdef\",\"event\":\"x\",\"agent\":\"codex\",\"junk\": [[[[[[[[[[0]]]]]]]]]]}";assert(!mica_hook_parse(nested,strlen(nested),&e));
 const char *bad="{\"token\":\"0123456789abcdef0123456789abcdef\",\"event\":\"x\",\"agent\":\"codex\",\"message\":\"\xff\"}";assert(!mica_hook_parse(bad,strlen(bad),&e));
 puts("hook parser bounds, valid input, nesting, truncation and UTF-8 passed");return 0;}
