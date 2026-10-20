// macOS fixtures for the production activation gate. This does not simulate
// iOS code trust: the real-device signing test remains required.
#import <Foundation/Foundation.h>
#import <Security/Security.h>

static NSString *suite;
static NSURL *directory;
@interface LCSharedUtils : NSObject
+ (NSString *)appGroupID;
+ (NSURL *)appGroupPath;
@end
@implementation LCSharedUtils
+ (NSString *)appGroupID { return suite; }
+ (NSURL *)appGroupPath { return directory; }
@end

@interface LCUtils : NSObject
+ (NSString *)getCertTeamIdWithKeyData:(NSData *)data password:(NSString *)password;
+ (void)setCertificatePassword:(NSString *)password;
+ (void)signFilesWithZSignWithURLs:(NSArray *)urls completionHandler:(void (^)(BOOL, NSError *))completion;
@end
static bool checkCodeSignature(const char *path) { abort(); } // Never fake a passed iOS trust test.
@implementation LCUtils
// Isolate certificate/profile membership from the upstream OpenSSL OU parser.
+ (NSString *)getCertTeamIdWithKeyData:(NSData *)data password:(NSString *)password { return @"ABCDEFGHIJ"; }
+ (void)setCertificatePassword:(NSString *)password {
    [[[NSUserDefaults alloc] initWithSuiteName:suite] setObject:password forKey:@"LCCertificatePassword"];
}
+ (void)signFilesWithZSignWithURLs:(NSArray *)urls completionHandler:(void (^)(BOOL, NSError *))completion { abort(); }
#include "SigningSetup.m.inc"
@end

static void require(BOOL condition, NSString *message) {
    if (!condition) { NSLog(@"FAILED: %@", message); exit(1); }
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        require(argc == 2, @"PKCS#12 fixture argument required");
        suite = [@"SideInstaller.SigningTests." stringByAppendingString:NSUUID.UUID.UUIDString];
        directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:suite]];
        NSFileManager *manager = NSFileManager.defaultManager;
        [manager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *bundleURL = [directory URLByAppendingPathComponent:@"Fixture.app"];
        [manager createDirectoryAtURL:bundleURL withIntermediateDirectories:YES attributes:nil error:nil];
        [@{@"CFBundleIdentifier": @"com.aault.signing.fixture", @"CFBundleExecutable": @"Fixture"}
            writeToURL:[bundleURL URLByAppendingPathComponent:@"Info.plist"] atomically:YES];
        NSBundle *bundle = [NSBundle bundleWithURL:bundleURL];
        NSData *p12 = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
        CFArrayRef items = NULL;
        OSStatus status = SecPKCS12Import((__bridge CFDataRef)p12,
            (__bridge CFDictionaryRef)@{(__bridge NSString *)kSecImportExportPassphrase: @"fixture"}, &items);
        NSArray *imported = CFBridgingRelease(items);
        require(status == errSecSuccess && imported.count, @"fixture must contain a readable private identity");
        SecIdentityRef identity = (__bridge SecIdentityRef)imported.firstObject[(__bridge NSString *)kSecImportItemIdentity];
        SecCertificateRef cert = NULL;
        require(SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, @"fixture certificate");
        NSData *der = CFBridgingRelease(SecCertificateCopyData(cert)); CFRelease(cert);
        NSMutableDictionary *profile = [@{
            @"Entitlements": @{@"com.apple.developer.team-identifier": @"ABCDEFGHIJ"},
            @"DeveloperCertificates": @[[NSData dataWithBytes:"other" length:5]],
            @"ExpirationDate": [NSDate dateWithTimeIntervalSinceNow:3600]
        } mutableCopy];
        NSURL *profileURL = [bundleURL URLByAppendingPathComponent:@"embedded.mobileprovision"];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        NSData *sentinel = [@"keep-existing" dataUsingEncoding:NSUTF8StringEncoding];
        [defaults setObject:sentinel forKey:@"LCCertificateData"];
        [defaults setObject:@"keep-password" forKey:@"LCCertificatePassword"];
        for (NSUInteger scenario = 0; scenario < 4; scenario++) {
            if (scenario == 1) profile[@"DeveloperCertificates"] = @[der];
            if (scenario == 2) profile[@"ExpirationDate"] = [NSDate dateWithTimeIntervalSinceNow:-3600];
            if (scenario == 3) {
                profile[@"ExpirationDate"] = [NSDate dateWithTimeIntervalSinceNow:3600];
                profile[@"Entitlements"] = @{@"com.apple.developer.team-identifier": @"OTHERTEAM1"};
            }
            // Use XML, like the XML payload in a signed mobileprovision.
            [[NSPropertyListSerialization dataWithPropertyList:profile format:NSPropertyListXMLFormat_v1_0 options:0 error:nil] writeToURL:profileURL atomically:YES];
            NSString *issue = [LCUtils embeddedActivateCertificate:p12 password:scenario == 1 ? @"wrong" : @"fixture" hostBundle:bundle];
            require(issue.length > 0, @"incompatible identity must be rejected");
            require([[defaults dataForKey:@"LCCertificateData"] isEqual:sentinel], @"rejection must retain active certificate");
            require([[defaults stringForKey:@"LCCertificatePassword"] isEqual:@"keep-password"], @"rejection must retain password");
        }
        profile[@"Entitlements"] = @{@"com.apple.developer.team-identifier": @"ABCDEFGHIJ"};
        [[NSPropertyListSerialization dataWithPropertyList:profile format:NSPropertyListXMLFormat_v1_0 options:0 error:nil] writeToURL:profileURL atomically:YES];
        require([LCUtils embeddedActivateCertificate:p12 password:@"fixture" hostBundle:bundle] == nil, @"authorised identity activation");
        require([[defaults dataForKey:@"LCCertificateData"] isEqual:p12], @"activated identity");
        require([[defaults stringForKey:@"LCCertificatePassword"] isEqual:@"fixture"], @"activated password");
        [defaults removePersistentDomainForName:suite];
        [manager removeItemAtURL:directory error:nil];
        puts("Production activation gate passed: mismatched leaf, wrong password, expired profile, wrong team, and authorised identity.");
    }
    return 0;
}
