#import "mica_agent_state.h"

NSString *MicaAgentStateForHookEvent(NSString *event, NSString *notificationType, NSString *currentState) {
    if ([event isEqualToString:@"SessionStart"]) return @"idle";
    if ([event isEqualToString:@"UserPromptSubmit"] || [event isEqualToString:@"PreToolUse"] ||
        [event isEqualToString:@"PostToolUse"]) return @"working";
    if ([event isEqualToString:@"PermissionRequest"]) return @"waitingPermission";
    if ([event isEqualToString:@"Notification"]) {
        if ([notificationType isEqualToString:@"permission_prompt"]) return @"waitingPermission";
        if ([notificationType isEqualToString:@"idle_prompt"] ||
            [notificationType isEqualToString:@"agent_needs_input"]) return @"waitingInput";
        return currentState;
    }
    if ([event isEqualToString:@"Stop"] ||
        ([event isEqualToString:@"notify"] && [notificationType isEqualToString:@"agent-turn-complete"])) return @"done";
    if ([event isEqualToString:@"StopFailure"]) return @"error";
    if ([event isEqualToString:@"SessionEnd"]) return @"none";
    return currentState;
}
