/* Observe native log writes only. Never call guest functions, alter exception
 * handling, or dereference guest addresses without a checked Mach read. */
#import "Diagnostics.h"
#include <mach/mach.h>

#include <pthread.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>
static int journal=-1;
static size_t journal_bytes;
static pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER;
static __thread int observing;
static __thread char pending[8192];
static __thread size_t pending_n;
static __thread uint64_t parameters[4];
static __thread unsigned mask;
static __thread int cpp;
static ssize_t (*real_write)(int,const void *,size_t);
static int read_guest(uint64_t address,void *out,size_t size) {
    vm_size_t got=0;
    if (address<0x10000 || address>UINT64_MAX-size) return 0;
    return vm_read_overwrite(mach_task_self(),address,size,(vm_address_t)out,&got)==KERN_SUCCESS && got==size;
}
static void guest_string(uint64_t address,char *out,size_t cap) {
    size_t n=0; for (;n+1<cap;n++) {
        unsigned char c; if (!read_guest(address+n,&c,1)) break;
        if (!c) break; if (c<32 || c>126) break; out[n]=c;
    } out[n]=0;
}
static void retain_line(const char *line) {
    pthread_mutex_lock(&lock);
    size_t n=strnlen(line,8191);
    if (journal>=0 && journal_bytes+n+1>=1024*1024) {
        ftruncate(journal,0);lseek(journal,0,SEEK_SET);journal_bytes=0;
    }
    if (journal>=0) {
        ssize_t a=real_write(journal,line,n),b=real_write(journal,"\n",1);
        if(a>0)journal_bytes+=(size_t)a; if(b>0)journal_bytes+=(size_t)b;
    }
    pthread_mutex_unlock(&lock);
}
static void decode_cpp(void) {
    uint32_t info[4],array[2],type[2];
    char name[256]={0},message[512]={0},result[1200];
    uint64_t base=parameters[3],object=parameters[1],throwinfo=parameters[2];
    if (read_guest(throwinfo,info,sizeof(info)) && info[3] &&
        read_guest(base+info[3],array,sizeof(array)) && array[0]>0 && array[0]<128 &&
        read_guest(base+array[1],type,sizeof(type)))
        guest_string(base+type[1]+16,name,sizeof(name));
    /* MSVC std::exception stores a message pointer after its vtable. Read it
     * only for recognised exception RTTI; never invoke what() across ABIs. */
    if (strstr(name,"exception") || strstr(name,"runtime_error") || strstr(name,"logic_error") || strstr(name,"bad_alloc")) {
        uint64_t pointer=0; if(read_guest(object+8,&pointer,sizeof(pointer)))guest_string(pointer,message,sizeof(message));
    }
    snprintf(result,sizeof(result),"[BCD-CppException] type=%s message=%s object=0x%llx throwinfo=0x%llx image=0x%llx (bounded memory observation; no guest calls)",
        name[0]?name:"unavailable",message[0]?message:"unavailable",(unsigned long long)object,(unsigned long long)throwinfo,(unsigned long long)base);
    retain_line(result);
}
static void observe_line(char *line) {
    if (strstr(line,"code=")) {
        cpp=strstr(line,"e06d7363")!=NULL; mask=0;
    }
    if (cpp) {
        char *p=strstr(line,"info["); unsigned index; unsigned long long value;
        if(p && sscanf(p,"info[%u]=%llx",&index,&value)==2 && index<4) {
            parameters[index]=value;mask|=1u<<index;
            if(mask==15){decode_cpp();cpp=0;}
        }
    }
    const char *keys[]={"[exc]","code=","info[","[exc-disp]","[fast-fail]","[term-stack]","[unwind] term","[exit-report]","[cage]","[autotune]","[BCD-","[dll-missing]","not found","UNHANDLED","gaps-exhausted","throw","what():","[init-peb]","[WineProc] Target",NULL};
    for(int i=0;keys[i];i++)if(strstr(line,keys[i])){retain_line(line);break;}
}
static ssize_t observed_write(int fd,const void *bytes,size_t count) {
    ssize_t result=real_write(fd,bytes,count);
    int saved_errno=errno;
    if(observing || fd!=STDERR_FILENO || result<=0)return result;
    observing=1;
    const char *p=bytes;
    for(size_t i=0;i<(size_t)result;i++) {
        if(p[i]=='\n' || pending_n==sizeof(pending)-1) {
            pending[pending_n]=0;observe_line(pending);pending_n=0;
        }
        if(p[i]!='\n')pending[pending_n++]=p[i];
    }
    observing=0;errno=saved_errno;return result;
}
void *BCDJournalWriteHook(void *original) { real_write=original;return observed_write; }
void BCDJournalBegin(void) {
    pthread_mutex_lock(&lock);
    if(journal>=0)close(journal);
    NSString *dir=[BCDDiagnosticDocuments().path stringByAppendingPathComponent:@"BCD-Diagnostics"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path=[dir stringByAppendingPathComponent:@"failure-journal.txt"];
    NSString *prior=[dir stringByAppendingPathComponent:@"previous-failure-journal.txt"];
    [NSFileManager.defaultManager removeItemAtPath:prior error:nil];
    [NSFileManager.defaultManager moveItemAtPath:path toPath:prior error:nil];
    journal=open(path.fileSystemRepresentation,O_CREAT|O_TRUNC|O_WRONLY,0600);journal_bytes=0;
    pthread_mutex_unlock(&lock);
}
