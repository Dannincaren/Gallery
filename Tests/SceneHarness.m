#import <AppKit/AppKit.h>
// Include the implementation so callback cancellation can be tested without
// posting notifications to the system, changing cursors or driving the UI.
#import "../Sources/GalleryNative/SceneObservation.m"
static void Check(BOOL value, const char *reason) { if (!value) { fprintf(stderr, "FAIL %s\n", reason); exit(1); } }
int main(void) { @autoreleasepool {
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    __block int calls = 0;
    for (int i = 0; i < 3; i++) {
        GLSceneObservation *observer = [GLSceneObservation observeChanges:^(int32_t type) { calls++; }];
        Check(observer != nil, "Read-only scene notification registration unavailable");
        Check([GLSceneObservation observeChanges:^(int32_t type) {}] == nil, "A second owner displaced observation");
        int before = calls;
        SceneNotification(1400, NULL, 0, NULL, 0);
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        Check(calls == before, "Space start notification survived completion-only policy");
        for (NSNumber *type in @[@1327, @1328, @1401]) SceneNotification(type.unsignedIntValue, NULL, 0, NULL, 0);
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        Check(calls == before + 3, "Mission Control / Space completion was not delivered");
        SceneNotification(1401, NULL, 0, NULL, 0);
        [observer invalidate]; [observer invalidate]; observer = nil;
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        Check(calls == before + 3, "A queued callback ran after stop");
    }
    puts("PASS read-only scene registration/restart, single owner, completion-only Space filtering, Mission Control delivery, queued callback cancellation and repeated cleanup; no cursor/UI changes");
} return 0; }
