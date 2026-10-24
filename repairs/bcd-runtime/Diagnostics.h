#import <Foundation/Foundation.h>
void BCDDiagnosticsBegin(const char *executable);
void BCDDiagnosticsState(NSString *state, NSDictionary *details);
NSString *BCDDiagnosticReport(NSURL *documents, NSURL *bundle, NSDictionary *session, NSArray<NSURL *> *logs);
NSString *BCDScrubDiagnostic(NSString *text);
NSDictionary *BCDSDKImports(NSURL *url);
NSURL *BCDDiagnosticDocuments(void);
NSString *BCDCreateCurrentDiagnosticReport(NSArray<NSURL *> *exportedLogs);
void BCDInstallDiagnosticsUI(void);
