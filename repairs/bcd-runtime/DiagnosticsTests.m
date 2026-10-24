#import "Diagnostics.h"
#include <assert.h>
int main(void) { @autoreleasepool {
    NSURL *root=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    NSFileManager *fm=NSFileManager.defaultManager;
    NSURL *game=[root URLByAppendingPathComponent:@"wine/drive_c/Ghost Game" isDirectory:YES];
    assert([fm createDirectoryAtURL:game withIntermediateDirectories:YES attributes:nil error:nil]);
    NSURL *sdk=[game URLByAppendingPathComponent:@"PsPcSdk.dll"];
    assert([fm copyItemAtURL:[NSURL fileURLWithPath:@"runtime-test/synthetic-sdk.dll"] toURL:sdk error:nil]);
    NSDictionary *scan=BCDSDKImports(sdk);
    assert([scan[@"count"] intValue]==3 && [scan[@"sha256"] length]==64);
    assert([scan[@"imports"][@"ntdsapi.dll"] containsObject:@"DsGetSpnA"]);
    NSURL *old=[root URLByAppendingPathComponent:@"old.txt"], *log=[root URLByAppendingPathComponent:@"log.txt"];
    [@"[BCD-Diagnostics] session=old\nFATAL: stale failure\n" writeToURL:old atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"FATAL: prior session failure\n[BCD-Diagnostics] session=test-1\n[BCD-WineStartup] server VERIFIED ready\nerr:module:import_dll Library tbs.dll not found\n[win-name] text=PlayStation PC SDK Runtime is missing\nunimplemented function tbs.Tbsi_Get_TCG_Log\nemail=user@example.com host=10.7.1.1\nAuthorization: Bearer secret-token\n/private/var/mobile/Containers/Data/Application/PRIVATE/Documents/wine\n" writeToURL:log atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSDictionary *session=@{@"id":@"test-1",@"executable":@"C:\\gHOST gAME\\GhostOfTsushima.exe",@"phase":@"server_ready_client_socket_created"};
    NSString *report=BCDDiagnosticReport(root,root,session,@[old,log]);
    assert([report containsString:@"Library tbs.dll not found"]);
    assert([report containsString:@"PlayStation PC SDK Runtime is missing"]);
    assert([report containsString:@"unimplemented function tbs.Tbsi_Get_TCG_Log"]);
    assert([report containsString:@"SDK scan: scanned"] && [report containsString:@"matches recorded session"]);
    assert(![report containsString:@"prior session failure"] && ![report containsString:@"stale failure"]);
    assert(![report containsString:@"user@example.com"] && ![report containsString:@"10.7.1.1"] && ![report containsString:@"secret-token"] && ![report containsString:@"/PRIVATE/"]);
    NSString *scrub=BCDScrubDiagnostic(@"[22:31:42.808] path=C:\\users\\Aaqib\\test email=x@y.com ip=fd00:1:2:3::4");
    assert([scrub containsString:@"22:31:42.808"] && ![scrub containsString:@"Aaqib"] && ![scrub containsString:@"fd00"]);
    NSMutableString *huge=NSMutableString.new;for(int i=0;i<3000;i++)[huge appendFormat:@"FATAL: %d %@\n",i,[@"x" stringByPaddingToLength:1000 withString:@"x" startingAtIndex:0]];
    [huge writeToURL:log atomically:YES encoding:NSUTF8StringEncoding error:nil];
    report=BCDDiagnosticReport(root,root,session,@[log]);assert([report lengthOfBytesUsingEncoding:NSUTF8StringEncoding]<=24000);
    NSDictionary *escape=@{@"executable":@"C:\\..\\Ghost Game\\GhostOfTsushima.exe"};
    assert([BCDDiagnosticReport(root,root,escape,@[]) containsString:@"SDK scan: PsPcSdk.dll not found"]);
    [fm removeItemAtURL:root error:nil];puts("Diagnostic SDK scan, session isolation, redaction, path traversal and report size tests passed");
} return 0; }
