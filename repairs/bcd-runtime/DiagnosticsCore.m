#import "Diagnostics.h"
#include "PEImports.h"
#include <CommonCrypto/CommonDigest.h>
#include <sys/sysctl.h>

static NSMutableDictionary *activeSession;
static NSString *const marker = @"[BCD-Diagnostics] session=";
static NSURL *sessionURL(void) { return [BCDDiagnosticDocuments() URLByAppendingPathComponent:@"BCD-Diagnostics/session.json"]; }
NSURL *BCDDiagnosticDocuments(void) {
    return [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
}
static void saveSession(void) {
    NSURL *url=sessionURL(); if (!url) return;
    [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *data=[NSJSONSerialization dataWithJSONObject:activeSession options:NSJSONWritingSortedKeys error:nil];
    [data writeToURL:url options:NSDataWritingAtomic error:nil];
}
void BCDDiagnosticsBegin(const char *executable) {
    @synchronized(NSProcessInfo.class) {
        NSString *exe=executable ? [NSString stringWithUTF8String:executable] : @"";
        activeSession=[@{@"id":NSUUID.UUID.UUIDString, @"started":[NSISO8601DateFormatter.new stringFromDate:NSDate.date],
            @"executable":exe ?: @"", @"phase":@"server_wait", @"repair":@5} mutableCopy];
        NSMutableDictionary *settings=NSMutableDictionary.new;
        for(NSString *key in @[@"MADEIRA_CFG_GAME",@"MADEIRA_OPTIN_DLLS",@"MADEIRA_CAGE_RELEASE",@"MADEIRA_EXE",@"WINEDEBUG",@"MADEIRA_FEX_AVX",@"MADEIRA_PAD_MODE",@"MADEIRA_THREAD_STACK_SPILL",@"MADEIRA_JIT_NO_DEBUGGER_POOL"]) {
            const char *value=getenv(key.UTF8String);if(value)settings[key]=[NSString stringWithUTF8String:value] ?: @"unreadable";
        }
        const char *cfg=getenv("MADEIRA_CFG_GAME");
        if(cfg) {
            NSString *config=[NSString stringWithContentsOfFile:[NSString stringWithUTF8String:cfg] encoding:NSUTF8StringEncoding error:nil];
            NSMutableArray *safe=NSMutableArray.new;
            for(NSString *line in [config componentsSeparatedByString:@"\n"]) {
                NSString *trim=[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                for(NSString *key in @[@"dxil-tess",@"sampler-reduction",@"ind-count",@"typed-view-align",@"typed-view-shadow",@"view-census",@"swap-mb",@"env.MADEIRA_CAGE_RELEASE",@"env.MADEIRA_OPTIN_DLLS",@"env.MADEIRA_THREAD_STACK_SPILL",@"env.MADEIRA_PAD_MODE"]) {
                    NSRange eq=[trim rangeOfString:@"="];
                    if(eq.location!=NSNotFound && [[[trim substringToIndex:eq.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] isEqualToString:key]) {[safe addObject:trim];break;}
                }
            }
            settings[@"game_config"]=[safe componentsJoinedByString:@"\n"];
        }
        activeSession[@"launch_settings"]=settings;
        activeSession[@"physical_memory_bytes"]=@(NSProcessInfo.processInfo.physicalMemory);
        activeSession[@"low_power"]=@(NSProcessInfo.processInfo.lowPowerModeEnabled);
        activeSession[@"thermal_state"]=@(NSProcessInfo.processInfo.thermalState);
        saveSession();
        fprintf(stderr,"%s%s\n",marker.UTF8String,[activeSession[@"id"] UTF8String]);
    }
}
void BCDDiagnosticsState(NSString *state, NSDictionary *details) {
    @synchronized(NSProcessInfo.class) {
        if (!activeSession) return;
        activeSession[@"phase"]=state;
        if (details) [activeSession addEntriesFromDictionary:details];
        saveSession();
    }
}
static NSString *replace(NSString *text,NSString *pattern,NSString *replacement) {
    NSRegularExpression *re=[NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
    return [re stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0,text.length) withTemplate:replacement];
}
NSString *BCDScrubDiagnostic(NSString *text) {
    text=replace(text,@"(?i)(authorization|access[_-]?token|refresh[_-]?token|password|cookie|pairing[_-]?record)\\s*[:=]\\s*[^\\r\\n]+",@"$1=[redacted]");
    text=replace(text,@"[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}",@"[email]");
    text=replace(text,@"\\b(?:[0-9]{1,3}\\.){3}[0-9]{1,3}\\b",@"[ip]");
    text=replace(text,@"(?i)(?:[0-9a-f]{1,4}:){3,}[0-9a-f:]+",@"[ip6]");
    text=replace(text,@"(?i)(?:/private)?/var/mobile/Containers/(?:Data|Bundle)/[^\\r\\n\\\"']+",@"[app-container-path]");
    text=replace(text,@"(?i)/(?:Users|home)/[^/\\s]+",@"/[user]");
    text=replace(text,@"(?i)C:\\\\users\\\\[^\\\\\\s]+",@"C:\\\\users\\\\[user]");
    text=replace(text,@"(?i)https?://[^\\s\\\"']+",@"[url]");
    return text;
}
static void imported(const char *dll,const char *function,int delayed,void *context) {
    NSMutableDictionary *rows=(__bridge NSMutableDictionary *)context;
    NSString *library=[[NSString stringWithUTF8String:dll] lowercaseString];
    NSString *key=delayed ? [library stringByAppendingString:@" (delay)"] : library;
    NSMutableArray *functions=rows[key]; if (!functions) rows[key]=functions=NSMutableArray.new;
    [functions addObject:[NSString stringWithUTF8String:function]];
}
NSDictionary *BCDSDKImports(NSURL *url) {
    NSNumber *size=nil; [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    if (!size || size.unsignedLongLongValue>128*1024*1024) return @{@"status":@"SDK file unavailable or larger than scan limit"};
    NSData *data=[NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
    if (!data) return @{@"status":@"SDK file unreadable"};
    NSMutableDictionary *rows=NSMutableDictionary.new;
    int n=bcd_pe_imports(data.bytes,data.length,imported,(__bridge void *)rows);
    if (n<0) return @{@"status":@"SDK PE import table invalid or unsupported"};
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString *hash=NSMutableString.new; for (unsigned i=0;i<sizeof(digest);i++) [hash appendFormat:@"%02x",digest[i]];
    return @{@"status":@"scanned",@"sha256":hash,@"imports":rows,@"count":@(n)};
}
static NSURL *findChild(NSURL *parent,NSString *name) {
    for (NSURL *url in [NSFileManager.defaultManager contentsOfDirectoryAtURL:parent includingPropertiesForKeys:nil options:0 error:nil])
        if ([url.lastPathComponent caseInsensitiveCompare:name]==NSOrderedSame) return url;
    return nil;
}
static NSURL *sdkURL(NSURL *documents,NSString *executable) {
    NSString *path=[executable stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    if (![path.lowercaseString hasPrefix:@"c:/"]) return nil;
    NSURL *root=[documents URLByAppendingPathComponent:@"wine/drive_c" isDirectory:YES];
    NSURL *folder=root;
    NSArray *parts=[[path substringFromIndex:3] pathComponents];
    for (NSString *part in [parts subarrayWithRange:NSMakeRange(0,parts.count ? parts.count-1 : 0)]) {
        if ([part isEqualToString:@".."] || [part isEqualToString:@"."] || [part isEqualToString:@"/"]) return nil;
        folder=findChild(folder,part); if (!folder) return nil;
    }
    NSURL *sdk=findChild(folder,@"PsPcSdk.dll");
    NSString *safeRoot=[root.URLByResolvingSymlinksInPath.path stringByAppendingString:@"/"];
    return [sdk.URLByResolvingSymlinksInPath.path hasPrefix:safeRoot] ? sdk : nil;
}
/* Stream the full log. Keep launch markers, failure evidence and a short tail;
 * shader/telemetry volume cannot push a crash out of a 2 MB tail window. */
static NSString *tail(NSURL *url) {
    NSInputStream *stream=[NSInputStream inputStreamWithURL:url];[stream open];
    NSMutableString *partial=NSMutableString.new;
    NSMutableArray *events=NSMutableArray.new,*recent=NSMutableArray.new;
    NSString *lastMarker=nil;
    uint8_t buffer[65536]; NSInteger n; NSUInteger total=0;
    while((n=[stream read:buffer maxLength:sizeof(buffer)])>0) {
        total+=(NSUInteger)n;
        NSString *chunk=[[NSString alloc]initWithBytes:buffer length:n encoding:NSISOLatin1StringEncoding];
        [partial appendString:chunk ?: @""];
        NSRange end;
        while((end=[partial rangeOfString:@"\n"]).location!=NSNotFound) {
            NSString *line=[partial substringToIndex:end.location];
            [partial deleteCharactersInRange:NSMakeRange(0,end.location+1)];
            if([line containsString:marker]) {lastMarker=line;[events removeAllObjects];[recent removeAllObjects];}
            NSString *low=line.lowercaseString;
            NSArray *keys=@[@"[bcd-",@"fatal:",@"[exc]",@"[exc-disp]",@"info[",@"[fast-fail]",@"[term-stack]",@"[unwind] term",@"[exit-report]",@"[cage]",@"gaps-exhausted",@"unhandled",@"not found",@"unimplemented function",@"unimplemented stub",@"[lc-winesocket]",@"[autotune]",@"[win-name]",@"[init-peb]",@"[device]",@"[game-cfg]",@"[madeira-env]",@"[jit-pool]",@"[display-shape]",@"[launch-route]",@"[wineproc] target",@"[pool-rot]",@"[footprint]",@"[madeira-d3d12] unimplemented"];
            BOOL keep=NO;for(NSString *key in keys)if([low containsString:key]){keep=YES;break;}
            if(keep){[events addObject:line];if(events.count>250)[events removeObjectAtIndex:0];}
            [recent addObject:line];if(recent.count>15)[recent removeObjectAtIndex:0];
        }
        if(partial.length>16384)[partial deleteCharactersInRange:NSMakeRange(0,partial.length-8192)];
        if(total>256*1024*1024){[events addObject:@"[scan limit reached: 256 MB; use failure journal]"];break;}
    }
    [stream close];
    if(partial.length)[recent addObject:partial];
    if(lastMarker)[events insertObject:lastMarker atIndex:0];
    [events addObjectsFromArray:recent];return [events componentsJoinedByString:@"\n"];
}
NSString *BCDDiagnosticReport(NSURL *documents,NSURL *bundle,NSDictionary *session,NSArray<NSURL *> *logs) {
    if(logs.count>1) {
        NSString *wanted=session[@"id"] ? [marker stringByAppendingString:session[@"id"]] : nil;
        NSMutableArray *isolated=NSMutableArray.new;
        if(wanted)for(NSURL *url in logs)if([tail(url) containsString:wanted])[isolated addObject:url];
        logs=isolated.count ? isolated : @[logs.firstObject];
    }
    NSMutableString *report=[NSMutableString stringWithString:@"BCD diagnostic report v5 — ChatGPT\n"];
    NSString *exe=session[@"executable"] ?: @"";
    NSString *target=[[exe stringByReplacingOccurrencesOfString:@"\\" withString:@"/"] lastPathComponent];
    char machine[128]={0}; size_t len=sizeof(machine); sysctlbyname("hw.machine",machine,&len,NULL,0);
    [report appendFormat:@"Build: 0.1.580; repair: 5\nDevice: %s; %@\nLast launch: %@\nTarget: %@\nSession: %@\nStartup phase: %@\n",machine,NSProcessInfo.processInfo.operatingSystemVersionString,session[@"started"] ?: @"unknown",target.length ? target : @"unknown",session[@"id"] ?: @"unknown",session[@"phase"] ?: @"no recorded launch"];
    [report appendString:@"Purpose: diagnose this single launch. Observations below are evidence, not a confirmed root cause. No automatic upload.\n"];
    [report appendFormat:@"Launch device state: RAM=%@ bytes; low_power=%@; thermal=%@ (0 nominal, 1 fair, 2 serious, 3 critical)\n",session[@"physical_memory_bytes"] ?: @"unrecorded",session[@"low_power"] ?: @"unrecorded",session[@"thermal_state"] ?: @"unrecorded"];
    NSDictionary *settings=session[@"launch_settings"];
    [report appendString:@"\nRecorded launch configuration (allowlisted):\n"];
    if(!settings.count)[report appendString:@"Not recorded by this diagnostic version.\n"];
    for(NSString *key in [settings.allKeys sortedArrayUsingSelector:@selector(compare:)])[report appendFormat:@"%@: %@\n",key,settings[key]];
    if (session[@"reason"]) [report appendFormat:@"Startup detail: %@\n",session[@"reason"]];
    [report appendString:@"\nFailure summary (observed records, newest per category):\n"];
    NSMutableDictionary *summary=NSMutableDictionary.new;
    for(NSURL *source in logs) {
        NSString *sample=tail(source);
        for(NSString *line in [sample componentsSeparatedByString:@"\n"]) {
            NSString *key=nil;
            if([line containsString:@"[exit-report]"])key=@"Game exit";
            else if([line containsString:@"[fast-fail]"])key=@"Last terminal exception";
            else if([line containsString:@"[cage]"])key=@"Address reservation";
            else if([line containsString:@"server VERIFIED"])key=@"Wine startup";
            else if([line containsString:@"[BCD-CppException]"])key=@"Decoded C++ exception";
            if(key && !summary[key])summary[key]=line; // supplied sources are newest first
            else if(key && source==logs.firstObject)summary[key]=line;
        }
    }
    for(NSString *key in @[@"Game exit",@"Last terminal exception",@"Decoded C++ exception",@"Wine startup",@"Address reservation"])
        [report appendFormat:@"%@: %@\n",key,summary[key] ?: @"not captured (not proof of success)"];
    [report appendString:@"Bundled Wine modules:\n"];
    for (NSString *module in @[@"ntdsapi.dll",@"tbs-optin.dll",@"evr-optin.dll",@"dxva2-optin.dll"]) {
        BOOL present=[NSFileManager.defaultManager isReadableFileAtPath:[[bundle URLByAppendingPathComponent:@"arm64ec-windows"] URLByAppendingPathComponent:module].path];
        [report appendFormat:@"  %@: %@\n",module,present ? @"present (not proof of initialization)" : @"missing"];
    }
    NSURL *sdk=sdkURL(documents,exe);
    NSDictionary *scan=sdk ? BCDSDKImports(sdk) : @{@"status":@"PsPcSdk.dll not found beside the recorded game executable"};
    [report appendFormat:@"SDK scan: %@\n",scan[@"status"]];
    if (scan[@"sha256"]) {
        NSDictionary *imports=scan[@"imports"];
        [report appendFormat:@"SDK SHA256: %@\nImport entries: %@\n",scan[@"sha256"],scan[@"count"]];
        for (NSString *library in [imports.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            BOOL detail=[@[@"ntdsapi.dll",@"tbs.dll"] containsObject:library];
            [report appendFormat:@"  %@%@\n",library,detail ? [@": " stringByAppendingString:[imports[library] componentsJoinedByString:@", "]] : @""];
        }
        [report appendString:@"Known support gaps in the bundled Wine source (imports alone do not prove calls): DsGetSpnA returns ERROR_CALL_NOT_IMPLEMENTED; DsFreeSpnArrayA is a generated stub. TBS has no TPM backend: Tbsi_Context_Create/Tbsi_GetDeviceInfo return TBS_E_TPM_NOT_FOUND; Tbsi_Get_TCG_Log/Tbsip_Context_Close are generated stubs.\n"];
    }
    NSURL *journal=[documents URLByAppendingPathComponent:@"BCD-Diagnostics/failure-journal.txt"];
    NSString *journalText=[NSString stringWithContentsOfURL:journal encoding:NSUTF8StringEncoding error:nil];
    if(journalText.length) {
        [report appendString:@"\nPreserved exception journal (game and child process IDs are separate):\n"];
        NSArray *journalLines=[journalText componentsSeparatedByString:@"\n"];
        BOOL decoded=NO;
        for(NSString *line in journalLines)if([line containsString:@"[BCD-CppException]"]){[report appendFormat:@"%@\n",line];decoded=YES;}
        if(!decoded)[report appendString:@"Exception type/message capture: no decoded record. Capture may be incomplete; this does not establish SDK success.\n"];
    }
    [report appendString:@"\nObserved log evidence (bounded; no automatic upload):\n"];
    NSString *sessionMarker=session[@"id"] ? [marker stringByAppendingString:session[@"id"]] : nil;
    NSMutableArray *matching=NSMutableArray.new;
    if (sessionMarker) for (NSURL *url in logs) if ([tail(url) containsString:sessionMarker]) [matching addObject:url];
    if (matching.count) logs=matching;
    else if (logs.count>1) logs=@[logs.firstObject];
    if(journalText.length) logs=[logs arrayByAddingObject:journal];
    else [report appendString:@"Failure journal: unavailable. Raw-log fallback used; capture completeness is limited.\n"];
    unsigned used=0;
    for (NSURL *url in logs) {
        if (used++>=3) break;
        NSString *text=tail(url); if (!text.length) continue;
        NSString *expected=session[@"id"] ? [marker stringByAppendingString:session[@"id"]] : nil;
        NSRange found=expected ? [text rangeOfString:expected options:NSBackwardsSearch] : NSMakeRange(NSNotFound,0);
        BOOL matched=found.location!=NSNotFound;
        if (matched) text=[text substringFromIndex:found.location];
        else {
            NSRange launch=[text rangeOfString:@"[bcd-ui] play local" options:NSBackwardsSearch];
            if (launch.location!=NSNotFound) text=[text substringFromIndex:launch.location];
        }
        [report appendFormat:@"-- %@; %@ --\n",url.lastPathComponent,matched ? @"matches recorded session" : @"session not verified; last launch/tail only"];
        NSArray *lines=[text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
        NSMutableOrderedSet *evidence=NSMutableOrderedSet.new;
        for (NSUInteger i=0;i<lines.count;i++) {
            NSString *line=lines[i]; NSString *low=line.lowercaseString;
            BOOL relevant=[low containsString:@"[device]"] || [low containsString:@"[game-cfg]"] || [low containsString:@"[madeira-env]"] || [low containsString:@"[jit-pool]"] || [low containsString:@"[pool-rot]"] || [low containsString:@"[display-shape]"] || [low containsString:@"[exc]"] || [low containsString:@"info["] || [low containsString:@"[exc-disp]"] || [low containsString:@"[fast-fail]"] || [low containsString:@"[term-stack]"] || [low containsString:@"[unwind] term"] || [low containsString:@"[exit-report]"] || [low containsString:@"[cage]"] || [low containsString:@"[bcd-cppexception]"] || [low containsString:@"[dll-missing]"] || [low containsString:@"err:module:import_dll"] || [low containsString:@"unimplemented function"] || [low containsString:@"unimplemented stub"] || [low containsString:@"fatal:"] || [low containsString:@"unhandled exception"] || [low containsString:@"[bcd-winestartup]"] || [low containsString:@"[bcd-diagnostics]"] || ([low containsString:@"[win-name]"] && ([low containsString:@"sdk"] || [low containsString:@"error"])) || ([low containsString:@"[lc-winesocket]"] && ([low containsString:@"retry"] || [low containsString:@"errno=1"]));
            if (relevant) { if (evidence.count>=90) [evidence removeObjectAtIndex:0]; [evidence addObject:line]; }
        }
        if (!evidence.count) [report appendString:@"No selected loader/SDK/fatal line in this log window.\n"];
        for (NSString *line in evidence) [report appendFormat:@"%@\n",line.length>500 ? [line substringToIndex:500] : line];
        [report appendString:@"Recent tail:\n"];
        for (NSUInteger i=lines.count>30 ? lines.count-30 : 0;i<lines.count;i++) {
            NSString *line=lines[i]; if (line.length) [report appendFormat:@"%@\n",line.length>800 ? [line substringToIndex:800] : line];
        }
    }
    if (!logs.count) [report appendString:@"No log files available. Reproduce the error, then export BCD's log.\n"];
    [report appendString:@"\nInterpretation: a C++ throw can be handled normally. Correlate its process/thread and stack with the final fast-fail. 0xc0000409 alone does not identify the root cause. Unavailable type/message means capture was incomplete, not SDK success.\n"];
    [report appendString:@"\nAnalysis handoff: identify the final failing process first; separate handled exceptions from terminal errors; compare the effective config with observed allocation/loader failures; state what is proven and what remains unknown before suggesting a change.\n"];
    report=[BCDScrubDiagnostic(report) mutableCopy];
    // Bound pasted text by UTF-8 bytes, preserving the report prefix and evidence.
    while ([report lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>23900 && report.length>100) [report deleteCharactersInRange:NSMakeRange(report.length-100,100)];
    [report appendString:@"\nEnd diagnostic report. Presence/imports do not prove SDK or game compatibility.\n"];
    return report;
}
NSString *BCDCreateCurrentDiagnosticReport(NSArray<NSURL *> *exportedLogs) {
    NSURL *docs=BCDDiagnosticDocuments();
    NSDictionary *session=nil;
    @synchronized(NSProcessInfo.class) { session=[activeSession copy]; }
    if (!session) {
        NSData *data=[NSData dataWithContentsOfURL:sessionURL()];
        if (data) { id json=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]; if ([json isKindOfClass:NSDictionary.class]) session=json; }
    }
    NSMutableArray *logs=[exportedLogs mutableCopy] ?: NSMutableArray.new;
    if (!logs.count) for (NSString *name in @[@"bcd-log.txt",@"bcd-log.prev.txt"]) {
        NSURL *url=[docs URLByAppendingPathComponent:name]; if ([NSFileManager.defaultManager fileExistsAtPath:url.path]) [logs addObject:url];
    }
    return BCDDiagnosticReport(docs,NSBundle.mainBundle.bundleURL,session ?: @{},logs);
}
