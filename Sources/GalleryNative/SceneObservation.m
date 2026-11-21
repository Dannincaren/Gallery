#import "GalleryNative.h"
#import <dlfcn.h>

typedef void (*SceneCallback)(uint32_t, void *, size_t, void *, int);
typedef int (*SceneConnectionFn)(void);
typedef int (*SceneNoticeFn)(int, SceneCallback, uint32_t, void *);
static SceneNoticeFn addSceneNotice, removeSceneNotice;
static void (^sceneChanged)(int32_t);

static void SceneNotification(uint32_t type, void *data, size_t length, void *context, int connection) {
    if (type != 1327 && type != 1328 && type != 1401) return;
    void (^changed)(int32_t);
    @synchronized (GLSceneObservation.class) { changed = sceneChanged; }
    if (changed) {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{ changed((int32_t)type); });
        CFRunLoopWakeUp(CFRunLoopGetMain());
    }
}

@interface GLSceneObservation ()
@property(nonatomic) BOOL active;
@property(nonatomic) int connection;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *types;
@property(nonatomic, copy) void (^changed)(int32_t);
@end

@implementation GLSceneObservation
+ (instancetype)observeChanges:(void (^)(int32_t))changed {
    if (!changed) return nil;
    [GLCursorBridge available];
    SceneConnectionFn main = (SceneConnectionFn)dlsym(RTLD_DEFAULT, "SLSMainConnectionID");
    addSceneNotice = (SceneNoticeFn)dlsym(RTLD_DEFAULT, "SLSRegisterConnectionNotifyProc");
    removeSceneNotice = (SceneNoticeFn)dlsym(RTLD_DEFAULT, "SLSRemoveConnectionNotifyProc");
    if (!main || !addSceneNotice || !removeSceneNotice) return nil;
    @synchronized (self) { if (sceneChanged) return nil; }
    GLSceneObservation *observer = [self new];
    observer.connection = main(); observer.active = YES; observer.changed = changed;
    observer.types = [NSMutableArray array];
    __weak GLSceneObservation *weak = observer;
    @synchronized (self) {
        sceneChanged = ^(int32_t type) {
            GLSceneObservation *strong = weak;
            if (strong.active) strong.changed(type);
        };
    }
    for (NSNumber *type in @[@1327, @1328, @1401]) {
        if (!addSceneNotice(observer.connection, SceneNotification, type.unsignedIntValue, NULL)) [observer.types addObject:type];
    }
    if (!observer.types.count) { [observer invalidate]; return nil; }
    return observer;
}
- (void)invalidate {
    if (!self.active) return;
    self.active = NO;
    @synchronized (GLSceneObservation.class) { sceneChanged = nil; }
    for (NSNumber *type in self.types) removeSceneNotice(self.connection, SceneNotification, type.unsignedIntValue, NULL);
    [self.types removeAllObjects]; self.changed = nil;
}
- (void)dealloc { [self invalidate]; }
@end
