// Gallery's read-only responsiveness observer. See Documentation/WAIT-OVERLAY.md
// for the private API contracts and the bounded tests behind this path.
#import "GalleryNative.h"
#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>

typedef int32_t (*MainConnectionFn)(void);
typedef bool (*UnresponsiveFn)(int32_t, const ProcessSerialNumber *);
typedef CGError (*TimeoutFn)(int32_t, double);
typedef void (*BusyNotifyFn)(int, void *, unsigned int, void *);
typedef CGError (*NotifyRegistrationFn)(BusyNotifyFn, int, void *);

// There is one cursor runtime in a process. A callback copies this block under
// the lock rather than dereferencing an observer pointer after deregistration.
static void (^busyChanged)(void);
static MainConnectionFn busyConnection;
static UnresponsiveFn unresponsive;
static TimeoutFn setTimeout;
static NotifyRegistrationFn registerNotice, removeNotice;

static void BusyNotification(int type, void *data, unsigned int length, void *context) {
    if (type != 750 && type != 751) return;
    // Deliberately do not parse undocumented notification payloads or collect
    // another application's information. The owner under the pointer is queried
    // independently when the main queue handles this edge.
    void (^changed)(void);
    @synchronized (GLBusyObservation.class) { changed = busyChanged; }
    if (changed) dispatch_async(dispatch_get_main_queue(), changed);
}

@interface GLBusyObservation ()
@property(nonatomic) BOOL registeredBusy;
@property(nonatomic) BOOL registeredRecovery;
@property(nonatomic) BOOL active;
@property(nonatomic, copy) void (^changed)(void);
@end

@implementation GLBusyObservation
+ (instancetype)observeChanges:(void (^)(void))changed {
    return [self observeChanges:changed timeout:5.0];
}
+ (instancetype)observeChanges:(void (^)(void))changed timeout:(NSTimeInterval)timeout {
    if (!changed || !isfinite(timeout) || timeout < 1 || timeout > 5) return nil;
    [GLCursorBridge available];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        busyConnection = (MainConnectionFn)dlsym(RTLD_DEFAULT, "CGSMainConnectionID");
        unresponsive = (UnresponsiveFn)dlsym(RTLD_DEFAULT, "CGSEventIsAppUnresponsive");
        setTimeout = (TimeoutFn)dlsym(RTLD_DEFAULT, "CGSEventSetAppIsUnresponsiveNotificationTimeout");
        registerNotice = (NotifyRegistrationFn)dlsym(RTLD_DEFAULT, "CGSRegisterNotifyProc");
        removeNotice = (NotifyRegistrationFn)dlsym(RTLD_DEFAULT, "CGSRemoveNotifyProc");
    });
    if (!busyConnection || !unresponsive || !setTimeout || !registerNotice || !removeNotice) return nil;
    @synchronized (GLBusyObservation.class) { if (busyChanged) return nil; }
    // The default notification threshold can exceed a short beachball. Without
    // this connection-scoped threshold the query remains false even during a
    // real eight-second event-loop hang. No application timeout is changed.
    if (setTimeout(busyConnection(), timeout) != kCGErrorSuccess) return nil;
    GLBusyObservation *observer = [GLBusyObservation new];
    observer.changed = changed;
    observer.active = YES;
    __weak GLBusyObservation *weakObserver = observer;
    @synchronized (GLBusyObservation.class) {
        busyChanged = ^{
            GLBusyObservation *strong = weakObserver;
            if (strong.active) strong.changed();
        };
    }
    observer.registeredBusy = registerNotice(BusyNotification, 750, NULL) == kCGErrorSuccess;
    observer.registeredRecovery = registerNotice(BusyNotification, 751, NULL) == kCGErrorSuccess;
    if (!observer.registeredBusy || !observer.registeredRecovery) { [observer invalidate]; return nil; }
    return observer;
}
- (BOOL)isUnresponsive:(int32_t)pid {
    if (!self.active || pid <= 0 || !busyConnection || !unresponsive) return NO;
    ProcessSerialNumber psn = {0};
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    OSStatus code = GetProcessForPID(pid, &psn);
#pragma clang diagnostic pop
    return code == noErr && unresponsive(busyConnection(), &psn);
}
- (void)invalidate {
    if (!self.active) return;
    self.active = NO;
    @synchronized (GLBusyObservation.class) { busyChanged = nil; }
    if (self.registeredBusy) removeNotice(BusyNotification, 750, NULL);
    if (self.registeredRecovery) removeNotice(BusyNotification, 751, NULL);
    self.registeredBusy = NO; self.registeredRecovery = NO; self.changed = nil;
}
- (void)dealloc { [self invalidate]; }
@end
