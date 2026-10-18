# Apple Container private gateway execution

Issue: https://github.com/tacogips/riela/issues/144

Apple Container 1.5.0 persists init stdout/stderr to stdio.log and has no log-disable flag. Launch only a bounded secret-free idle init. Send explicit provider bindings by name to attached exec; invoke a guest guard that sets NoNewPrivs and verifies nonroot, zero capabilities, readonly root, protected bounded tmpfs and process/core limits. Always force-delete, including failures/cancellation. Preserve Docker/Podman transport.

Official images ship the guard and map /tmp to protected /dev/shm. Verify with synthetic public sentinels in output, environment and stdin; inspect runtime metadata and logs before cleanup. No real provider calls for privacy testing. Add fake runner regressions and compile/test actual guard failures. Integrate released Apple0.1.11 scoped folder creation and no uncertain mutation retries; release Riela0.2.9 after focused tests, source review, images and release packaging.
