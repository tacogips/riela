# sac-07 implementation progress

Implementation complete; formal review and combined-tree integration remain pending. The CLI selects explicit HTTP or local channel, reads execution projections locally, and performs stopped-App reload through the shared service under the owner lock. The local tests use injected `/tmp/rac-` roots and temporary HOME.

- Private scratch seed `cp -cR .build/. tmp/serverless-app-control/build-sac-07/` exited 0 (`tmp/serverless-app-control/sac-07-cli-instance-local-mode/seed.log`). The first build failed on copied module-cache paths; only the private copied cache was removed. Final build with private module caches and `--disable-sandbox --skip-update` exited 0 (`build-final-3.log`).
- The final test filter ran 27 tests, zero failures (`test-final-2.log`). The prior 27-test attempt had one invalid-fixture failure (`test-attempt-1.log`); an existing requested malformed definition is now validated after discovery fails.
- Strict selected-file lint and the plan lint exited 0 (`lint-final-3.log`, `lint-plan-2.log`); unchanged existing HTTP tests and diff check exited 0 (`unchanged-tests.log`, `diff-final.log`).
- `ls ~/.riela/rielaapp/run` exited 1 because the directory does not exist (`real-root-check.log`). Tests inject isolated roots; no pre-test timestamp snapshot was captured.
- Source identity is recorded in `tmp/serverless-app-control/sac-07-cli-instance-local-mode/source-sha256-final.log`. All log names above are relative to that evidence directory. The scratch path is retained for finalization.
