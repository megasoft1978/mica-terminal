#import <Cocoa/Cocoa.h>

#include <stdint.h>
#include <stdio.h>

static NSString *ProjectMark(NSString *name) {
    NSError *error = nil;
    NSRegularExpression *expression = [NSRegularExpression
        regularExpressionWithPattern:@"[A-Z]+(?=[A-Z][a-z]|[^A-Za-z0-9]|$)|[A-Z]?[a-z]+|[0-9]+"
        options:0 error:&error];
    if (!expression || error) return @"M";

    NSArray<NSTextCheckingResult *> *matches = [expression matchesInString:name
        options:0 range:NSMakeRange(0, name.length)];
    NSMutableString *mark = [NSMutableString string];
    if (matches.count > 1) {
        for (NSUInteger i = 0; i < MIN(matches.count, 3); i++) {
            NSRange first = [matches[i] range];
            [mark appendString:[[name substringWithRange:first] substringToIndex:1].uppercaseString];
        }
    } else if (matches.count == 1) {
        NSString *word = [name substringWithRange:matches[0].range];
        NSUInteger end = [word rangeOfComposedCharacterSequenceAtIndex:0].length;
        NSUInteger markEnd = end;
        if (end < word.length) {
            NSRange second = [word rangeOfComposedCharacterSequenceAtIndex:end];
            markEnd = NSMaxRange(second);
        }
        [mark appendString:[word substringToIndex:markEnd].uppercaseString];
    }
    return mark.length ? mark : @"M";
}

static uint32_t ProjectHash(NSString *name) {
    uint32_t hash = 2166136261u;
    for (NSUInteger i = 0; i < name.length; i++) {
        hash ^= [name characterAtIndex:i];
        hash *= 16777619u;
    }
    return hash;
}

static BOOL WriteProjectIcon(NSString *sourcePath, NSString *destinationPath, NSString *name) {
    NSImage *source = [[NSImage alloc] initWithContentsOfFile:sourcePath];
    if (!source) {
        fprintf(stderr, "cannot read base app icon: %s\n", sourcePath.UTF8String);
        return NO;
    }

    const NSInteger pixels = 1024;
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:pixels pixelsHigh:pixels bitsPerSample:8
        samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
        bytesPerRow:0 bitsPerPixel:0];
    if (!bitmap) {
        fprintf(stderr, "cannot allocate project icon bitmap\n");
        return NO;
    }
    bitmap.size = NSMakeSize(pixels, pixels);

    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    if (!context) {
        fprintf(stderr, "cannot create project icon drawing context\n");
        return NO;
    }
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:context];
    context.imageInterpolation = NSImageInterpolationHigh;
    [source drawInRect:NSMakeRect(0, 0, pixels, pixels) fromRect:NSZeroRect
        operation:NSCompositingOperationSourceOver fraction:1.0];

    CGFloat diameter = pixels * 0.19;
    NSRect badge = NSMakeRect((pixels - diameter) / 2.0, pixels * 0.77, diameter, diameter);
    NSBezierPath *backing = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(badge, -10, -10)];
    [[NSColor colorWithWhite:0.05 alpha:0.92] setFill];
    [backing fill];

    uint32_t hash = ProjectHash(name);
    NSColor *accent = [NSColor colorWithHue:(CGFloat)(hash % 360u) / 360.0
        saturation:0.78 brightness:0.46 alpha:1.0];
    NSBezierPath *circle = [NSBezierPath bezierPathWithOvalInRect:badge];
    circle.lineWidth = 10;
    [[NSColor colorWithWhite:1.0 alpha:0.96] setStroke];
    [accent setFill];
    [circle fill];
    [circle stroke];

    NSString *mark = ProjectMark(name);
    CGFloat fontSize = mark.length > 2 ? pixels * 0.061 : pixels * 0.071;
    NSDictionary *attributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:fontSize weight:NSFontWeightHeavy],
        NSForegroundColorAttributeName: NSColor.whiteColor,
    };
    NSSize textSize = [mark sizeWithAttributes:attributes];
    NSPoint textPoint = NSMakePoint(NSMidX(badge) - textSize.width / 2.0,
                                    NSMidY(badge) - textSize.height / 2.0);
    [mark drawAtPoint:textPoint withAttributes:attributes];
    [context flushGraphics];
    [NSGraphicsContext restoreGraphicsState];

    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    NSError *writeError = nil;
    BOOL saved = [png writeToFile:destinationPath options:NSDataWritingAtomic error:&writeError];
    if (!saved) {
        fprintf(stderr, "cannot save project icon %s: %s\n", destinationPath.UTF8String,
                writeError.localizedDescription.UTF8String);
    }
    return saved;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 4) {
            fprintf(stderr, "usage: mica-project-icon BASE.icns OUTPUT.png PROJECT_NAME\n");
            return 2;
        }
        [NSApplication sharedApplication];
        return WriteProjectIcon([NSString stringWithUTF8String:argv[1]],
                                [NSString stringWithUTF8String:argv[2]],
                                [NSString stringWithUTF8String:argv[3]]) ? 0 : 1;
    }
}
