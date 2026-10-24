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
- (UIActivityType)activityType { return @"com.thebcd69.bcd.copy-chatgpt-report.v5"; }
- (NSString *)activityTitle { return @"Copy report for ChatGPT"; }
- (UIImage *)activityImage { return [UIImage systemImageNamed:@"doc.on.clipboard"]; }
- (BOOL)canPerformWithActivityItems:(NSArray *)items { return self.logs.count>0; }
- (void)performActivity {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        NSString *report=BCDCreateCurrentDiagnosticReport(self.logs);
        dispatch_async(dispatch_get_main_queue(),^{ UIPasteboard.generalPasteboard.string=report; [self activityDidFinish:YES]; });
    });
}
@end
@interface BCDShareChatGPTActivity : BCDCopyDiagnosticActivity
@end
@implementation BCDShareChatGPTActivity
- (UIActivityType)activityType { return @"com.thebcd69.bcd.share-chatgpt-report.v5"; }
- (NSString *)activityTitle { return @"Share report for ChatGPT (.txt)"; }
- (UIImage *)activityImage { return [UIImage systemImageNamed:@"doc.text"]; }
- (void)performActivity {
    NSArray *logs=self.logs;
    [self activityDidFinish:YES];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        NSString *report=BCDCreateCurrentDiagnosticReport(logs);
        NSURL *dir=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *file=[dir URLByAppendingPathComponent:@"BCD-ChatGPT-report.txt"];
        BOOL saved=[report writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,500*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
            for(UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if(![scene isKindOfClass:UIWindowScene.class] || scene.activationState!=UISceneActivationStateForegroundActive)continue;
                for(UIWindow *window in ((UIWindowScene *)scene).windows) {
                    if(!window.isKeyWindow)continue;
                    UIViewController *view=window.rootViewController;
                    while(view.presentedViewController)view=view.presentedViewController;
                    UIActivityViewController *share=[[UIActivityViewController alloc]initWithActivityItems:saved ? @[file] : @[report] applicationActivities:nil];
                    share.popoverPresentationController.sourceView=view.view;
                    share.popoverPresentationController.sourceRect=CGRectMake(CGRectGetMidX(view.view.bounds),CGRectGetMidY(view.view.bounds),1,1);
                    [view presentViewController:share animated:YES completion:nil];return;
                }
            }
        });
    });
}
@end
@interface UIViewController (BCDChatGPTCrash)
- (void)bcd_presentViewController:(UIViewController *)view animated:(BOOL)animated completion:(void (^)(void))completion;
@end
@implementation UIViewController (BCDChatGPTCrash)
- (void)bcd_presentViewController:(UIViewController *)view animated:(BOOL)animated completion:(void (^)(void))completion {
    if([view isKindOfClass:UIAlertController.class]) {
        UIAlertController *alert=(id)view;
        NSString *text=[[NSString stringWithFormat:@"%@ %@",alert.title ?: @"",alert.message ?: @""] lowercaseString];
        if(([text containsString:@"crashed"] || [text containsString:@"wine could not start"]) && alert.preferredStyle==UIAlertControllerStyleAlert) {
            BOOL existing=NO;for(UIAlertAction *a in alert.actions)if([a.title containsString:@"ChatGPT"])existing=YES;
            if(!existing)[alert addAction:[UIAlertAction actionWithTitle:@"Copy report for ChatGPT" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
                    NSString *report=BCDCreateCurrentDiagnosticReport(nil);
                    dispatch_async(dispatch_get_main_queue(),^{UIPasteboard.generalPasteboard.string=report;});
                });
            }]];
        }
    }
    [self bcd_presentViewController:view animated:animated completion:completion];
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
        BCDShareChatGPTActivity *share=BCDShareChatGPTActivity.new;share.logs=logs;
        activities=[(activities ?: @[]) arrayByAddingObjectsFromArray:@[copy,share]];
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
        Method present=class_getInstanceMethod(UIViewController.class,@selector(presentViewController:animated:completion:));
        Method patched=class_getInstanceMethod(UIViewController.class,@selector(bcd_presentViewController:animated:completion:));
        if(present && patched)method_exchangeImplementations(present,patched);
    });
}
#else
void BCDInstallDiagnosticsUI(void) {}
#endif
