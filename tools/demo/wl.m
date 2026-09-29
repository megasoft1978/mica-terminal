#import <Cocoa/Cocoa.h>
int main(void){ @autoreleasepool{
 NSArray *l=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly|kCGWindowListExcludeDesktopElements,kCGNullWindowID));
 for(NSDictionary*w in l){ if([[w[@"kCGWindowOwnerName"] description] rangeOfString:@"ica"].location==NSNotFound) continue; CGRect r; CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)w[@"kCGWindowBounds"],&r);
  printf("%d|%s|%.0f,%.0f,%.0f,%.0f\n",[w[@"kCGWindowNumber"] intValue],[[w[@"kCGWindowName"] description] UTF8String],r.origin.x,r.origin.y,r.size.width,r.size.height);} } }
