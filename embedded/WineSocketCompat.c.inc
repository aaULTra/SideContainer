/* BCD guest compatibility: retry denied Wine filesystem sockets in the
 * process-owned temporary directory. No sandbox rules or entitlements change.
 * Included by LCBootstrap.m and exercised by native socket tests. */
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <stddef.h>
#include <pthread.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>

#define SI_WINE_SOCKET_SLOTS 8
static int (*si_wine_real_bind)(int, const struct sockaddr *, socklen_t) = bind;
static int (*si_wine_real_connect)(int, const struct sockaddr *, socklen_t) = connect;
static int (*si_wine_real_unlink)(const char *) = unlink;
static int (*si_wine_real_chmod)(const char *, mode_t) = chmod;
static pthread_mutex_t si_wine_socket_lock = PTHREAD_MUTEX_INITIALIZER;
static char si_wine_home[PATH_MAX];
static char si_wine_tmp[PATH_MAX];
static char si_wine_socket_dir[PATH_MAX];
static int si_wine_log_fd = -1;
static struct { char original[PATH_MAX]; char relocated[sizeof(((struct sockaddr_un *)0)->sun_path)]; }
    si_wine_sockets[SI_WINE_SOCKET_SLOTS];

static void si_wine_log(const char *format, ...) {
    int saved = errno;
    char message[2048];
    const char *prefix = "[LC-WineSocket] ";
    size_t used = strlen(prefix);
    memcpy(message, prefix, used);
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(message + used, sizeof(message) - used - 1, format, arguments);
    va_end(arguments);
    size_t length = strlen(message);
    message[length++] = '\n';
    if (si_wine_log_fd >= 0) (void)write(si_wine_log_fd, message, length);
    (void)write(STDERR_FILENO, message, length);
    errno = saved;
}

/* Canonicalise the existing parent, never the not-yet-created socket. Only
 * Wine's exact .wineserver/server-<device>-<inode>/socket is eligible. */
static int si_wine_socket_key(const char *path, char output[PATH_MAX]) {
    if (!si_wine_home[0] || !path || !path[0]) return 0;
    char parent[PATH_MAX], resolved[PATH_MAX];
    size_t length = strnlen(path, sizeof(parent));
    if (!length || length >= sizeof(parent)) return 0;
    memcpy(parent, path, length + 1);
    char *slash = strrchr(parent, '/');
    const char *name = slash ? slash + 1 : parent;
    if (strcmp(name, "socket")) return 0;
    if (slash) { if (slash == parent) slash[1] = 0; else *slash = 0; }
    else strcpy(parent, ".");
    if (!realpath(parent, resolved)) return 0;
    size_t home_length = strlen(si_wine_home);
    if (strncmp(resolved, si_wine_home, home_length) || resolved[home_length] != '/') return 0;
    const char *server = strstr(resolved + home_length, "/.wineserver/server-");
    if (!server) return 0;
    server += strlen("/.wineserver/server-");
    if (!*server) return 0;
    for (const char *p = server; *p; ++p)
        if (!((*p >= '0' && *p <= '9') || (*p >= 'a' && *p <= 'f') ||
              (*p >= 'A' && *p <= 'F') || *p == '-')) return 0;
    int count = snprintf(output, PATH_MAX, "%s/socket", resolved);
    return count > 0 && count < PATH_MAX;
}

static int si_wine_address_key(const struct sockaddr *address, socklen_t length, char key[PATH_MAX]) {
    size_t offset = offsetof(struct sockaddr_un, sun_path);
    if (!address || length <= offset || address->sa_family != AF_UNIX) return 0;
    const struct sockaddr_un *unix_address = (const struct sockaddr_un *)address;
    size_t available = length - offset;
    if (available > sizeof(unix_address->sun_path)) available = sizeof(unix_address->sun_path);
    size_t count = strnlen(unix_address->sun_path, available);
    if (!count || count == available) return 0; /* unnamed/abstract/unterminated */
    return si_wine_socket_key(unix_address->sun_path, key);
}

static socklen_t si_wine_address(struct sockaddr_un *address, const char *path) {
    memset(address, 0, sizeof(*address));
    address->sun_family = AF_UNIX;
    memcpy(address->sun_path, path, strlen(path) + 1);
    socklen_t length = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + strlen(path) + 1);
#ifdef __APPLE__
    address->sun_len = length;
#endif
    return length;
}

static int si_wine_find_socket(const char *key) {
    for (int i = 0; i < SI_WINE_SOCKET_SLOTS; ++i)
        if (!strcmp(si_wine_sockets[i].original, key)) return i;
    return -1;
}

static void si_wine_socket_cleanup(void) {
    for (int i = 0; i < SI_WINE_SOCKET_SLOTS; ++i)
        if (si_wine_sockets[i].relocated[0]) si_wine_real_unlink(si_wine_sockets[i].relocated);
    if (si_wine_socket_dir[0]) rmdir(si_wine_socket_dir);
}

static int si_wine_bind(int fd, const struct sockaddr *address, socklen_t length) {
    int incoming = errno;
    char key[PATH_MAX];
    if (!si_wine_address_key(address, length, key)) {
        errno = incoming;
        return si_wine_real_bind(fd, address, length);
    }
    pthread_mutex_lock(&si_wine_socket_lock);
    int slot = si_wine_find_socket(key);
    if (slot >= 0) {
        struct sockaddr_un retry;
        socklen_t retry_length = si_wine_address(&retry, si_wine_sockets[slot].relocated);
        errno = incoming;
        int result = si_wine_real_bind(fd, (const struct sockaddr *)&retry, retry_length);
        int error = errno;
        si_wine_log("bind mapped original=%s target=%s result=%d errno=%d", key, retry.sun_path, result, result ? error : 0);
        pthread_mutex_unlock(&si_wine_socket_lock);
        errno = error;
        return result;
    }
    errno = incoming;
    int result = si_wine_real_bind(fd, address, length);
    int original_error = errno;
    si_wine_log("bind original=%s result=%d errno=%d (%s)", key, result,
                result ? original_error : 0, result ? strerror(original_error) : "ok");
    if (!result || (original_error != EPERM && original_error != EACCES)) {
        pthread_mutex_unlock(&si_wine_socket_lock);
        errno = original_error;
        return result;
    }
    for (int i = 0; i < SI_WINE_SOCKET_SLOTS; ++i) if (!si_wine_sockets[i].original[0]) { slot = i; break; }
    if (slot < 0) goto unavailable;
    if (!si_wine_socket_dir[0]) {
        char directory[PATH_MAX];
        int count = snprintf(directory, sizeof(directory), "%s/WXXXXXX", si_wine_tmp);
        if (count < 0 || count >= (int)sizeof(directory) ||
            (size_t)count + strlen("/s0") >= sizeof(((struct sockaddr_un *)0)->sun_path)) {
            si_wine_log("retry unavailable: process temporary path exceeds Unix socket path limit");
            goto unavailable;
        }
        if (!mkdtemp(directory)) { si_wine_log("retry directory creation failed errno=%d (%s)", errno, strerror(errno)); goto unavailable; }
        strcpy(si_wine_socket_dir, directory); /* mkdtemp creates mode 0700 */
    }
    char target[sizeof(((struct sockaddr_un *)0)->sun_path)];
    int count = snprintf(target, sizeof(target), "%s/s%d", si_wine_socket_dir, slot);
    if (count < 0 || count >= (int)sizeof(target)) goto unavailable;
    struct sockaddr_un retry;
    socklen_t retry_length = si_wine_address(&retry, target);
    result = si_wine_real_bind(fd, (const struct sockaddr *)&retry, retry_length);
    int retry_error = errno;
    si_wine_log("bind retry original=%s target=%s result=%d errno=%d (%s)", key, target,
                result, result ? retry_error : 0, result ? strerror(retry_error) : "ok");
    if (!result) {
        strcpy(si_wine_sockets[slot].original, key);
        strcpy(si_wine_sockets[slot].relocated, target);
        pthread_mutex_unlock(&si_wine_socket_lock);
        errno = incoming;
        return 0;
    }
unavailable:
    pthread_mutex_unlock(&si_wine_socket_lock);
    errno = original_error;
    return -1;
}

static int si_wine_connect(int fd, const struct sockaddr *address, socklen_t length) {
    int incoming = errno;
    char key[PATH_MAX], target[sizeof(((struct sockaddr_un *)0)->sun_path)] = {0};
    if (si_wine_address_key(address, length, key)) {
        pthread_mutex_lock(&si_wine_socket_lock);
        int slot = si_wine_find_socket(key);
        if (slot >= 0) strcpy(target, si_wine_sockets[slot].relocated);
        pthread_mutex_unlock(&si_wine_socket_lock);
    }
    errno = incoming;
    if (!target[0]) return si_wine_real_connect(fd, address, length);
    struct sockaddr_un redirected;
    socklen_t redirected_length = si_wine_address(&redirected, target);
    int result = si_wine_real_connect(fd, (const struct sockaddr *)&redirected, redirected_length);
    int error = errno;
    si_wine_log("connect mapped original=%s result=%d errno=%d", key, result, result ? error : 0);
    errno = error;
    return result;
}

static int si_wine_file_target(const char *path, char target[sizeof(((struct sockaddr_un *)0)->sun_path)]) {
    char key[PATH_MAX];
    if (!si_wine_socket_key(path, key)) return 0;
    pthread_mutex_lock(&si_wine_socket_lock);
    int slot = si_wine_find_socket(key);
    if (slot >= 0) strcpy(target, si_wine_sockets[slot].relocated);
    pthread_mutex_unlock(&si_wine_socket_lock);
    return slot >= 0;
}

static int si_wine_unlink(const char *path) {
    int incoming = errno;
    char target[sizeof(((struct sockaddr_un *)0)->sun_path)];
    int mapped = si_wine_file_target(path, target);
    errno = incoming;
    return si_wine_real_unlink(mapped ? target : path);
}

static int si_wine_chmod(const char *path, mode_t mode) {
    int incoming = errno;
    char target[sizeof(((struct sockaddr_un *)0)->sun_path)];
    int mapped = si_wine_file_target(path, target);
    errno = incoming;
    return si_wine_real_chmod(mapped ? target : path, mode);
}

static int si_wine_socket_prepare(const char *bundle_id, const char *guest_home, const char *temporary) {
    const char *bcd = "com.thebcd69.bcd";
    if (!bundle_id || strncmp(bundle_id, bcd, strlen(bcd)) ||
        (bundle_id[strlen(bcd)] && bundle_id[strlen(bcd)] != '.')) return 0;
    if (!guest_home || !temporary || !realpath(guest_home, si_wine_home) || !realpath(temporary, si_wine_tmp)) return 0;
    /* Darwin's canonical /private/var spelling wastes eight of sun_path's 104
     * bytes. Use /var only when stat proves it names the very same directory. */
    if (!strncmp(si_wine_tmp, "/private/var/", strlen("/private/var/"))) {
        struct stat canonical, short_path;
        if (!stat(si_wine_tmp, &canonical) && !stat(si_wine_tmp + strlen("/private"), &short_path) &&
            canonical.st_dev == short_path.st_dev && canonical.st_ino == short_path.st_ino)
            memmove(si_wine_tmp, si_wine_tmp + strlen("/private"), strlen(si_wine_tmp + strlen("/private")) + 1);
    }
    char log_path[PATH_MAX];
    int count = snprintf(log_path, sizeof(log_path), "%s/Documents/LC-WineSocket.log", si_wine_home);
    if (count > 0 && count < (int)sizeof(log_path)) si_wine_log_fd = open(log_path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
    atexit(si_wine_socket_cleanup);
    si_wine_log("compat v1 enabled bundle=%s guest=%s process-tmp=%s", bundle_id, si_wine_home, si_wine_tmp);
    return 1;
}
