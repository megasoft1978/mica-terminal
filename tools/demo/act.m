#import <Cocoa/Cocoa.h>
int main(int c,char**v){ @autoreleasepool{ NSRunningApplication*a=[NSRunningApplication runningApplicationWithProcessIdentifier:atoi(v[1])]; [a activateWithOptions:NSApplicationActivateAllWindows|NSApplicationActivateIgnoringOtherApps]; printf("activated %d\n",a!=nil);} }
