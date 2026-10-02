#include "mica_agent_detect.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    const char *yes1[] = {"claude", "claude-code --resume", "node /x/node_modules/@openai/codex/bin/codex.js", "npx codex", "bunx @anthropic-ai/claude-code", "sh -c cd repo && claude --resume x", "env FOO=1 claude", "codex --help", "bun /x/node_modules/@anthropic-ai/claude-code/cli.js", "node codex", "npx @openai/codex", "claude --print"};
    const int kinds[] = {1,1,2,2,1,1,1,2,1,2,2,1};
    for (unsigned i=0;i<sizeof(kinds)/sizeof(kinds[0]);i++) assert(mica_agent_kind_from_commands(yes1[i])==kinds[i]);
    const char *no[] = {"claudette", "codexify", "cat my-codex-notes.txt", "vim /tmp/claude-notes", "python codex_helper.py", "echo claude-ish", "sleep 5", "node /x/node_modules/@openai/codexify/bin/a.js"};
    for (unsigned i=0;i<sizeof(no)/sizeof(no[0]);i++) assert(mica_agent_kind_from_commands(no[i])==0);
    puts("agent detection tests passed"); return 0;
}
