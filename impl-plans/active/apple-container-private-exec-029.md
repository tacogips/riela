# Apple Container private gateway execution

Issue: https://github.com/tacogips/riela/issues/144

Apple Container 1.5.0 persists init stdout/stderr to stdio.log and has no log-disable flag. Launch only a bounded secret-free idle init. Send explicit provider bindings in a bounded RIELAENV1 stdin frame to attached exec; invoke a guest guard that sets NoNewPrivs and verifies nonroot, zero capabilities, readonly root, protected bounded tmpfs and process/core limits. Always force-delete, including failures/cancellation. Preserve Docker/Podman transport.

Official images ship the guard and map /tmp to protected /dev/shm. Verify with synthetic public sentinels in output, environment and stdin; inspect runtime metadata and logs before cleanup. No real provider calls for privacy testing. Add fake runner regressions and compile/test actual guard failures. Integrate released Apple0.1.12 scoped folder creation and no uncertain mutation retries; release Riela0.2.9 after focused tests, source review, images and release packaging.

Audit: Apple container1.5.0 RuntimeService configures exec streams directly and keeps process config in memory. Containerization0.47.0 writes guest process.json under /run/container, mounted tmpfs, but debug logs interpolate process config. Therefore secrets are excluded from runtime argv/environment/config entirely: the guard reads a bounded frame on stdin after validating isolation. Synthetic initial env/stdin/output probes found empty init logs and no values in inspect or eight updated host metadata files (three large binary disks excluded); final framed transport/image proof follows.

Independent review found no blocker in frame encoding, guest guard or cleanup. Parent live Notes integration verified existing root/month reuse, five new category folders with correct account/parent, and exact ID reuse on a second canonical-name call. Caller offline capability probe passes against staged0.2.9 and requires no exec env bindings, exact private frame, guard and cleanup.

Final native gates with published Apple0.1.12 revision97dccf0:52 focused tests, one optional live integration skip, zero failures; changed-file SwiftLint clean. Stable final-validation-cli verifies0.2.9 and Apple0.1.12. Image synthetic tests remain pending before release tag.
