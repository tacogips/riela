# sac-04 control service progress

Implemented the seven-operation service and optional live reload revision. Preserved the existing App ports and reload/cancel tests. App and channel wiring belong to downstream plans.

Verification evidence is under `tmp/serverless-app-control/sac-04-control-service/`. Initial build and test attempts exposed and corrected Swift syntax and test-fixture issues; their logs are retained. Final build: `build-final-3.log` (exit 0). Final test: `test-final-3.log` (exit 0, 29 tests, 0 failures). Selected strict lint: `lint-final-3.log` (exit 0). Plan lint: `lint-plan-final-3.log` (exit 0). Unchanged tests check: `unchanged.log` (exit 0).

Formal test-integrity, adversarial and integration review remain downstream. Verification was run on the shared tree; the serial integration gate must repeat it.

Continuation added explicit revision encoding, 422 run passthrough, secret-bearing snapshot and status key, profile, shutdown, serialization and error response assertions. Final verification: `build-continuation-2.log`, `test-continuation-1.log`, `lint-continuation-1.log`, `lint-plan-continuation-1.log`, and `unchanged-continuation.log` all exit 0.
