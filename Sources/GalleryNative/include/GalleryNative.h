#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN
@class NSCursor;
@interface GLCursorSnapshot : NSObject
@property(nonatomic, readonly) CGImageRef image;
@property(nonatomic, readonly) CGSize size;
@property(nonatomic, readonly) CGPoint hotSpot;
@property(nonatomic, readonly) int32_t seed;
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
+ (int32_t)cursorSeed;
+ (nullable NSDictionary<NSString *, id> *)standardCursor:(NSString *)identifier;
+ (int32_t)setBackgroundCursorUpdates:(BOOL)enabled;
+ (int32_t)clearCoreCursorCache;
@end
NS_ASSUME_NONNULL_END
