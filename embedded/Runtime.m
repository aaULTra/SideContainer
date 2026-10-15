#import "Runtime.h"
#import <objc/message.h>

BOOL SIEmbeddedIsLiveProcess(void) {
    SEL selector = NSSelectorFromString(@"isLiveProcess");
    return [NSUserDefaults respondsToSelector:selector]
        && ((BOOL (*)(id, SEL))objc_msgSend)(NSUserDefaults.class, selector);
}

NSString *SIEmbeddedHostTeam(void) {
    Class cls = NSClassFromString(@"LCSharedUtils");
    SEL selector = NSSelectorFromString(@"teamIdentifier");
    if (![cls respondsToSelector:selector]) return nil;
    return ((NSString *(*)(id, SEL))objc_msgSend)(cls, selector);
}

void SIEmbeddedReturnToHost(void) {
    Class cls = NSClassFromString(@"LCSharedUtils");
    SEL selector = NSSelectorFromString(@"launchToGuestAppWithClassicMode:");
    if ([cls respondsToSelector:selector]) {
        ((BOOL (*)(id, SEL, NSUInteger))objc_msgSend)(cls, selector, 0);
    }
}
