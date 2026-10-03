#import "mica_ssh_profile.h"

NSUInteger const MicaSSHProfileMaximumCount = 64;

static NSError *ProfileError(NSString *message) {
    return [NSError errorWithDomain:@"MicaSSHProfileError" code:1
        userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString *Trimmed(NSString *value) {
    return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static BOOL ContainsControlCharacters(NSString *value) {
    return [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound;
}

static BOOL ValidDestination(NSString *destination) {
    if (!destination.length || destination.length > 255 || [destination hasPrefix:@"-"] ||
        ContainsControlCharacters(destination)) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.@:%-[]"];
    return [destination rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

static NSString *POSIXQuote(NSString *value) {
    return [NSString stringWithFormat:@"'%@'", [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

NSDictionary<NSString *, NSString *> *MicaSSHProfileNormalize(NSDictionary *candidate, NSError **error) {
    if (![candidate isKindOfClass:NSDictionary.class]) {
        if (error) *error = ProfileError(@"Profile data must be a dictionary.");
        return nil;
    }
    id rawName = candidate[@"name"];
    id rawDestination = candidate[@"destination"];
    id rawDirectory = candidate[@"remoteDirectory"];
    id rawID = candidate[@"id"];
    if (![rawName isKindOfClass:NSString.class] || ![rawDestination isKindOfClass:NSString.class] ||
        (rawDirectory && ![rawDirectory isKindOfClass:NSString.class]) ||
        (rawID && ![rawID isKindOfClass:NSString.class])) {
        if (error) *error = ProfileError(@"Profile fields must be text.");
        return nil;
    }
    NSString *name = Trimmed(rawName);
    NSString *destination = Trimmed(rawDestination);
    NSString *directory = rawDirectory ? rawDirectory : @"";
    NSString *identifier = rawID ? Trimmed(rawID) : NSUUID.UUID.UUIDString;
    if (!name.length || name.length > 80 || ContainsControlCharacters(name) ||
        [name containsString:@"\t"]) {
        if (error) *error = ProfileError(@"Enter a profile name of 1–80 characters without control characters.");
        return nil;
    }
    if (!ValidDestination(destination)) {
        if (error) *error = ProfileError(@"Enter an SSH host alias, host name, IP address, or user@host. Put SSH options in ~/.ssh/config.");
        return nil;
    }
    if (directory.length > 4096 || ContainsControlCharacters(directory)) {
        if (error) *error = ProfileError(@"The remote folder must be under 4096 characters and contain no control characters.");
        return nil;
    }
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:identifier];
    if (!uuid) {
        if (error) *error = ProfileError(@"Profile identifier is invalid.");
        return nil;
    }
    return @{@"id": uuid.UUIDString, @"name": name, @"destination": destination,
             @"remoteDirectory": directory};
}

NSString *MicaSSHProfileCommand(NSDictionary<NSString *, NSString *> *profile) {
    NSDictionary *normalized = MicaSSHProfileNormalize(profile, NULL);
    if (!normalized) return nil;
    NSString *destination = normalized[@"destination"];
    NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithObjects:@"ssh", @"-tt", nil];
    NSString *directory = normalized[@"remoteDirectory"];
    if (directory.length) {
        NSString *directoryExpression = nil;
        if ([directory isEqualToString:@"~"]) directoryExpression = @"\"$HOME\"";
        else if ([directory hasPrefix:@"~/"])
            directoryExpression = [NSString stringWithFormat:@"\"$HOME\"/%@", POSIXQuote([directory substringFromIndex:2])];
        else directoryExpression = POSIXQuote(directory);
        NSString *remote = [NSString stringWithFormat:@"cd -- %@ && exec \"${SHELL:-/bin/sh}\" -l", directoryExpression];
        [arguments addObject:destination];
        [arguments addObject:remote];
    } else {
        [arguments addObject:destination];
    }
    NSMutableArray<NSString *> *quoted = [NSMutableArray arrayWithCapacity:arguments.count];
    for (NSString *argument in arguments) [quoted addObject:POSIXQuote(argument)];
    return [quoted componentsJoinedByString:@" "];
}
