# ssg2-07 implementation progress

Status: implementation complete; formal integrity, adversarial and integration review pending.

Dependency ssg2-06 is accepted by dispatch. Design §10.1–10.2 matches the plan. Generated removal retries after restoring owner directory permissions within the resolved root without following symlinks. Removal failures become warnings; retention propagates them without failing the target. Compact retains warnings and no longer treats retention failures or reconciliation verdicts as remaining work. Busy retention remains a failing exit.

Coverage: `testReadOnlySnapshotAndExternalSymlink` checks dry-run modes, removal and outside link safety; `testUnremovableSnapshotIsWarningAndOtherEntriesAreRemoved` checks warning and continued collection; `testReadOnlySnapshotsAndUnremovableWarning` checks CLI success; `testGeneratedWarningDoesNotLeaveCompactWorkRemaining`, `testLiveNestedInvocationDoesNotLeaveWorkRemaining`, `testHeldSessionLockIsSkippedAndLeavesWorkRemaining`, and the second-pass assertions cover compact.

Removed remaining assignments: reconciliation live/skipped and retention failure. Kept: conversion batch, lock and errors; memory conversion; dry-run estimate; pin failure; checkpoint, vacuum and reclamation states. Pre/post SHA256: `tmp/ssg2/ssg2-07-gc-readonly-workremaining/pre.sha256` and `post.sha256`. Per-edit intentions are in the same directory. Verification on the moving shared tree: `build-final2.log` exit 0; `test-final7.log` exit 0, 94 tests, 0 failures; `lint-final2.log` and `lint-changed-final3.log` exit 0. Earlier failed test/lint attempts retained in `test-final*.log` and `lint-final.log` and fixed. Combined-tree review and verification remain downstream.
