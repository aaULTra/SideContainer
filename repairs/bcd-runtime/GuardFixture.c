/* Native dyld integration test: no Wine, iOS or game execution is claimed. */
#include <assert.h>
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static _Atomic int running=0, ready=0;
__attribute__((used)) static const char readiness_log[]="[launch] wineserver ready after %.0f ms";
int wineserver_is_running(void) { return atomic_load(&running); }
int wineserver_is_ready(void) { return atomic_load(&ready); }
__attribute__((noinline,optnone)) int wine_process_start(void) {
    int pair[2]={-1,-1};
    int result=socketpair(AF_UNIX,SOCK_STREAM,0,pair);
    if (!result) {close(pair[0]);close(pair[1]);}
    return result;
}
__attribute__((noinline,optnone)) static int unrelated_socketpair(void) {
    int pair[2];int result=socketpair(AF_UNIX,SOCK_STREAM,0,pair);
    if (!result) {close(pair[0]);close(pair[1]);}return result;
}
static void *become_ready(void *unused) { usleep(30000);atomic_store(&ready,1);return NULL; }
int main(int argc,char **argv) {
    assert(argc==2);
    int (*installed)(void)=dlsym(RTLD_DEFAULT,"bcd_guard_installed");
    if (!strcmp(argv[1],"unmatched")) {assert(installed && !installed());assert(unrelated_socketpair()==0);puts("unmatched image untouched");return 0;}
    assert(installed && installed());
    if (!strcmp(argv[1],"unrelated")) {assert(unrelated_socketpair()==0);puts("unrelated socketpair unaffected");return 0;}
    if (!strcmp(argv[1],"stopped")) {atomic_store(&ready,1);assert(wine_process_start()==-1 && errno==EPIPE);puts("stale-ready stopped server refused");return 0;}
    atomic_store(&running,1);
    if (!strcmp(argv[1],"timeout")) {assert(wine_process_start()==-1 && errno==ETIMEDOUT);puts("timeout refused");return 0;}
    if (!strcmp(argv[1],"delayed")) {pthread_t thread;pthread_create(&thread,NULL,become_ready,NULL);assert(wine_process_start()==0);pthread_join(thread,NULL);puts("delayed readiness accepted");return 0;}
    atomic_store(&ready,1);
    if (!strcmp(argv[1],"othergame")) {
        setenv("MADEIRA_EXE","C:\\OtherGame.exe",1);
        setenv("MADEIRA_OPTIN_DLLS","sfc",1);
        assert(wine_process_start()==0);
        assert(!strcmp(getenv("MADEIRA_OPTIN_DLLS"),"sfc"));puts("other game's settings untouched");return 0;
    }
    if (!strcmp(argv[1],"config")) {
        char directory[]="/tmp/bcd-guard-XXXXXX";assert(mkdtemp(directory));
        char path[1024],backup[1100];snprintf(path,sizeof(path),"%s/game.cfg",directory);snprintf(backup,sizeof(backup),"%s.before-wine-repair",path);
        const char *original="# my existing settings\nswap-mb = 4096\nenv.MADEIRA_OPTIN_DLLS = tbs;EVR.dll\n";
        FILE *file=fopen(path,"w");assert(file);fputs(original,file);fclose(file);
        setenv("MADEIRA_EXE","C:\\Ghost of Tsushima DIRECTORS CUT\\GhostOfTsushima.exe",1);
        setenv("MADEIRA_CFG_GAME",path,1);
        assert(wine_process_start()==0);
        char content[4096]={0},second[4096]={0},saved[4096]={0};
        file=fopen(path,"r");assert(file);size_t length=fread(content,1,sizeof(content)-1,file);fclose(file);
        assert(!strncmp(content,original,strlen(original)) && strstr(content,"env.MADEIRA_OPTIN_DLLS = tbs,evr,dxva2\n"));
        file=fopen(backup,"r");assert(file);fread(saved,1,sizeof(saved)-1,file);fclose(file);assert(!strcmp(saved,original));
        assert(!strcmp(getenv("MADEIRA_OPTIN_DLLS"),"tbs,evr,dxva2"));
        assert(wine_process_start()==0);
        file=fopen(path,"r");assert(file);assert(fread(second,1,sizeof(second)-1,file)==length);fclose(file);assert(!strcmp(content,second));
        unlink(path);unlink(backup);rmdir(directory);puts("game config merged, backed up and idempotent");return 0;
    }
    assert(!strcmp(argv[1],"ready"));assert(wine_process_start()==0);puts("ready server accepted");return 0;
}
