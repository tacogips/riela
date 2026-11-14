# ssg2-05 maintenance host wiring progress

Status: implementation incomplete; review pending. Dependencies ssg2-04 and ssg2-06 were accepted by dispatch. Design §5 is aligned with the assigned plan.

Implemented target locking, conversion, profile vacuum caps, automatic policy gating, explicit store selection and scheduled CLI/App wiring. Replaced the no-config skip test because built-in defaults enable automatic maintenance. Added cap and held-lock coverage and scheduled conversion tests. Source identities are recorded in `tmp/ssg2/ssg2-05-maintenance-host-wiring/pre-sha256.txt` and `post-sha256.txt`; per-edit intentions and copies are in that directory.

Build: `build.log` exit 0 on a moving shared tree. Initial test `test.log` exit 1 (40 tests, 1 failure); `test-final.log` exit 1 (41 tests, 2 failures): the new scheduled fixture selected an unsafe /var symlink path. `diagnostic.log` exit 1 because sibling `Tests/RielaCLITests/GarbageCollectionCommandTests.swift` changed during compilation; `diagnostic-2.log` exit 1 confirmed the fixture path. The fixture now uses the repository temporary directory. Strict selected-file lint `changed-lint.log` exit 0; exact plan lint `lint-final.log` exit 0 before the last fixture edit. Earlier `lint.log` exit 2 scanned the whole repository because the planned new file did not yet exist.

Outstanding: rerun gates on final source, verify scheduled test fix, add the remaining specified run-end selection, disabled-policy, run-end legacy conversion, scheduler lifecycle and scheduled vacuum tests, and record final evidence. Formal reviews and integration remain downstream.

Continuation: `test-final-2.log` exit 0, 41 tests, 0 failures on the moving shared tree; `lint-final-2.log` exit 0, `changed-lint-final.log` exit 0. The scheduled fixture path repair is verified. The remaining coverage listed above is still incomplete; no review acceptance is claimed.

## Continuation 1 — implementation complete, review pending

The preceding outstanding list is superseded. `AutomaticRetentionTests` now exercises project, user, deduplicated explicit project and other explicit store selection. `RunEndStorageMaintenanceTests` checks no-config freelist and file-size reduction, automatic opt-out, held automatic lock preserving a legacy row and freelist, run-end conversion, 4096/scheduled caps and NONE mode/freelist. `EventLiveServeMaintenanceTests` checks conversion and vacuum via both scheduled entry points and a short-interval scheduler pass followed by stop and cancellation. CLI and hook calls use captured temporary environments. Per-edit intentions and pre-edit copies are under `tmp/ssg2/ssg2-05-maintenance-host-wiring/`; final Swift hashes are in `post-cont1.sha256`.

Current-source gates: `build-cont1-final.log` exit 0, `test-cont1-final.log` exit 0 (47 tests, 0 failures), `lint-cont1-final2.log` exit 0 and `changed-lint-cont1-final2.log` exit 0; `acceptance-cont1.log` exit 0. Verification was performed on a moving shared tree. Formal test-integrity, adversarial and serial integration reviews remain downstream.
