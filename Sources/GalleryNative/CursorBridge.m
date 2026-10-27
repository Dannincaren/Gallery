// Gallery adaptation of Mousecape's apply.m and MCDefs.m registration / copy
// paths. Copyright (c) 2013-2014 Alex Zielenski. All rights reserved.
// Modified for Gallery: ARC, dynamic symbols, validation and explicit errors.
// Subject to the noncommercial terms in ../../LICENSE. See Vendor/Mousecape.
#import "GalleryNative.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>
#import <objc/message.h>

typedef int32_t GLConnection;
typedef GLConnection (*ConnectionFn)(void);
typedef CGError (*RegisterFn)(GLConnection, const char *, bool, bool, CGSize,
                             CGPoint, NSUInteger, CGFloat, CFArrayRef, int *);
typedef CGError (*CopyFn)(GLConnection, const char *, CGSize *, CGPoint *,
                         NSUInteger *, CGFloat *, CFArrayRef *);
typedef CGError (*CoreCopyFn)(GLConnection, int, CFArrayRef *, CGSize *, CGPoint *,
                             NSUInteger *, CGFloat *);
typedef CGError (*GlobalSizeFn)(GLConnection, size_t *);
typedef CGError (*GlobalDataFn)(GLConnection, void *, int *, int *, CGRect *, CGPoint *, int *, int *, int *);
typedef int (*SeedFn)(void);
typedef CGError (*SelectFn)(GLConnection, const char *, int *);
typedef CGError (*CoreSelectFn)(GLConnection, int);
typedef CGError (*ConnectionPropertyFn)(GLConnection, GLConnection, CFStringRef, CFTypeRef);
typedef CGError (*NewConnectionFn)(int, GLConnection *);
typedef CGError (*WindowTagsFn)(GLConnection, int32_t, const uint64_t *, int);
typedef CGError (*ClearCoreFn)(GLConnection);
static ConnectionFn connectionFn;
static RegisterFn registerFn;
static CopyFn copyFn;
static CoreCopyFn coreCopyFn;
static GlobalSizeFn globalSizeFn;
static GlobalDataFn globalDataFn;
static SeedFn seedFn;
static SelectFn selectFn;
static CoreSelectFn coreSelectFn;
static CGError lastRefreshCode;
static ConnectionPropertyFn connectionPropertyFn;
static BOOL backgroundUpdatesEnabled;
static NewConnectionFn newConnectionFn;
static GLConnection probeConnection;
static WindowTagsFn clearWindowTagsFn;
static ClearCoreFn clearCoreFn;

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
        globalSizeFn = (GlobalSizeFn)dlsym(RTLD_DEFAULT, "CGSGetGlobalCursorDataSize");
        globalDataFn = (GlobalDataFn)dlsym(RTLD_DEFAULT, "CGSGetGlobalCursorData");
        seedFn = (SeedFn)dlsym(RTLD_DEFAULT, "CGSCurrentCursorSeed");
        selectFn = (SelectFn)dlsym(RTLD_DEFAULT, "CGSSetRegisteredCursor");
        coreSelectFn = (CoreSelectFn)dlsym(RTLD_DEFAULT, "CoreCursorSet");
        connectionPropertyFn = (ConnectionPropertyFn)dlsym(RTLD_DEFAULT, "CGSSetConnectionProperty");
        newConnectionFn = (NewConnectionFn)dlsym(RTLD_DEFAULT, "CGSNewConnection");
        clearWindowTagsFn = (WindowTagsFn)dlsym(RTLD_DEFAULT, "CGSClearWindowTags");
        clearCoreFn = (ClearCoreFn)dlsym(RTLD_DEFAULT, "CoreCursorUnregisterAll");
    });
}

@implementation GLCursorBridge
+ (BOOL)available {
    loadSymbols();
    return connectionFn && registerFn && copyFn;
}
+ (NSString *)diagnostics {
    loadSymbols();
    return [NSString stringWithFormat:@"connection=%d register=%d copy=%d coreCopy=%d globalProbe=%d refresh=%d",
            connectionFn != NULL, registerFn != NULL, copyFn != NULL, coreCopyFn != NULL, globalSizeFn && globalDataFn, lastRefreshCode];
}
+ (int32_t)cursorSeed { loadSymbols(); return seedFn ? seedFn() : -1; }
+ (int32_t)clearCoreCursorCache { loadSymbols(); return connectionFn && clearCoreFn ? clearCoreFn(connectionFn()) : -10001; }
+ (void)prepareOverlayWindow:(NSInteger)windowNumber {
    loadSymbols();
    if (connectionFn && clearWindowTagsFn) {
        // A nonactivating NSPanel is normally allowed to set its own cursor
        // while inactive. A cursor-only window must never claim that role.
        const uint64_t tags = (uint64_t)1 << 5;
        clearWindowTagsFn(connectionFn(), (int32_t)windowNumber, &tags, 64);
    }
}
+ (int32_t)setBackgroundCursorUpdates:(BOOL)enabled {
    loadSymbols();
    if (!connectionFn || !connectionPropertyFn) return -10001;
    // This property belongs only to Gallery's WindowServer connection. It
    // allows cursor updates while another app owns keyboard focus, and is
    // cleared when Gallery stops. No display-wide settings are changed.
    GLConnection connection = connectionFn();
    CGError error = connectionPropertyFn(connection, connection, CFSTR("SetsCursorInBackground"), enabled ? kCFBooleanTrue : kCFBooleanFalse);
    if (!error) backgroundUpdatesEnabled = enabled;
    return error;
}
+ (NSDictionary *)standardCursor:(NSString *)identifier {
    loadSymbols();
    NSDictionary *selectors = @{
        @"com.apple.coregraphics.Arrow": @"arrowCursor", @"com.apple.cursor.0": @"arrowCursor", @"com.apple.coregraphics.IBeam": @"IBeamCursor",
        @"com.apple.coregraphics.IBeamXOR": @"IBeamCursor", @"com.apple.cursor.2": @"pointingHandCursor",
        @"com.apple.cursor.1": @"IBeamCursor",
        @"com.apple.cursor.13": @"pointingHandCursor", @"com.apple.cursor.3": @"operationNotAllowedCursor",
        @"com.apple.cursor.7": @"crosshairCursor", @"com.apple.cursor.8": @"crosshairCursor",
        @"com.apple.cursor.11": @"closedHandCursor", @"com.apple.cursor.12": @"openHandCursor",
        @"com.apple.cursor.19": @"resizeLeftRightCursor", @"com.apple.cursor.23": @"resizeUpDownCursor",
        @"com.apple.cursor.17": @"resizeLeftCursor", @"com.apple.cursor.18": @"resizeRightCursor",
        @"com.apple.cursor.21": @"resizeUpCursor", @"com.apple.cursor.22": @"resizeDownCursor",
        @"com.apple.coregraphics.Copy": @"dragCopyCursor", @"com.apple.coregraphics.Alias": @"dragLinkCursor",
        @"com.apple.cursor.26": @"IBeamCursorForVerticalLayout"};
    NSString *name = selectors[identifier]; if (!name) return nil;
    SEL selector = NSSelectorFromString(name);
    if (![NSCursor respondsToSelector:selector]) return nil;
    NSCursor *cursor = ((NSCursor *(*)(id, SEL))objc_msgSend)([NSCursor class], selector);
    SEL initialize = NSSelectorFromString(@"_getImageAndHotSpotFromCoreCursor");
    if ([cursor respondsToSelector:initialize]) ((void (*)(id, SEL))objc_msgSend)(cursor, initialize);
    NSMutableArray<NSData *> *representations = [NSMutableArray array];
    for (NSImageRep *rep in cursor.image.representations) {
        if ([rep isKindOfClass:NSBitmapImageRep.class]) {
            NSData *png = [(NSBitmapImageRep *)rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            if (png) [representations addObject:png];
        }
    }
    CGImageRef image = [cursor.image CGImageForProposedRect:NULL context:nil hints:nil];
    NSBitmapImageRep *fallback = nil;
    if (!image) { fallback = [NSBitmapImageRep imageRepWithData:cursor.image.TIFFRepresentation]; image = fallback.CGImage; }
    if (!image) return nil;
    NSData *png = [[[NSBitmapImageRep alloc] initWithCGImage:image] representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (png) [representations addObject:png];
    if (!representations.count) return nil;
    long long coreType = -1;
    SEL typeSelector = NSSelectorFromString(@"_coreCursorType");
    if ([cursor respondsToSelector:typeSelector]) coreType = ((long long (*)(id, SEL))objc_msgSend)(cursor, typeSelector);
    return @{@"Representations": representations, @"FrameCount": @1, @"FrameDuration": @0.1,
        @"PointsWide": @(cursor.image.size.width), @"PointsHigh": @(cursor.image.size.height),
        @"HotSpotX": @(cursor.hotSpot.x), @"HotSpotY": @(cursor.hotSpot.y), @"CoreCursorType": @(coreType)};
}
+ (NSDictionary *)currentCursor {
    loadSymbols();
    // Read the actual WindowServer cursor, independent of this app's active
    // window or its cached NSCursor. The historical CGSInternal declaration of
    // this function differs; use the validated rowBytes + CGRect ABI here.
    if (connectionFn && globalSizeFn && globalDataFn) {
        // Observe through a separate connection with no background cursor
        // override. Gallery's drawing/hiding connection can otherwise return
        // its own cached cursor instead of another app's latest selection.
        if (!probeConnection && newConnectionFn) { newConnectionFn(0, &probeConnection); }
        GLConnection observer = probeConnection ? probeConnection : connectionFn();
        size_t byteCount = 0;
        if (!globalSizeFn(observer, &byteCount) && byteCount > 0 && byteCount <= 16 * 1024 * 1024) {
            int length = (int)byteCount;
            NSMutableData *bytes = [NSMutableData dataWithLength:length];
            CGRect rect = CGRectZero; CGPoint hot = CGPointZero;
            int row = 0, depth = 0, components = 0, bits = 0;
            int error = globalDataFn(observer, bytes.mutableBytes, &length, &row, &rect, &hot, &depth, &components, &bits);
            if (!error && rect.size.width > 0 && rect.size.width <= 2048 && rect.size.height > 0 && rect.size.height <= 49152 &&
                bits == 8 && components == 4 && row >= rect.size.width * 4 &&
                row * rect.size.height <= bytes.length) {
                CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)bytes);
                CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
                CGImageRef image = CGImageCreate(rect.size.width, rect.size.height, 8, 32, row, space,
                    kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little, provider, NULL, false, kCGRenderingIntentDefault);
                CGColorSpaceRelease(space); CGDataProviderRelease(provider);
                if (image) {
                    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
                    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                    CGImageRelease(image);
                    if (png) return @{@"Representations": @[png], @"FrameCount": @1, @"FrameDuration": @0.1,
                        @"PointsWide": @(rect.size.width), @"PointsHigh": @(rect.size.height),
                        @"HotSpotX": @(hot.x), @"HotSpotY": @(hot.y), @"Probe": @"WindowServer"};
                }
            }
        }
    }
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
    return [self updateCursor:cursor identifier:identifier refresh:YES];
}
+ (int32_t)updateCursor:(NSDictionary *)cursor identifier:(NSString *)identifier refresh:(BOOL)refresh {
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
    BOOL suppressVisibleUpdate = backgroundUpdatesEnabled && !refresh;
    if (suppressVisibleUpdate) [self setBackgroundCursorUpdates:NO];
    CGError error = registerFn(connectionFn(), identifier.UTF8String, true, true, size, hot,
                              count, duration, (__bridge CFArrayRef)images, &seed);
    if (suppressVisibleUpdate) [self setBackgroundCursorUpdates:YES];
    if (!error && refresh) {
        // CoreCursorSet can reuse a process-local cached image. Select the
        // freshly registered resource by name instead, including core aliases.
        if (selectFn) { lastRefreshCode = selectFn(connectionFn(), identifier.UTF8String, &seed); }
        else if (coreSelectFn && [identifier hasPrefix:@"com.apple.cursor."]) {
            lastRefreshCode = coreSelectFn(connectionFn(), identifier.pathExtension.intValue);
        }
    }
    return error;
}
@end
