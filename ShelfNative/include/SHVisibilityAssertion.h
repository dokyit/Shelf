#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SHVisibilityAssertion : NSObject

+ (BOOL)isAvailable;

- (instancetype)initWithAllowedBundles:(NSArray<NSString *> *)bundles
                           systemItems:(NSArray<NSNumber *> *)systemItems;

- (void)activateWithCompletion:(void (^)(NSError * _Nullable error))completion;

- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
