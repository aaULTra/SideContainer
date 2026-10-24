#include <assert.h>
#include <stdio.h>
#include "Readiness.h"
typedef struct { int running, ready, stop_at, ready_at, polls, running_reads; double time; } Fake;
static int running(void *p) {
    Fake *f = p; f->running_reads++;
    if (f->stop_at && f->running_reads >= f->stop_at) return 0;
    return f->running;
}
static int ready(void *p) { Fake *f=p; return f->ready || (f->ready_at && f->polls >= f->ready_at); }
static double now(void *p) { return ((Fake *)p)->time; }
static void pause_probe(void *p) { Fake *f=p; f->polls++; f->time += 0.01; }
static BCDServerResult run(Fake *f) {
    return bcd_wait_for_server((BCDServerProbe){running, ready, now, pause_probe, f}, 0.1);
}
int main(void) {
    Fake f={.running=1,.ready=1}; assert(run(&f)==BCD_SERVER_READY && f.polls==0);
    f=(Fake){.ready=1}; assert(run(&f)==BCD_SERVER_STOPPED); /* stale readiness */
    f=(Fake){0}; assert(run(&f)==BCD_SERVER_STOPPED);
    f=(Fake){.running=1,.ready_at=4}; assert(run(&f)==BCD_SERVER_READY && f.polls==4);
    f=(Fake){.running=1}; assert(run(&f)==BCD_SERVER_TIMEOUT && f.time>=0.1 && f.polls<12);
    f=(Fake){.running=1,.stop_at=4}; assert(run(&f)==BCD_SERVER_STOPPED && f.polls==3);
    f=(Fake){.running=1,.ready=1,.stop_at=2}; assert(run(&f)==BCD_SERVER_STOPPED);
    puts("7 Wine server readiness cases passed");
}
