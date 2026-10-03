#import "mica_status_context.h"

static NSString *MicaStableAgentActivity(NSString *activity) {
    static NSSet<NSString *> *knownActivities;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        knownActivities = [NSSet setWithArray:@[@"Planning", @"Searching", @"Reading", @"Editing",
            @"Working", @"Thinking", @"Exploring", @"Testing", @"Analyzing", @"Compacting"]];
    });
    return [knownActivities containsObject:activity] ? activity : @"Working";
}

NSString *MicaStatusContextForCommand(NSString *commandName, NSString *agentName,
    NSString *agentState, NSString *agentActivity, MicaStatusActivity activity,
    BOOL hasAgentHook, BOOL completed, int exitStatus) {
    NSString *command = commandName.lastPathComponent.length ? commandName.lastPathComponent : commandName;
    if (agentName.length) {
        if (hasAgentHook) {
            if ([agentState isEqualToString:@"waitingPermission"]) return [NSString stringWithFormat:@"%@ · Needs approval", agentName];
            if ([agentState isEqualToString:@"waitingInput"]) return [NSString stringWithFormat:@"%@ · Needs input", agentName];
            if ([agentState isEqualToString:@"done"]) return [NSString stringWithFormat:@"%@ · Finished", agentName];
            if ([agentState isEqualToString:@"error"]) return [NSString stringWithFormat:@"%@ · Error", agentName];
            if ([agentState isEqualToString:@"working"])
                return [NSString stringWithFormat:@"%@ · %@", agentName, MicaStableAgentActivity(agentActivity)];
            return [NSString stringWithFormat:@"%@ · Ready", agentName];
        }
        if (activity == MicaStatusActivityWaiting) {
            NSString *waiting = [agentActivity isEqualToString:@"Needs approval"] ? @"Needs approval" :
                ([agentActivity isEqualToString:@"Choosing session"] ? @"Choosing session" : @"Needs input");
            return [NSString stringWithFormat:@"%@ · %@", agentName, waiting];
        }
        if (activity == MicaStatusActivityNeedsAttention) return [NSString stringWithFormat:@"%@ · Error", agentName];
        if (activity == MicaStatusActivityFinished || completed) return [NSString stringWithFormat:@"%@ · Finished", agentName];
        if (activity == MicaStatusActivityRunning)
            return [NSString stringWithFormat:@"%@ · %@", agentName, MicaStableAgentActivity(agentActivity)];
        return [NSString stringWithFormat:@"%@ · Ready", agentName];
    }
    if (completed || activity == MicaStatusActivityFinished) {
        if (exitStatus == 0) return [NSString stringWithFormat:@"%@ · Finished", command.length ? command : @"Command"];
        return [NSString stringWithFormat:@"%@ · Failed (%d)", command.length ? command : @"Command", exitStatus];
    }
    if (activity == MicaStatusActivityWaiting) return [NSString stringWithFormat:@"%@ · Waiting for input", command.length ? command : @"Command"];
    if (activity == MicaStatusActivityNeedsAttention) return [NSString stringWithFormat:@"%@ · Needs attention", command.length ? command : @"Command"];
    if (activity == MicaStatusActivityIdle) {
        if ([command caseInsensitiveCompare:@"lazygit"] == NSOrderedSame) return @"lazygit · Open";
        return [NSString stringWithFormat:@"%@ · Idle", command.length ? command : @"Terminal"];
    }
    return [NSString stringWithFormat:@"Running · %@", command.length ? command : @"command"];
}
