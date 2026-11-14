# mrot-05 progress

Implemented the configured-run request key/type validation and synchronous in-memory and live-store busy check before the run limit. Running launches carry their configured identity; the 409 reports the session or `pending`. Probe errors fail open and `allowOverlap` bypasses the check. Added six focused route scenarios using temporary stores and real locks.

Evidence: `tmp/manual-overlap-terminal-reserve/mrot-05-app-run-busy-check/`. The overlap suite passed 6 tests on the shared moving tree. Build, existing launch tests (2 passed) and plan/strict changed-file lint all exited 0. Earlier attempts record concurrent source modification and fixture compile errors. Formal integrity, adversarial and combined-tree reviews remain downstream.
