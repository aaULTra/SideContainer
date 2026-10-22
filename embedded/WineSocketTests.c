#include "WineSocketCompat.c.inc"
#include <assert.h>
#include <netinet/in.h>

static int denial = EPERM;
static int deny_retry;
static int bind_calls;
static int controlled_bind(int fd, const struct sockaddr *address, socklen_t length) {
    ++bind_calls;
    if (address && address->sa_family == AF_UNIX) {
        const char *path = ((const struct sockaddr_un *)address)->sun_path;
        if (deny_retry || !strcmp(path, "socket")) { errno = denial; return -1; }
    }
    return bind(fd, address, length);
}

static void make_directory(const char *path) { assert(mkdir(path, 0700) == 0); }

int main(int argc, char **argv) {
    assert(argc == 2);
    char root[] = "/tmp/siwine-XXXXXX";
    assert(mkdtemp(root));
    char home[PATH_MAX], temporary[PATH_MAX], path[PATH_MAX], server[PATH_MAX];
    snprintf(home, sizeof(home), "%s/home", root); make_directory(home);
    snprintf(temporary, sizeof(temporary), "%s/tmp", root); make_directory(temporary);
    snprintf(path, sizeof(path), "%s/home/Documents", root); make_directory(path);
    snprintf(path, sizeof(path), "%s/home/Documents/wine", root); make_directory(path);
    snprintf(path, sizeof(path), "%s/home/Documents/wine/.wineserver", root); make_directory(path);
    snprintf(server, sizeof(server), "%s/home/Documents/wine/.wineserver/server-1-2", root); make_directory(server);
    assert(chdir(server) == 0);

    if (!strcmp(argv[1], "other-app")) {
        assert(!si_wine_socket_prepare("com.example.app", home, temporary));
        assert(!si_wine_home[0]);
        puts("unrelated app not enabled"); return 0;
    }
    assert(si_wine_socket_prepare("com.thebcd69.bcd", home, temporary));
    if (!strcmp(argv[1], "paths")) {
        char key[PATH_MAX], absolute[PATH_MAX], canonical[PATH_MAX];
        assert(si_wine_socket_key("socket", key));
        assert(realpath(server, canonical));
        snprintf(absolute, sizeof(absolute), "%s/socket", canonical);
        assert(!strcmp(key, absolute));
        assert(!si_wine_socket_key("other", key));
        assert(!si_wine_socket_key("socket/", key));
        assert(!si_wine_socket_key("", key));
        assert(!si_wine_socket_key(NULL, key));
        assert(!chdir(temporary));
        assert(!si_wine_socket_key("socket", key));
        puts("path scope checks passed"); return 0;
    }
    si_wine_real_bind = controlled_bind;
    int listener = socket(AF_UNIX, SOCK_STREAM, 0); assert(listener >= 0);
    struct sockaddr_un address;
    socklen_t length = si_wine_address(&address, "socket");

    if (!strcmp(argv[1], "unrelated-socket")) {
        length = si_wine_address(&address, "unrelated");
        assert(!si_wine_bind(listener, (const struct sockaddr *)&address, length));
        assert(bind_calls == 1); assert(!si_wine_socket_dir[0]);
        assert(!si_wine_chmod("unrelated", 0600));
        assert(!si_wine_unlink("unrelated"));
    } else if (!strcmp(argv[1], "normal-bind")) {
        si_wine_real_bind = bind;
        assert(!si_wine_bind(listener, (const struct sockaddr *)&address, length));
        assert(!si_wine_socket_dir[0]); assert(!si_wine_unlink("socket"));
    } else if (!strcmp(argv[1], "other-error")) {
        denial = EADDRINUSE;
        assert(si_wine_bind(listener, (const struct sockaddr *)&address, length) == -1);
        assert(errno == EADDRINUSE); assert(bind_calls == 1); assert(!si_wine_socket_dir[0]);
    } else if (!strcmp(argv[1], "failed-retry")) {
        deny_retry = 1;
        assert(si_wine_bind(listener, (const struct sockaddr *)&address, length) == -1);
        assert(errno == EPERM); assert(bind_calls == 2); assert(!si_wine_sockets[0].original[0]);
    } else if (!strcmp(argv[1], "long-temp")) {
        memset(si_wine_tmp, 'x', sizeof(((struct sockaddr_un *)0)->sun_path));
        si_wine_tmp[sizeof(((struct sockaddr_un *)0)->sun_path)] = 0;
        assert(si_wine_bind(listener, (const struct sockaddr *)&address, length) == -1);
        assert(errno == EPERM); assert(bind_calls == 1); assert(!si_wine_socket_dir[0]);
    } else if (!strcmp(argv[1], "outside-home")) {
        char outside[PATH_MAX];
        snprintf(outside, sizeof(outside), "%s/.wineserver", root); make_directory(outside);
        snprintf(outside, sizeof(outside), "%s/.wineserver/server-1-2", root); make_directory(outside);
        assert(!chdir(outside));
        assert(si_wine_bind(listener, (const struct sockaddr *)&address, length) == -1);
        assert(bind_calls == 1); assert(!si_wine_socket_dir[0]);
    } else if (!strcmp(argv[1], "ipv4")) {
        struct sockaddr_in ip = {0}; ip.sin_family = AF_INET; ip.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
#ifdef __APPLE__
        ip.sin_len = sizeof(ip);
#endif
        int network = socket(AF_INET, SOCK_STREAM, 0); assert(network >= 0);
        assert(!si_wine_bind(network, (const struct sockaddr *)&ip, sizeof(ip)));
        assert(bind_calls == 1); assert(!si_wine_socket_dir[0]); close(network);
    } else {
        if (!strcmp(argv[1], "eacces")) denial = EACCES;
        assert(!si_wine_bind(listener, (const struct sockaddr *)&address, length));
        assert(bind_calls == 2);
        struct stat attributes;
        assert(!stat(si_wine_socket_dir, &attributes));
        assert((attributes.st_mode & 0777) == 0700);
        assert(!si_wine_chmod("socket", 0600));
        assert(!stat(si_wine_sockets[0].relocated, &attributes));
        assert((attributes.st_mode & 0777) == 0600);
        assert(!listen(listener, 1));
        int client = socket(AF_UNIX, SOCK_STREAM, 0); assert(client >= 0);
        /* The client may use an absolute path while Wine bound a relative one. */
        char absolute[PATH_MAX]; snprintf(absolute, sizeof(absolute), "%s/socket", server);
        if (strlen(absolute) < sizeof(address.sun_path)) length = si_wine_address(&address, absolute);
        assert(!si_wine_connect(client, (const struct sockaddr *)&address, length));
        int accepted = accept(listener, NULL, NULL); assert(accepted >= 0);
        assert(write(client, "wine", 4) == 4);
        char message[4]; assert(read(accepted, message, sizeof(message)) == 4);
        assert(!memcmp(message, "wine", 4));
        close(accepted); close(client); close(listener);
        assert(!si_wine_unlink("socket"));
        assert(access(si_wine_sockets[0].relocated, F_OK) == -1 && errno == ENOENT);
        /* A server restart must reuse the mapping and must not hit the denied
         * original or leak an occupied relocated socket. */
        listener = socket(AF_UNIX, SOCK_STREAM, 0); assert(listener >= 0);
        length = si_wine_address(&address, "socket");
        assert(!si_wine_bind(listener, (const struct sockaddr *)&address, length));
        assert(bind_calls == 3); assert(!si_wine_unlink("socket"));
    }
    close(listener);
    si_wine_socket_cleanup();
    puts("Wine socket compatibility checks passed");
    return 0;
}
