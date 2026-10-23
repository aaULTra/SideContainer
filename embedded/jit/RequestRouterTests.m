#import <Foundation/Foundation.h>
#include "RequestRouter.m.inc"

@interface TestContext : NSObject
@property(nonatomic, strong) NSArray *inputItems;
@property(nonatomic, strong) NSError *error;
@property(nonatomic) NSUInteger starts;
@end
@implementation TestContext
- (void)cancelRequestWithError:(NSError *)error { self.error = error; }
@end

@interface TestJITHandler : NSObject<NSExtensionRequestHandling>
@end
@implementation TestJITHandler
- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context {
    TestContext *test = (id)context;
    test.starts++;
}
@end

static NSUInteger loads;
static Class loadClass;
static Class test_loader(NSURL *url, NSError **error) {
    loads++;
    NSCAssert([url.path isEqual:@"/App/LiveContainer.app/Frameworks/SIJITSupport.framework"], @"Wrong service path");
    if (!loadClass) *error = si_jit_route_error(@"Fixture load failed");
    return loadClass;
}
static TestContext *context(NSDictionary *info) {
    TestContext *test = [TestContext new];
    NSExtensionItem *item = [NSExtensionItem new];
    item.userInfo = info;
    test.inputItems = @[item];
    return test;
}
static BOOL route(TestContext *test, NSString *path) {
    return si_route_jit_request((id)test, [NSURL fileURLWithPath:path], test_loader);
}

int main(void) { @autoreleasepool {
    NSString *process = @"/App/LiveContainer.app/PlugIns/LiveProcess.appex";
    NSDictionary *request = @{@"SideInstaller.JIT.request": [@"{}" dataUsingEncoding:NSUTF8StringEncoding]};
    TestContext *guest = context(@{@"selected": @"guest", @"endpoint": @"refresh"});
    NSCAssert(!route(guest, process) && !guest.error && loads == 0 && !si_jit_service_active,
              @"Ordinary guest/refresh routing must remain unchanged");

    TestContext *malformed = context(@{@"SideInstaller.JIT.request": @"not data"});
    NSCAssert(route(malformed, process) && malformed.error && loads == 0,
              @"Invalid JIT payload must fail before loading a guest or service");
    NSMutableDictionary *mixed = [request mutableCopy]; mixed[@"selected"] = @"guest";
    TestContext *ambiguous = context(mixed);
    NSCAssert(route(ambiguous, process) && ambiguous.error && loads == 0, @"Do not combine guest and JIT requests");

    TestContext *wrongHost = context(request);
    NSCAssert(route(wrongHost, @"/App/LiveContainer.app") && wrongHost.error && loads == 0,
              @"JIT must never execute in the host UI");
    TestContext *missing = context(request);
    NSCAssert(route(missing, process) && missing.error && missing.starts == 0 && loads == 1,
              @"A missing framework must report failure");
    loadClass = NSObject.class;
    TestContext *wrongClass = context(request);
    NSCAssert(route(wrongClass, process) && wrongClass.error && wrongClass.starts == 0,
              @"The loaded class must implement the extension request protocol");

    loadClass = TestJITHandler.class;
    TestContext *valid = context(request);
    NSCAssert(route(valid, process) && !valid.error && valid.starts == 1,
              @"The original extension context must reach the JIT handler once");
    NSCAssert(si_jit_service_active && si_jit_request_handler, @"Retain the service handler through asynchronous work");
    NSCAssert(!route(guest, process) && guest.starts == 0, @"Guest requests must not enter the helper");
    NSError *error = nil;
    NSCAssert(!si_load_jit_service([NSURL fileURLWithPath:@"/nonexistent/SIJITSupport.framework"], &error) && error,
              @"The real loader must return an actionable missing-framework error");
    puts("JIT service request routing checks passed");
    return 0;
} }
