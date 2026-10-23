#ifndef BCD_READINESS_H
#define BCD_READINESS_H
/* Pure state machine: the platform adapter supplies the clock and server state. */
typedef enum {
    BCD_SERVER_READY = 0,
    BCD_SERVER_STOPPED = 1,
    BCD_SERVER_TIMEOUT = 2
} BCDServerResult;

typedef struct {
    int (*running)(void *);
    int (*ready)(void *);
    double (*now)(void *);
    void (*pause)(void *);
    void *context;
} BCDServerProbe;

static BCDServerResult bcd_wait_for_server(BCDServerProbe probe, double timeout) {
    double deadline = probe.now(probe.context) + timeout;
    for (;;) {
        if (!probe.running(probe.context)) return BCD_SERVER_STOPPED;
        if (probe.ready(probe.context)) {
            /* A stale ready flag must not make a stopped server look usable. */
            return probe.running(probe.context) ? BCD_SERVER_READY : BCD_SERVER_STOPPED;
        }
        if (probe.now(probe.context) >= deadline) return BCD_SERVER_TIMEOUT;
        probe.pause(probe.context);
    }
}
#endif
