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

static void fail(void) { fputs("Gateway isolation verification failed\n", stderr); exit(125); }

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
    execvp(argv[1], argv + 1);
    fail();
}
