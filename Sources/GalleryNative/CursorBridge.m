// Gallery adaptation of Mousecape's apply.m and MCDefs.m registration / copy
// paths. Copyright (c) 2013-2014 Alex Zielenski. All rights reserved.
// Modified for Gallery: ARC, dynamic symbols, validation and explicit errors.
// Subject to the noncommercial terms in ../../LICENSE. See Vendor/Mousecape.
#import "GalleryNative.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>

typedef int32_t GLConnection;
typedef GLConnection (*ConnectionFn)(void);
typedef CGError (*RegisterFn)(GLConnection, const char *, bool, bool, CGSize,
                             CGPoint, NSUInteger, CGFloat, CFArrayRef, int *);
typedef CGError (*CopyFn)(GLConnection, const char *, CGSize *, CGPoint *,
                         NSUInteger *, CGFloat *, CFArrayRef *);
typedef CGError (*CoreCopyFn)(GLConnection, int, CFArrayRef *, CGSize *, CGPoint *,
                             NSUInteger *, CGFloat *);
static ConnectionFn connectionFn;
static RegisterFn registerFn;
static CopyFn copyFn;
static CoreCopyFn coreCopyFn;

static void loadSymbols(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Public framework may re-export these on older systems; newer systems
        // put them in SkyLight. Never link private symbols at app startup.
        dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY | RTLD_LOCAL);
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL);
        connectionFn = (ConnectionFn)dlsym(RTLD_DEFAULT, "CGSMainConnectionID");
        registerFn = (RegisterFn)dlsym(RTLD_DEFAULT, "CGSRegisterCursorWithImages");
        copyFn = (CopyFn)dlsym(RTLD_DEFAULT, "CGSCopyRegisteredCursorImages");
        coreCopyFn = (CoreCopyFn)dlsym(RTLD_DEFAULT, "CoreCursorCopyImages");
    });
}

@implementation GLCursorBridge
+ (BOOL)available {
    loadSymbols();
    return connectionFn && registerFn && copyFn;
}
+ (NSString *)diagnostics {
    loadSymbols();
    return [NSString stringWithFormat:@"connection=%d register=%d copy=%d coreCopy=%d",
            connectionFn != NULL, registerFn != NULL, copyFn != NULL, coreCopyFn != NULL];
}
+ (NSDictionary *)currentCursor {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSCursor *cursor = [NSCursor currentSystemCursor];
#pragma clang diagnostic pop
    if (!cursor) return nil;
    CGImageRef currentImage = [cursor.image CGImageForProposedRect:NULL context:nil hints:nil];
    if (!currentImage) return nil;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:currentImage];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (!png) return nil;
    return @{@"Representations": @[png], @"FrameCount": @1, @"FrameDuration": @0.1,
             @"PointsWide": @(cursor.image.size.width), @"PointsHigh": @(cursor.image.size.height),
             @"HotSpotX": @(cursor.hotSpot.x), @"HotSpotY": @(cursor.hotSpot.y)};
}
+ (NSDictionary *)readCursor:(NSString *)identifier {
    if (![self available]) return nil;
    CGSize size = CGSizeZero; CGPoint hot = CGPointZero;
    NSUInteger count = 0; CGFloat duration = 0;
    CFArrayRef images = NULL;
    CGError error;
    if ([identifier hasPrefix:@"com.apple.cursor."] && coreCopyFn) {
        error = coreCopyFn(connectionFn(), identifier.pathExtension.intValue, &images, &size, &hot, &count, &duration);
    } else {
        error = copyFn(connectionFn(), identifier.UTF8String, &size, &hot, &count, &duration, &images);
    }
    if (error || !images) { if (images) CFRelease(images); return nil; }
    NSMutableArray *data = [NSMutableArray array];
    for (id object in (__bridge NSArray *)images) {
        if (CFGetTypeID((__bridge CFTypeRef)object) != CGImageGetTypeID()) continue;
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:(__bridge CGImageRef)object];
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if (png) [data addObject:png];
    }
    CFRelease(images);
    if (!data.count || count < 1 || size.width <= 0 || size.height <= 0) return nil;
    return @{@"Representations": data, @"FrameCount": @(count), @"FrameDuration": @(duration > 0 ? duration : 0.1),
             @"PointsWide": @(size.width), @"PointsHigh": @(size.height),
             @"HotSpotX": @(hot.x), @"HotSpotY": @(hot.y)};
}
+ (int32_t)registerCursor:(NSDictionary *)cursor identifier:(NSString *)identifier {
    if (![self available]) return -10001;
    NSUInteger count = [cursor[@"FrameCount"] unsignedIntegerValue];
    CGFloat duration = [cursor[@"FrameDuration"] doubleValue];
    CGSize size = CGSizeMake([cursor[@"PointsWide"] doubleValue], [cursor[@"PointsHigh"] doubleValue]);
    CGPoint hot = CGPointMake([cursor[@"HotSpotX"] doubleValue], [cursor[@"HotSpotY"] doubleValue]);
    if (!identifier.length || count < 1 || count > 24 || !isfinite(duration) || duration <= 0 ||
        !isfinite(size.width) || !isfinite(size.height) || size.width <= 0 || size.height <= 0 ||
        !isfinite(hot.x) || !isfinite(hot.y) || hot.x < 0 || hot.y < 0 || hot.x >= size.width || hot.y >= size.height) return -10002;
    NSMutableArray *images = [NSMutableArray array];
    for (NSData *data in cursor[@"Representations"]) {
        NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:data];
        if (!rep.CGImage || rep.pixelsHigh % count != 0) return -10003;
        // Retain the image through the array after its representation is released.
        [images addObject:(__bridge id)rep.CGImage];
    }
    if (!images.count) return -10003;
    int seed = 0;
    return registerFn(connectionFn(), identifier.UTF8String, true, true, size, hot,
                      count, duration, (__bridge CFArrayRef)images, &seed);
}
@end
