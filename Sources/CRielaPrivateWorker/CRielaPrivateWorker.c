#include "CRielaPrivateWorker.h"

static int prepared = 0;

#if defined(__linux__)
#include <string.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <unistd.h>

/* Set this before Swift concurrency creates threads: NO_NEW_PRIVS is per-thread
 * and must be inherited by every worker that may launch a vendor/domain child. */
__attribute__((constructor))
static void prepare_private_worker(int argc, char **argv, char **environment) {
    (void)environment;
    if (argc != 2 || strcmp(argv[1], "__riela-private-workflow-worker") != 0) {
        return;
    }
    const struct rlimit processes = {256, 256};
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
