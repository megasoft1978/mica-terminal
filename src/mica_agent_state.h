#import <Foundation/Foundation.h>

// Returns the hook-authoritative state for a recognized event, or currentState for unknown events.
NSString *MicaAgentStateForHookEvent(NSString *event, NSString *notificationType, NSString *currentState);
