/* BCD 580 compatibility repair. No guest executable instructions are changed.
 * A single imported socketpair slot is guarded for calls from wine_process_start.
 * Other socketpairs and all ready Wine launches keep their original path.
 */
#import <Foundation/Foundation.h>
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE && !defined(BCD_GUARD_FIXTURE)
#import <UIKit/UIKit.h>
#endif
#include <dlfcn.h>
#include <errno.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#include "Readiness.h"
#include "GuardImage.h"

#ifndef BCD_GUARD_TIMEOUT
#define BCD_GUARD_TIMEOUT 10.0
#endif

static uintptr_t image_base;
static int installed;
static int (*original_socketpair)(int, int, int, int *);
static int (*server_ready)(void);
static int (*server_running)(void);

static void repair_log(NSString *message) {
    fprintf(stderr, "[BCD-WineStartup] %s\n", message.UTF8String);
}

static void report_failure(NSString *message) {
    repair_log(message);
#if TARGET_OS_IPHONE && !defined(BCD_GUARD_FIXTURE)
    /* The existing launch monitor returns to the library in about two seconds. */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (!window.isKeyWindow || !window.rootViewController) continue;
                UIViewController *view = window.rootViewController;
                while (view.presentedViewController && !view.presentedViewController.isBeingDismissed) view = view.presentedViewController;
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Wine could not start" message:message preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [view presentViewController:alert animated:YES completion:nil];
                return;
            }
        }
    });
#endif
}

static int probe_running(void *unused) { return server_running(); }
static int probe_ready(void *unused) { return server_ready(); }
static double probe_now(void *unused) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1000000000.0;
}
static void probe_pause(void *unused) { struct timespec delay={0, 10000000}; nanosleep(&delay, NULL); }

/* Merge only the effective opt-in DLL list in this game's existing config.
 * Preserve its other lines and retain a one-time backup before changing it.
 */
static BOOL prepare_ghost(NSString **failure) {
    const char *exe = getenv("MADEIRA_EXE");
    if (!exe) return YES;
    NSString *program = [[NSString stringWithUTF8String:exe] stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    if (!program || [program.lastPathComponent caseInsensitiveCompare:@"GhostOfTsushima.exe"] != NSOrderedSame) return YES;
#if !defined(BCD_GUARD_FIXTURE)
    NSString *farm = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"arm64ec-windows"];
    for (NSString *name in @[@"ntdsapi.dll", @"evr-optin.dll", @"dxva2-optin.dll"]) {
        if (![NSFileManager.defaultManager isReadableFileAtPath:[farm stringByAppendingPathComponent:name]]) {
            *failure = [NSString stringWithFormat:@"Ghost of Tsushima needs %@, but it is missing from this BCD installation. Import the complete Wine repair IPA into LiveContainer again.", name];
            return NO;
        }
    }
#endif
    NSString *key = @"env.MADEIRA_OPTIN_DLLS";
    const char *cfg = getenv("MADEIRA_CFG_GAME");
    NSString *path = cfg && *cfg ? [NSString stringWithUTF8String:cfg] : nil;
    NSString *text = @"";
    NSError *error = nil;
    if (path && [NSFileManager.defaultManager fileExistsAtPath:path]) {
        text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
        if (!text) { *failure = @"Ghost's Wine configuration could not be read. Its settings were left unchanged. Check the game configuration file before trying again."; return NO; }
    }
    NSString *current = getenv("MADEIRA_OPTIN_DLLS") ? [NSString stringWithUTF8String:getenv("MADEIRA_OPTIN_DLLS")] : @"";
    for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *trim = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([trim hasPrefix:@"#"]) continue;
        NSRange equal = [trim rangeOfString:@"="];
        if (equal.location == NSNotFound) continue;
        if ([[[trim substringToIndex:equal.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] isEqualToString:key]) {
            current = [[trim substringFromIndex:equal.location+1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        }
    }
    NSMutableOrderedSet<NSString *> *names = [NSMutableOrderedSet orderedSet];
    for (NSString *part in [current componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@",; \t"]]) {
        NSString *name = part.lowercaseString;
        if ([name hasSuffix:@".dll"]) name = [name substringToIndex:name.length-4];
        if (name.length) [names addObject:name];
    }
    BOOL changed = ![names containsObject:@"evr"] || ![names containsObject:@"dxva2"];
    [names addObject:@"evr"]; [names addObject:@"dxva2"];
    NSString *merged = [names.array componentsJoinedByString:@","];
    if (path && changed) {
        NSString *backup = [path stringByAppendingString:@".before-wine-repair"];
        if ([NSFileManager.defaultManager fileExistsAtPath:path] && ![NSFileManager.defaultManager fileExistsAtPath:backup] &&
            ![NSFileManager.defaultManager copyItemAtPath:path toPath:backup error:&error]) {
            *failure = @"Ghost's Wine settings could not be backed up, so the repair did not change them."; return NO;
        }
        NSString *updated = [text stringByAppendingFormat:@"%@# BCD Wine repair: video-helper dependencies for this game.\n%@ = %@\n", [text hasSuffix:@"\n"] || !text.length ? @"" : @"\n", key, merged];
        if (![updated writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
            *failure = @"Ghost's Wine settings could not be saved. Check that the game configuration folder is writable before trying again."; return NO;
        }
    }
    setenv("MADEIRA_OPTIN_DLLS", merged.UTF8String, 1);
    repair_log([NSString stringWithFormat:@"Ghost video dependencies enabled for this game: %@", merged]);
    return YES;
}

__attribute__((noinline)) static int guarded_socketpair(int domain, int type, int protocol, int *pair) {
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    if (caller < image_base + BCD_WINE_START || caller >= image_base + BCD_WINE_END)
        return original_socketpair(domain, type, protocol, pair);
    double began = probe_now(NULL);
    BCDServerProbe probe={probe_running, probe_ready, probe_now, probe_pause, NULL};
    BCDServerResult result = bcd_wait_for_server(probe, BCD_GUARD_TIMEOUT);
    if (result != BCD_SERVER_READY) {
        NSString *reason = result == BCD_SERVER_STOPPED
            ? @"Wine's server stopped before startup completed. The Windows program was not launched. Check the preceding Wine server error in the log, then close BCD and reopen it."
            : @"Wine's server did not finish starting within 10 seconds. The Windows program was not launched. Check the preceding Wine server error in the log, then close BCD and reopen it.";
        report_failure(reason);
        if (pair) { pair[0]=-1; pair[1]=-1; }
        errno = result == BCD_SERVER_STOPPED ? EPIPE : ETIMEDOUT;
        return -1;
    }
    @autoreleasepool {
        NSString *failure=nil;
        if (!prepare_ghost(&failure)) { report_failure(failure); if (pair) { pair[0]=-1; pair[1]=-1; } errno=EIO; return -1; }
        repair_log([NSString stringWithFormat:@"server VERIFIED ready before Wine connection (%.0f ms)", (probe_now(NULL)-began)*1000.0]);
    }
    return original_socketpair(domain, type, protocol, pair);
}

static BOOL matches_image(const struct mach_header *header) {
    if (header->magic != MH_MAGIC_64 || header->cputype != BCD_IMAGE_CPU) return NO;
    const struct mach_header_64 *h=(const void *)header;
    const uint8_t *p=(const uint8_t *)(h+1), *end=p+h->sizeofcmds;
    for (uint32_t i=0; i<h->ncmds && p+sizeof(struct load_command)<=end; i++) {
        const struct load_command *c=(const void *)p;
        if (c->cmdsize<sizeof(*c) || p+c->cmdsize>end) return NO;
        if (c->cmd==LC_UUID && c->cmdsize>=sizeof(struct uuid_command)) {
            const struct uuid_command *uuid=(const void *)p;
            /* LC increments byte zero when it prepares an imported app. */
            return memcmp(uuid->uuid+1, BCD_IMAGE_UUID+1, 15)==0;
        }
        p+=c->cmdsize;
    }
    return NO;
}

static void image_added(const struct mach_header *header, intptr_t slide) {
    if (installed || !matches_image(header)) return;
    uintptr_t base=(uintptr_t)header;
    if (memcmp((void *)(base+BCD_WINE_START), BCD_START_BYTES, sizeof(BCD_START_BYTES)) ||
        memcmp((void *)(base+BCD_READY), BCD_READY_BYTES, sizeof(BCD_READY_BYTES))) {
        repair_log(@"Guard NOT installed: BCD function fingerprint mismatch."); return;
    }
    original_socketpair=dlsym(RTLD_NEXT, "socketpair");
    if (!original_socketpair) original_socketpair=dlsym(RTLD_DEFAULT, "socketpair");
    if (!original_socketpair) { repair_log(@"Guard NOT installed: socketpair could not be resolved."); return; }
    uintptr_t *slot=(void *)(base+BCD_SOCKETPAIR_SLOT);
    mach_vm_address_t page=(mach_vm_address_t)slot & ~((mach_vm_address_t)getpagesize()-1);
    mach_vm_address_t region=page; mach_vm_size_t region_size=0;
    vm_region_basic_info_data_64_t info={0}; mach_msg_type_number_t count=VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object=MACH_PORT_NULL;
    kern_return_t kr=mach_vm_region(mach_task_self(), &region, &region_size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object);
    if (object!=MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    if (kr!=KERN_SUCCESS) { repair_log(@"Guard NOT installed: import protection could not be inspected."); return; }
    kr=mach_vm_protect(mach_task_self(), page, (mach_vm_size_t)getpagesize(), FALSE, info.protection|VM_PROT_WRITE|VM_PROT_COPY);
    if (kr!=KERN_SUCCESS) { repair_log(@"Guard NOT installed: import pointer could not be made writable."); return; }
    image_base=base;
    server_ready=(void *)(base+BCD_READY);
    server_running=(void *)(base+BCD_RUNNING);
    __atomic_store_n(slot, (uintptr_t)guarded_socketpair, __ATOMIC_RELEASE);
    kr=mach_vm_protect(mach_task_self(), page, (mach_vm_size_t)getpagesize(), FALSE, info.protection);
    if (kr!=KERN_SUCCESS) repair_log(@"Warning: import page protection restore failed.");
    installed=1;
    repair_log(@"Readiness guard installed for this BCD build; Wine client startup only.");
}

int bcd_guard_installed(void) { return installed; }
__attribute__((constructor)) static void install_guard(void) {
    @autoreleasepool { _dyld_register_func_for_add_image(image_added); }
}
