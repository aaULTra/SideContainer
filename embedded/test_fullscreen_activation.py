"""Exercise the production modern-activation hook with Foundation doubles."""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


@unittest.skipUnless(sys.platform == 'darwin', 'requires Objective-C Foundation on macOS CI')
class FullscreenActivationTests(unittest.TestCase):
    def test_new_sessions_only_and_request_preservation(self):
        harness = r'''#import <Foundation/Foundation.h>
@interface UISceneActivationRequestOptions : NSObject <NSCopying>
@property BOOL fullscreen;
@property NSString *otherOption;
- (void)_setRequestFullscreen:(BOOL)value;
@end
@implementation UISceneActivationRequestOptions
- (void)_setRequestFullscreen:(BOOL)value { self.fullscreen = value; }
- (id)copyWithZone:(NSZone *)zone {
    UISceneActivationRequestOptions *copy = [UISceneActivationRequestOptions new];
    copy.fullscreen = self.fullscreen; copy.otherOption = self.otherOption; return copy;
}
@end
@interface UISceneSessionActivationRequest : NSObject <NSCopying>
@property id session;
@property id userActivity;
@property id role;
@property UISceneActivationRequestOptions *options;
@end
@implementation UISceneSessionActivationRequest
- (id)copyWithZone:(NSZone *)zone {
    UISceneSessionActivationRequest *copy = [UISceneSessionActivationRequest new];
    copy.session = self.session; copy.userActivity = self.userActivity;
    copy.role = self.role; copy.options = self.options; return copy;
}
@end
@interface UIApplication : NSObject
@property UISceneSessionActivationRequest *received;
@property int count;
- (void)activateSceneSessionForRequest:(UISceneSessionActivationRequest *)request errorHandler:(void (^)(NSError *))handler;
@end
@implementation UIApplication
- (void)activateSceneSessionForRequest:(UISceneSessionActivationRequest *)request errorHandler:(void (^)(NSError *))handler {
    self.received = request; self.count++;
    if (handler) handler([NSError errorWithDomain:@"fixture" code:7 userInfo:nil]);
}
@end
@interface SIFullscreenActivationHooks : NSObject
+ (void)install;
@end
#include "FullscreenActivation.m.inc"
int main(void) {
    @autoreleasepool {
        [SIFullscreenActivationHooks install];
        [SIFullscreenActivationHooks install]; // must not undo the swizzle
        UIApplication *app = [UIApplication new];
        UISceneSessionActivationRequest *request = [UISceneSessionActivationRequest new];
        request.role = @"window"; request.userActivity = @"guest-activity";
        request.options = [UISceneActivationRequestOptions new];
        request.options.otherOption = @"preserve";
        __block int errors = 0;
        void (^handler)(NSError *) = ^(NSError *error) { NSCAssert(error.code == 7, @"error preserved"); errors++; };
        [app activateSceneSessionForRequest:request errorHandler:handler];
        NSCAssert(app.count == 1 && errors == 1, @"forward exactly once");
        NSCAssert(app.received != request && app.received.options != request.options, @"copy caller state");
        NSCAssert(app.received.options.fullscreen && !request.options.fullscreen, @"new scene fullscreen only on copy");
        NSCAssert(app.received.userActivity == request.userActivity && app.received.role == request.role, @"routing preserved");
        NSCAssert([app.received.options.otherOption isEqual:@"preserve"], @"options preserved");

        request.options = nil;
        [app activateSceneSessionForRequest:request errorHandler:nil];
        NSCAssert(app.received.options.fullscreen && request.options == nil, @"create missing options");

        request.session = @"existing-resized-window";
        request.options = [UISceneActivationRequestOptions new];
        [app activateSceneSessionForRequest:request errorHandler:handler];
        NSCAssert(app.received == request && !app.received.options.fullscreen, @"never force an existing window");
        request.options.fullscreen = YES; // explicit one-time guest correction
        [app activateSceneSessionForRequest:request errorHandler:nil];
        NSCAssert(app.received.options.fullscreen, @"keep explicit target-scene request");
        NSCAssert(app.count == 4 && errors == 2, @"callbacks preserved");
    }
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'activation.m'
            source.write_text(harness)
            result = subprocess.run(['clang', '-fobjc-arc', '-fblocks', '-framework', 'Foundation',
                                     '-I', str(Path(__file__).parent.resolve()), str(source),
                                     '-o', str(root / 'activation')], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(root / 'activation')], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
