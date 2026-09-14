#import "SHVisibilityAssertion.h"

#import <dlfcn.h>
#import <objc/runtime.h>

@interface NSObject (ShelfMenuBarClientBridge)
- (id)initWithAllowedSystemItems:(NSArray<NSNumber *> *)items
      allowedBundleIdentifiers:(NSArray<NSString *> *)identifiers;
- (void)activateWithConfiguration:(id)configuration
                completionHandler:(void (^)(NSError * _Nullable error))completion;
- (void)invalidate;
@end

static NSString *const SHVisibilityErrorDomain = @"Shelf.VisibilityAssertion";

static NSError *SHVisibilityError(NSString *message) {
    return [NSError errorWithDomain:SHVisibilityErrorDomain
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static void SHEnsureFrameworkLoaded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore",
               RTLD_LAZY);
    });
}

@implementation SHVisibilityAssertion {
    NSArray<NSString *> *_allowedBundles;
    NSArray<NSNumber *> *_systemItems;
    id _assertion;
    BOOL _invalidated;
}

+ (BOOL)isAvailable {
    SHEnsureFrameworkLoaded();
    Class configurationClass = NSClassFromString(@"MBAssessmentModeConfiguration");
    Class assertionClass = NSClassFromString(@"MBAssessmentModeAssertion");
    if (!configurationClass || !assertionClass) {
        return NO;
    }
    return [configurationClass instancesRespondToSelector:@selector(initWithAllowedSystemItems:allowedBundleIdentifiers:)]
        && [assertionClass instancesRespondToSelector:@selector(init)]
        && [assertionClass instancesRespondToSelector:@selector(activateWithConfiguration:completionHandler:)]
        && [assertionClass instancesRespondToSelector:@selector(invalidate)];
}

- (instancetype)initWithAllowedBundles:(NSArray<NSString *> *)bundles
                           systemItems:(NSArray<NSNumber *> *)systemItems {
    self = [super init];
    if (self) {
        _allowedBundles = [bundles copy];
        _systemItems = [systemItems copy];
    }
    return self;
}

- (void)activateWithCompletion:(void (^)(NSError * _Nullable error))completion {
    void (^done)(NSError * _Nullable) = [completion copy];
    @try {
        if (_invalidated) {
            done(SHVisibilityError(@"This assertion has already been invalidated."));
            return;
        }
        if (_assertion != nil) {
            done(SHVisibilityError(@"This assertion is already active."));
            return;
        }
        if (![SHVisibilityAssertion isAvailable]) {
            done(SHVisibilityError(@"The menu bar backend is not available on this system."));
            return;
        }
        id configuration = [[NSClassFromString(@"MBAssessmentModeConfiguration") alloc]
            initWithAllowedSystemItems:_systemItems
              allowedBundleIdentifiers:_allowedBundles];
        if (!configuration) {
            done(SHVisibilityError(@"Could not create the menu bar configuration."));
            return;
        }
        id assertion = [[NSClassFromString(@"MBAssessmentModeAssertion") alloc] init];
        if (!assertion) {
            done(SHVisibilityError(@"Could not create the menu bar assertion."));
            return;
        }
        _assertion = assertion;
        [assertion activateWithConfiguration:configuration
                           completionHandler:^(NSError * _Nullable error) {
            done(error);
        }];
    } @catch (NSException *exception) {
        done(SHVisibilityError(@"The menu bar backend raised an exception."));
    }
}

- (void)invalidate {
    _invalidated = YES;
    id assertion = _assertion;
    _assertion = nil;
    if (assertion) {
        @try {
            [assertion invalidate];
        } @catch (NSException *exception) {
        }
    }
}

- (void)dealloc {
    _invalidated = YES;
    id assertion = _assertion;
    _assertion = nil;
    if (assertion) {
        @try {
            [assertion invalidate];
        } @catch (NSException *exception) {
        }
    }
}

@end
