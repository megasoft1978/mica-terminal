#import <Foundation/Foundation.h>

NSString *MicaResumeCommand(NSString *kind, NSString *sessionID);
// Allowlisted launch flags only (claude: --dangerously-skip-permissions; codex: --sandbox <v>,
// --ask-for-approval <v>, --dangerously-bypass-approvals-and-sandbox). Unknown tokens are dropped.
NSArray<NSString *> *MicaSanitizedAgentFlags(NSString *kind, NSArray *flags);
// A Claude config dir worth restoring: absolute, existing, no shell-hostile characters, not the default ~/.claude.
NSString *MicaSanitizedConfigDir(NSString *configDir, NSString *home);
// Reproduces how the agent was launched, e.g. `CLAUDE_CONFIG_DIR='/Users/me/.claude-work' claude --dangerously-skip-permissions --resume <id>`.
NSString *MicaResumeCommandWithLaunch(NSString *kind, NSString *sessionID, NSString *configDir, NSArray *flags, NSString *home);
