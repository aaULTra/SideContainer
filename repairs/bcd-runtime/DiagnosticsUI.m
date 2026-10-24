#import "Diagnostics.h"
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE && !defined(BCD_GUARD_FIXTURE)
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@interface BCDCopyDiagnosticActivity : UIActivity
@property(nonatomic,copy) NSArray<NSURL *> *logs;
@end
@implementation BCDCopyDiagnosticActivity
+ (UIActivityCategory)activityCategory { return UIActivityCategoryAction; }
- (UIActivityType)activityType { return @"com.thebcd69.bcd.copy-diagnostic.v3"; }
- (NSString *)activityTitle { return @"Copy diagnostic report"; }
- (UIImage *)activityImage { return [UIImage systemImageNamed:@"doc.on.clipboard"]; }
- (BOOL)canPerformWithActivityItems:(NSArray *)items { return self.logs.count>0; }
- (void)performActivity {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        NSString *report=BCDCreateCurrentDiagnosticReport(self.logs);
        dispatch_async(dispatch_get_main_queue(),^{ UIPasteboard.generalPasteboard.string=report; [self activityDidFinish:YES]; });
    });
}
@end
static BOOL logURL(NSURL *url) {
    if (!url.isFileURL) return NO;
    NSArray *names=@[@"BCD log.txt",@"BCD log (the run before).txt",@"bcd-log.txt",@"bcd-log.prev.txt"];
    if (![names containsObject:url.lastPathComponent]) return NO;
    NSString *path=url.URLByResolvingSymlinksInPath.path;
    NSString *docs=[BCDDiagnosticDocuments().URLByResolvingSymlinksInPath.path stringByAppendingString:@"/"];
    NSString *temporary=[NSURL fileURLWithPath:NSTemporaryDirectory()].URLByResolvingSymlinksInPath.path;
    return [path hasPrefix:docs] || ([path hasPrefix:[temporary stringByAppendingString:@"/"]] && [url.URLByDeletingLastPathComponent.lastPathComponent isEqualToString:@"BCD logs"]);
}
@interface UIActivityViewController (BCDDiagnostics)
- (instancetype)bcd_initWithActivityItems:(NSArray *)items applicationActivities:(NSArray<UIActivity *> *)activities;
@end
@implementation UIActivityViewController (BCDDiagnostics)
- (instancetype)bcd_initWithActivityItems:(NSArray *)items applicationActivities:(NSArray<UIActivity *> *)activities {
    NSMutableArray *logs=NSMutableArray.new;
    for (id item in items) if ([item isKindOfClass:NSURL.class] && logURL(item)) [logs addObject:item];
    if (logs.count) {
        BCDCopyDiagnosticActivity *copy=BCDCopyDiagnosticActivity.new; copy.logs=logs;
        activities=[(activities ?: @[]) arrayByAddingObject:copy];
    }
    return [self bcd_initWithActivityItems:items applicationActivities:activities];
}
@end
void BCDInstallDiagnosticsUI(void) {
    static dispatch_once_t once;
    dispatch_once(&once,^{
        Method original=class_getInstanceMethod(UIActivityViewController.class,@selector(initWithActivityItems:applicationActivities:));
        Method replacement=class_getInstanceMethod(UIActivityViewController.class,@selector(bcd_initWithActivityItems:applicationActivities:));
        if (original && replacement) method_exchangeImplementations(original,replacement);
    });
}
#else
void BCDInstallDiagnosticsUI(void) {}
#endif
