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

NSBundle *SIEmbeddedHostBundle(void) {
    SEL selector = NSSelectorFromString(@"lcMainBundle");
    if (![NSUserDefaults respondsToSelector:selector]) return nil;
    NSBundle *bundle = ((NSBundle *(*)(id, SEL))objc_msgSend)(NSUserDefaults.class, selector);
    if (SIEmbeddedIsLiveProcess()) {
        bundle = [NSBundle bundleWithURL:bundle.bundleURL.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent];
    }
    return bundle;
}

NSString *SIEmbeddedEntitlementsAtPath(NSString *path) {
    Class cls = NSClassFromString(@"LCSharedUtils");
    SEL selector = NSSelectorFromString(@"embeddedEntitlementsAtPath:");
    if (![cls respondsToSelector:selector]) return nil;
    return ((NSString *(*)(id, SEL, id))objc_msgSend)(cls, selector, path);
}

void SIEmbeddedReturnToHost(void) {
    Class cls = NSClassFromString(@"LCSharedUtils");
    SEL selector = NSSelectorFromString(@"launchToGuestAppWithClassicMode:");
    if ([cls respondsToSelector:selector]) {
        ((BOOL (*)(id, SEL, NSUInteger))objc_msgSend)(cls, selector, 0);
    }
}

NSString *SIEmbeddedActivateCertificate(NSData *certificate, NSString *password) {
    Class cls = NSClassFromString(@"LCUtils");
    SEL selector = NSSelectorFromString(@"embeddedActivateCertificate:password:hostBundle:");
    NSBundle *host = SIEmbeddedHostBundle();
    if (!host || ![cls respondsToSelector:selector]) return @"The host signing setup bridge is unavailable. Install the updated combined build.";
    return ((NSString *(*)(id, SEL, id, id, id))objc_msgSend)(cls, selector, certificate, password, host);
}

void SIEmbeddedTestSigning(void (^completion)(BOOL, NSString *)) {
    Class cls = NSClassFromString(@"LCUtils");
    SEL selector = NSSelectorFromString(@"embeddedValidateJITLessWithHostBundle:completion:");
    NSBundle *host = SIEmbeddedHostBundle();
    if (!host || ![cls respondsToSelector:selector]) {
        completion(NO, @"The host signing test bridge is unavailable. Install the updated combined build.");
        return;
    }
    void (^callback)(BOOL, NSError *) = ^(BOOL valid, NSError *error) {
        completion(valid, error.localizedDescription);
    };
    ((void (*)(id, SEL, id, id))objc_msgSend)(cls, selector, host, callback);
}

NSURL *SIEmbeddedJITPairingURL(void) {
    NSBundle *host = SIEmbeddedHostBundle();
    if (![host.infoDictionary[@"SIEmbeddedBuild"] boolValue]) return nil;
    SEL selector = NSSelectorFromString(@"lcAppGroupPath");
    if (![NSUserDefaults respondsToSelector:selector]) return nil;
    NSString *path = ((id (*)(id, SEL))objc_msgSend)(NSUserDefaults.class, selector);
    if (!path.length || !path.isAbsolutePath) return nil;
    return [[NSURL fileURLWithPath:path isDirectory:YES] URLByAppendingPathComponent:@"SideInstaller/JIT/pairing.plist"];
}
