#import "Diagnostics.h"
#include <assert.h>
#include <stdint.h>
#include <unistd.h>
int main(void) {@autoreleasepool {
    ssize_t (*emit)(int,const void *,size_t)=BCDJournalWriteHook(write);
    BCDJournalBegin();
    uint8_t image[1024]={0};
    uint32_t *throwinfo=(void *)(image+32);throwinfo[3]=64;
    uint32_t *array=(void *)(image+64);array[0]=1;array[1]=96;
    uint32_t *type=(void *)(image+96);type[1]=128;
    strcpy((char *)image+144,".?AVruntime_error@std@@");
    const char *message="fixture failure detail";uint64_t object[3]={0,(uintptr_t)message,0};
    NSString *line=[NSString stringWithFormat:@"0024:trace:seh:raise code=e06d7363\n info[0]=19930520\n info[1]=%llx\n info[2]=%llx\n info[3]=%llx\n",(unsigned long long)(uintptr_t)object,(unsigned long long)(uintptr_t)throwinfo,(unsigned long long)(uintptr_t)image];
    NSData *d=[line dataUsingEncoding:NSUTF8StringEncoding];
    // Deliberately split records across writes.
    emit(2,d.bytes,19);emit(2,(char *)d.bytes+19,d.length-19);
    NSString *path=[BCDDiagnosticDocuments().path stringByAppendingPathComponent:@"BCD-Diagnostics/failure-journal.txt"];
    NSString *text=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    assert([text containsString:@"type=.?AVruntime_error@std@@"]);
    assert([text containsString:@"message=fixture failure detail"]);
    const char *invalid="0024:trace:seh:raise code=e06d7363\n info[0]=19930520\n info[1]=1\n info[2]=1\n info[3]=1\n";
    emit(2,invalid,strlen(invalid));
    text=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    assert([text containsString:@"type=unavailable message=unavailable"]);
    puts("Journal split-write, MSVC RTTI/message, inaccessible memory tests passed");
}return 0;}
