#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface GLCursorBridge : NSObject
+ (BOOL)available;
+ (NSString *)diagnostics;
+ (nullable NSDictionary<NSString *, id> *)readCursor:(NSString *)identifier;
+ (nullable NSDictionary<NSString *, id> *)currentCursor;
+ (int32_t)registerCursor:(NSDictionary<NSString *, id> *)cursor identifier:(NSString *)identifier;
@end
NS_ASSUME_NONNULL_END
