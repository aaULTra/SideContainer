// SwiftUI can call the iOS 17 activation entry point directly. Hook it as
// well as LC's legacy requestSceneSessionActivation hook.
#import <objc/runtime.h>

@interface UIApplication (SIFullscreenActivation)
- (void)si_activateSceneSessionForRequest:(UISceneSessionActivationRequest *)request
                           errorHandler:(void (^)(NSError *))errorHandler API_AVAILABLE(ios(17.0));
@end

@implementation UIApplication (SIFullscreenActivation)
- (void)si_activateSceneSessionForRequest:(UISceneSessionActivationRequest *)request
                           errorHandler:(void (^)(NSError *))errorHandler {
    // Existing sessions include user resizing/rearrangement and explicit
    // focus requests. Leave their presentation preferences untouched.
    if (request.session != nil) {
        [self si_activateSceneSessionForRequest:request errorHandler:errorHandler];
        return;
    }
    // Preserve session, role, activity and all other options. Do not mutate a
    // caller-owned request, which SwiftUI may reuse for another window.
    UISceneSessionActivationRequest *fullscreenRequest = [request copy];
    UISceneActivationRequestOptions *options = [request.options copy] ?: [UISceneActivationRequestOptions new];
    [options _setRequestFullscreen:YES];
    fullscreenRequest.options = options;
    [self si_activateSceneSessionForRequest:fullscreenRequest errorHandler:errorHandler];
}
@end

@implementation SIFullscreenActivationHooks
+ (void)install {
    if (@available(iOS 17.0, *)) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            Method original = class_getInstanceMethod(UIApplication.class, @selector(activateSceneSessionForRequest:errorHandler:));
            Method replacement = class_getInstanceMethod(UIApplication.class, @selector(si_activateSceneSessionForRequest:errorHandler:));
            if (original && replacement) method_exchangeImplementations(original, replacement);
        });
    }
}
@end
