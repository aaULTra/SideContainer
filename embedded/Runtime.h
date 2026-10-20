#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
BOOL SIEmbeddedIsLiveProcess(void);
NSString * _Nullable SIEmbeddedHostTeam(void);
NSBundle * _Nullable SIEmbeddedHostBundle(void);
NSString * _Nullable SIEmbeddedEntitlementsAtPath(NSString *path);
void SIEmbeddedReturnToHost(void);
NSString * _Nullable SIEmbeddedActivateCertificate(NSData *certificate, NSString *password);
void SIEmbeddedTestSigning(void (^completion)(BOOL valid, NSString * _Nullable error));
NS_ASSUME_NONNULL_END
