// Embedded signing setup. Certificate availability is not proof of iOS trust.
+ (NSString *)embeddedCertificateError:(NSData *)p12 password:(NSString *)password hostBundle:(NSBundle *)host {
    NSData *profile = [NSData dataWithContentsOfURL:[host.bundleURL URLByAppendingPathComponent:@"embedded.mobileprovision"]];
    if (!profile) return @"The installed host profile is missing. Reinstall this combined build with all extensions retained.";
    NSRange start = [profile rangeOfData:[@"<?xml" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0, profile.length)];
    if (start.location == NSNotFound) return @"The installed host profile is unreadable.";
    NSRange end = [profile rangeOfData:[@"</plist>" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(start.location, profile.length - start.location)];
    if (end.location == NSNotFound) return @"The installed host profile is incomplete.";
    NSDictionary *dict = [NSPropertyListSerialization propertyListWithData:[profile subdataWithRange:NSMakeRange(start.location, NSMaxRange(end) - start.location)] options:0 format:nil error:nil];
    if (![dict isKindOfClass:NSDictionary.class]) return @"The installed host profile is unreadable.";
    NSString *team = [self getCertTeamIdWithKeyData:p12 password:password];
    NSString *hostTeam = dict[@"Entitlements"][@"com.apple.developer.team-identifier"];
    if (!team || ![team isEqualToString:hostTeam]) return @"The signing certificate belongs to a different team. Sign in to SideInstaller with the account/team that signed this LiveContainer. No active certificate was replaced.";
    CFArrayRef items = NULL;
    OSStatus status = SecPKCS12Import((__bridge CFDataRef)p12, (__bridge CFDictionaryRef)@{(__bridge NSString *)kSecImportExportPassphrase: password}, &items);
    NSArray *imported = CFBridgingRelease(items);
    if (status != errSecSuccess || !imported.count) return @"The signing certificate/private key could not be decoded.";
    SecIdentityRef identity = (__bridge SecIdentityRef)imported.firstObject[(__bridge NSString *)kSecImportItemIdentity];
    SecCertificateRef cert = NULL;
    if (!identity || SecIdentityCopyCertificate(identity, &cert) != errSecSuccess) return @"The signing identity has no certificate.";
    NSData *der = CFBridgingRelease(SecCertificateCopyData(cert));
    CFRelease(cert);
    NSArray *allowed = dict[@"DeveloperCertificates"];
    if (![allowed isKindOfClass:NSArray.class] || ![allowed containsObject:der]) return @"This LiveContainer was installed with a different signing certificate. Open the built-in SideInstaller → Set up LiveContainer → Repair signing. Your existing active certificate was kept.";
    NSDate *expiry = dict[@"ExpirationDate"];
    if (![expiry isKindOfClass:NSDate.class] || [expiry timeIntervalSinceNow] <= 0) return @"The installed host profile has expired. Use Set up LiveContainer → Repair signing.";
    return nil;
}

+ (NSString *)embeddedActivateCertificate:(NSData *)p12 password:(NSString *)password hostBundle:(NSBundle *)host {
    NSString *error = [self embeddedCertificateError:p12 password:password hostBundle:host];
    if (error) return error;
    NSString *group = LCSharedUtils.appGroupID;
    if (!group.length || !LCSharedUtils.appGroupPath) return @"The shared app group is inaccessible. Reinstall with app groups and all extensions retained.";
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:group];
    [defaults setObject:p12 forKey:@"LCCertificateData"];
    [self setCertificatePassword:password];
    [defaults setObject:NSDate.date forKey:@"LCCertificateUpdateDate"];
    return nil;
}

+ (void)embeddedValidateJITLessWithHostBundle:(NSBundle *)host completion:(void (^)(BOOL, NSError *))completion {
    // Each attempt gets a fresh inode/path. Never reuse a prior failed test file
    // or rely on a copy operation whose error was ignored.
    NSURL *directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    NSURL *library = [directory URLByAppendingPathComponent:@"TestJITLess.dylib"];
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error] ||
        ![NSFileManager.defaultManager copyItemAtURL:[host.bundleURL URLByAppendingPathComponent:@"Frameworks/TestJITLess.dylib"] toURL:library error:&error]) {
        [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, error); });
        return;
    }
    [self signFilesWithZSignWithURLs:@[library] completionHandler:^(BOOL success, NSError *signError) {
        // Signing can call back on either queue. Kernel validation stays off the
        // main thread, and there is no semaphore blocking its error callback.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            BOOL valid = success && checkCodeSignature(library.path.UTF8String);
            NSError *result = signError;
            if (success && !valid) {
                NSString *detail = [NSUserDefaults.standardUserDefaults stringForKey:@"SILastSignatureError"] ?: @"Unknown signature error";
                result = [NSError errorWithDomain:@"SideInstaller.Signing" code:2 userInfo:@{NSLocalizedDescriptionKey:
                    [@"iOS rejected the signed test library. " stringByAppendingString:detail]}];
            }
            [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(valid, result); });
        });
    }];
}
