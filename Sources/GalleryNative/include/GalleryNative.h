#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN
@class NSCursor;
@interface GLCursorResource : NSObject
@end
@interface GLCursorSnapshot : NSObject
@property(nonatomic, readonly) CGImageRef image;
@property(nonatomic, readonly) CGSize size;
@property(nonatomic, readonly) CGPoint hotSpot;
@property(nonatomic, readonly) int32_t seed;
@end

/// Read-only WindowServer responsiveness notifications. The observer configures
/// only this application's connection; no cursor resources or other apps change.
@interface GLBusyObservation : NSObject
+ (nullable instancetype)observeChanges:(void (^)(void))changed;
+ (nullable instancetype)observeChanges:(void (^)(void))changed timeout:(NSTimeInterval)timeout;
- (BOOL)isUnresponsive:(int32_t)pid;
- (void)invalidate;
@end

/// Read-only Mission Control entry/exit and Space completion; no event payloads.
@interface GLSceneObservation : NSObject
+ (nullable instancetype)observeChanges:(void (^)(int32_t type))changed;
- (void)invalidate;
@end

@interface GLCursorBridge : NSObject
+ (BOOL)available;
+ (NSString *)diagnostics;
+ (nullable NSDictionary<NSString *, id> *)readCursor:(NSString *)identifier;
+ (nullable NSDictionary<NSString *, id> *)currentCursor;
+ (nullable GLCursorSnapshot *)currentSnapshot;
+ (int32_t)cursorVisibility;
+ (int32_t)presentCursor:(NSCursor *)cursor;
+ (BOOL)missionControlActiveWithDockPIDs:(NSArray<NSNumber *> *)dock managerPIDs:(NSArray<NSNumber *> *)manager;
+ (void)setDockCursorOverride:(BOOL)enabled;
+ (int32_t)registerCursor:(NSDictionary<NSString *, id> *)cursor identifier:(NSString *)identifier;
+ (int32_t)updateCursor:(NSDictionary<NSString *, id> *)cursor identifier:(NSString *)identifier refresh:(BOOL)refresh;
+ (nullable GLCursorResource *)prepareCursor:(NSDictionary<NSString *, id> *)cursor;
+ (nullable GLCursorResource *)prepareImages:(NSArray *)images frameCount:(NSUInteger)count frameDuration:(NSTimeInterval)duration size:(CGSize)size hotSpot:(CGPoint)hotSpot;
+ (int32_t)applyPreparedCursor:(GLCursorResource *)cursor identifiers:(NSArray<NSString *> *)identifiers;
+ (int32_t)applyPreparedCursor:(GLCursorResource *)cursor identifiers:(NSArray<NSString *> *)identifiers showImmediately:(BOOL)show;
+ (int32_t)storePreparedCursor:(GLCursorResource *)cursor identifiers:(NSArray<NSString *> *)identifiers globally:(BOOL)global;
+ (int32_t)selectCursorIdentifier:(NSString *)identifier;
+ (int32_t)cursorSeed;
+ (nullable NSDictionary<NSString *, id> *)standardCursor:(NSString *)identifier;
+ (int32_t)setBackgroundCursorUpdates:(BOOL)enabled;
+ (int32_t)moveOverlayWindow:(int32_t)window origin:(CGPoint)origin;
+ (int32_t)clearCoreCursorCache;
@end
NS_ASSUME_NONNULL_END
