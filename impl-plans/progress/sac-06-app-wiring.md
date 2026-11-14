# sac-06 App wiring progress

Implementation in progress. App control ports and HTTP adapters use the shared service; startup waits for the owner lock before phase B and binds the channel under the lock. Source discovery and session-root delegation use the shared helpers. The installed App was not launched.

Evidence is under `tmp/serverless-app-control/sac-06-app-wiring/`; the private build root is `tmp/serverless-app-control/build-sac-06`. The one-time `cp -cR .build/. tmp/serverless-app-control/build-sac-06/` seed exited 0. The first two builds failed on copied module cache paths (build-1.log and build-2.log); the copied private ModuleCache was removed and the build retried with plan-local module caches. Formal review and serial integration remain downstream.

## Implementation verification

- Private scratch seed: exit 0. `build-1.log` and `build-2.log` record the absolute-path module-cache failures. After removing only the copied private ModuleCache, `build-3.log` records the retry with plan-local `CLANG_MODULE_CACHE_PATH` and `SWIFTPM_MODULECACHE_OVERRIDE`, `--disable-sandbox --skip-update`: exit 0, including RielaApp.
- `test-1.log`: assigned filtered suites, exit 0, 115 tests, 0 failures.
- `lint-plan.log`: plan's eight-file lint, exit 0, zero violations. `lint-1.log`: strict changed-file lint from `changed-swift.nul`, exit 0.
- `phase-grep.log`: initial preparation, load and autostart calls are inside `runPhaseB`; the later state load is inside profile switching. `render-grep.log` is empty; `service-grep.log` lists the HTTP adapters and socket host. `diff-check.log` is empty.
- `source-sha256.log` records the eight implementation files. Builds and tests used a shared source tree and the private `build-sac-06` output; final combined-tree verification remains the serial integration gate.
- Review-dependent completion, independent review, staging and commit are downstream. No formal review is claimed here.

The author self-check corrected the waiting status after lock acquisition. Final-source evidence: `build-final.log` exit 0, `test-final.log` exit 0 (115 tests, zero failures), `lint-plan-final.log` and `lint-final-2.log` exit 0, and `source-sha256-final.log` / `source-check-final.log` identify and verify the eight source files. The earlier passing build and test predate that status correction and are retained only as historical evidence.

## Integration repair 2026-11-12

Finding `IR-SAC06-MENU-REGRESSION-TEST`: the ready-state fixture now marks owner startup complete; a separate test covers the waiting menu. Existing assertions are unchanged. Evidence in `tmp/serverless-app-control/sac-06-app-wiring/`: `reproduce-amend2.log` exit 1 (one test, four assertions), `build-amend2.log` exit 0, `test-amend2.log` exit 0 (16 tests), `test-suites-amend2.log` exit 0 (115 tests), `lint-amend2.log` and `lint-manifest-amend2.log` exit 0. `test-diff-amend2.log` has additions only; `source-sha256-amend2.log` records source identity. Before and after menu hashes match: `4a2f16f0be9e99105e036fdc2670d956c23fa82f256336fcc6b2cb8d206654c8` (`menu-before-amend2.log`, `menu-after-amend2.log`). Serial aggregate baseline disposition and independent review remain downstream.
