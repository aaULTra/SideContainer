// JIT requests use a separate instance of the existing LiveProcess service.
// Run before guest bootstrap, bundle hooks or logging the guest request.
#import <Foundation/Foundation.h>

typedef Class (*SIJITServiceLoader)(NSURL *, NSError **);
static id<NSExtensionRequestHandling> si_jit_request_handler;
static BOOL si_jit_service_active;

static NSError *si_jit_route_error(NSString *message) {
    return [NSError errorWithDomain:@"SIJITService" code:1
                          userInfo:@{NSLocalizedDescriptionKey: message}];
}

static Class si_load_jit_service(NSURL *url, NSError **error) {
    NSBundle *bundle = [NSBundle bundleWithURL:url];
    if (!bundle || ![bundle loadAndReturnError:error]) {
        if (error && !*error) *error = si_jit_route_error(@"The built-in JIT framework could not be loaded. Update the combined app.");
        return Nil;
    }
    return NSClassFromString(@"SIJITHelperHandler");
}

static BOOL si_route_jit_request(NSExtensionContext *context, NSURL *processURL,
                                 SIJITServiceLoader loader) {
    id item = context.inputItems.firstObject;
    if (![item isKindOfClass:NSExtensionItem.class]) return NO;
    NSDictionary *info = [(NSExtensionItem *)item userInfo];
    id payload = info[@"SideInstaller.JIT.request"];
    if (!payload) return NO; // ordinary guest/refresh/custom-payload request
    si_jit_service_active = YES;
    if (![payload isKindOfClass:NSData.class] || info[@"selected"] || info[@"customPayloadDylib"]) {
        [context cancelRequestWithError:si_jit_route_error(@"Invalid or mixed JIT service request.")];
        return YES;
    }
    NSURL *plugins = processURL.URLByDeletingLastPathComponent;
    if (![processURL.pathExtension isEqualToString:@"appex"] ||
        ![plugins.lastPathComponent isEqualToString:@"PlugIns"]) {
        [context cancelRequestWithError:si_jit_route_error(@"JIT must run in the installed LiveProcess service.")];
        return YES;
    }
    NSURL *url = [plugins.URLByDeletingLastPathComponent
        URLByAppendingPathComponent:@"Frameworks/SIJITSupport.framework" isDirectory:YES];
    NSError *error = nil;
    Class handlerClass = loader(url, &error);
    if (!handlerClass || ![handlerClass conformsToProtocol:@protocol(NSExtensionRequestHandling)]) {
        [context cancelRequestWithError:error ?: si_jit_route_error(@"The built-in JIT handler is unavailable. Update the combined app.")];
        return YES;
    }
    si_jit_request_handler = [handlerClass new];
    [si_jit_request_handler beginRequestWithExtensionContext:context];
    return YES;
}
