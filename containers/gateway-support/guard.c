#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/statvfs.h>
#include <sys/vfs.h>
#include <linux/magic.h>
#include <errno.h>

static void fail(void) { fputs("Gateway isolation verification failed\n", stderr); exit(125); }

static size_t consumed = 0;
static void exact(char *buffer, size_t length) {
    if (length > 1048576 || consumed + length > 1048576) fail();
    consumed += length;
    while (length) {
        ssize_t count = read(STDIN_FILENO, buffer, length);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) fail();
        buffer += count; length -= (size_t)count;
    }
}
static size_t number(void) {
    size_t value = 0, digits = 0; char byte;
    for (;;) {
        exact(&byte, 1);
        if (byte == '\n' && digits) return value;
        if (byte < '0' || byte > '9' || ++digits > 7) fail();
        value = value * 10 + (size_t)(byte - '0');
    }
}
static void bindings(void) {
    char magic[10]; exact(magic, 10);
    if (memcmp(magic, "RIELAENV1\n", 10)) fail();
    size_t count = number(); if (count > 128) fail();
    for (size_t index = 0; index < count; index++) {
        size_t keyLength = number(), valueLength = number();
        if (!keyLength || keyLength > 255 || valueLength > 1048576) fail();
        char key[256]; char *value = malloc(valueLength + 1); if (!value) fail();
        exact(key, keyLength); exact(value, valueLength);
        key[keyLength] = 0; value[valueLength] = 0;
        size_t prefix = !strncmp(key, "X_GW_", 5) ? 5 : !strncmp(key, "GMAIL_GATEWAY_", 14) ? 14 : 0;
        if (!prefix || keyLength <= prefix || strlen(value) != valueLength) fail();
        for (size_t j = prefix; j < keyLength; j++)
            if (!(key[j] >= 'A' && key[j] <= 'Z') && !(key[j] >= '0' && key[j] <= '9') && key[j] != '_') fail();
        if (setenv(key, value, 1)) fail();
        memset(value, 0, valueLength); free(value);
    }
}

int main(int argc, char **argv) {
    if (argc < 2 || getuid() != 10001 || geteuid() != 10001 || getgid() != 10001) fail();
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) || prctl(PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0) != 1) fail();
    FILE *status = fopen("/proc/self/status", "r");
    if (!status) fail();
    char line[512]; unsigned int seen = 0;
    while (fgets(line, sizeof line, status)) {
        if (!strncmp(line, "Cap", 3)) {
            char *colon = strchr(line, ':');
            if (!colon || strtoull(colon + 1, NULL, 16) != 0) fail();
            seen++;
        }
    }
    fclose(status);
    if (seen != 5) fail();
    struct rlimit limit;
    if (getrlimit(RLIMIT_NPROC, &limit) || limit.rlim_cur > 256 || limit.rlim_max > 256) fail();
    if (getrlimit(RLIMIT_CORE, &limit) || limit.rlim_cur != 0 || limit.rlim_max != 0) fail();
    struct statvfs root, temp; struct statfs filesystem;
    if (statvfs("/", &root) || !(root.f_flag & ST_RDONLY)) fail();
    if (statvfs("/tmp", &temp) || statfs("/tmp", &filesystem) || filesystem.f_type != TMPFS_MAGIC) fail();
    unsigned long required = ST_NOSUID | ST_NODEV | ST_NOEXEC;
    if ((temp.f_flag & required) != required || temp.f_blocks * temp.f_frsize > 256ULL * 1024 * 1024) fail();
    if (setenv("TMPDIR", "/tmp", 1)) fail();
    bindings();
    execvp(argv[1], argv + 1);
    fail();
}
