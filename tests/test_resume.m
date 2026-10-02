#import <Foundation/Foundation.h>
#import "../src/mica_resume.h"

int main(void) {
    @autoreleasepool {
        NSArray *valid = @[@"abcdefgh", @"abc_DEF-123.xyz", [@"a" stringByPaddingToLength:80 withString:@"a" startingAtIndex:0]];
        for (NSString *value in valid) if (!MicaResumeCommand(@"claude", value)) return 1;
        NSString *tooShort = @"short";
        NSString *tooLong = [@"a" stringByPaddingToLength:81 withString:@"a" startingAtIndex:0];
        NSArray *hostile = @[@"abc defgh", @"abcdefgh;", @"$(touch)", @"abc\"defgh", @"abc\ndefgh", @"abcdefghé", tooShort, tooLong];
        for (NSString *value in hostile) if (MicaResumeCommand(@"claude", value)) return 2;
        if (![[MicaResumeCommand(@"codex", @"abcdefgh") description] isEqualToString:@"codex resume abcdefgh"]) return 3;
        if (MicaResumeCommand(@"other", @"abcdefgh")) return 4;
    }
    return 0;
}
