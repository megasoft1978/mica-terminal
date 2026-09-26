#ifndef MICA_LAUNCH_H
#define MICA_LAUNCH_H

/* Keep these shell commands shared by the app and the PTY launcher tests. */
#define MICA_COMMAND_CLAUDE \
    "unset CLAUDECODE; export CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1; yowork"
#define MICA_COMMAND_CLAUDE_RESUME \
    "unset CLAUDECODE; export CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1; yowork --continue"
#define MICA_COMMAND_CODEX \
    "codex -c tui.raw_output_mode=true --no-alt-screen"
#define MICA_COMMAND_CODEX_RESUME \
    "codex resume -c tui.raw_output_mode=true --no-alt-screen --last"

#endif
