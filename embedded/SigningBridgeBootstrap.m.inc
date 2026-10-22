    if (isSideStore) {
        NSBundle *host = lcMainBundle;
        if (isLiveProcess) {
            host = [NSBundle bundleWithURL:host.bundleURL.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent];
        }
        NSString *framework = [host.bundlePath stringByAppendingPathComponent:@"Frameworks/LiveContainerSwiftUI.framework/LiveContainerSwiftUI"];
        if (!framework.length) return @"The embedded signing bridge could not locate the LiveContainer host bundle.";
        // Retain the image for the lifetime of the guest. Do not call the UI's
        // main function: LiveProcess needs its signing API without launching LCUI.
        void *signingFramework = dlopen(framework.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
        if (!signingFramework) {
            const char *detail = dlerror();
            return [NSString stringWithFormat:@"The host signing framework could not load: %s", detail ?: "unknown loader error"];
        }
        Class signing = NSClassFromString(@"LCUtils");
        for (NSString *method in @[@"embeddedActivateCertificate:password:hostBundle:",
                                   @"embeddedValidateJITLessWithHostBundle:completion:"]) {
            if (![signing respondsToSelector:NSSelectorFromString(method)]) {
                return [NSString stringWithFormat:@"The combined build's host signing framework is missing %@. Install a rebuilt combined IPA.", method];
            }
        }
    }
