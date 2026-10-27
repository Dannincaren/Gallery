#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface GLCursorBridge : NSObject
+ (BOOL)available;
+ (NSString *)diagnostics;
+ (nullable NSDictionary<NSString *, id> *)readCursor:(NSString *)identifier;
+ (nullable NSDictionary<NSString *, id> *)currentCursor;
+ (int32_t)registerCursor:(NSDictionary<NSString *, id> *)cursor identifier:(NSString *)identifier;
+ (int32_t)updateCursor:(NSDictionary<NSString *, id> *)cursor identifier:(NSString *)identifier refresh:(BOOL)refresh;
+ (int32_t)cursorSeed;
+ (nullable NSDictionary<NSString *, id> *)standardCursor:(NSString *)identifier;
+ (int32_t)setBackgroundCursorUpdates:(BOOL)enabled;
+ (void)prepareOverlayWindow:(NSInteger)windowNumber;
+ (int32_t)clearCoreCursorCache;
@end
NS_ASSUME_NONNULL_END
