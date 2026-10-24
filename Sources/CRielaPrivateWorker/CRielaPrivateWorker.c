#include "CRielaPrivateWorker.h"

static int prepared = 0;

#if defined(__linux__)
#include <string.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <unistd.h>

#define RIELA_PRIVATE_WORKER_MAX_PROCESSES 1024

/* Set this before Swift concurrency creates threads: NO_NEW_PRIVS is per-thread
 * and must be inherited by every worker that may launch a vendor/domain child.
 *
 * Exit status 112 (PrivateWorkflowWorker.guestRefusalStatus) means the guest
 * identity or limits were refused: root uid, gid 0, set-id mismatch, or a
 * failed prctl/setrlimit. The host maps it to one fixed policy error.
 *
 * RLIMIT_NPROC counts every task of the real uid, so the guest uid must not be
 * shared with host users (rootful Docker/Podman share the host uid space). The
 * limit never exceeds the inherited hard limit: an unprivileged process cannot
 * raise it, and `--ulimit nproc=N` with N < 1024 must still start. */
__attribute__((constructor))
static void prepare_private_worker(int argc, char **argv, char **environment) {
    (void)environment;
    if (argc != 2 || strcmp(argv[1], "__riela-private-workflow-worker") != 0) {
        return;
    }
    struct rlimit current;
    if (getrlimit(RLIMIT_NPROC, &current) != 0) {
        _exit(112);
    }
    rlim_t bound = RIELA_PRIVATE_WORKER_MAX_PROCESSES;
    if (current.rlim_max != RLIM_INFINITY && current.rlim_max < bound) {
        bound = current.rlim_max;
    }
    const struct rlimit processes = {bound, bound};
    const struct rlimit core = {0, 0};
    if (getuid() == 0 || getgid() == 0 || getuid() != geteuid() || getgid() != getegid()
        || prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0
        || setrlimit(RLIMIT_NPROC, &processes) != 0 || setrlimit(RLIMIT_CORE, &core) != 0) {
        _exit(112);
    }
    prepared = 1;
}
#endif

int riela_private_worker_prepared(void) { return prepared; }
