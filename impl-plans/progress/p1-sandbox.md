# P1 sandbox implementation progress

- Workflow mode: `issue-resolution`
- Issue reference: `workflow-input:Complete Work Runtime P1 using the accepted dispatcher, guard, and director design`
- Plan: `impl-plans/active/work-runtime-p1-sandbox.md`
- Plan review decision: `accepted_for_step6_implementation`
- Integration review decision: `needs_revision_selective_redispatch`
- Latest Step 7 review decision: `needs_revision` (`comm-000063`, `step7-review-attempt-1-exec-9`)
- Latest test-integrity decisions: `needs_revision` (`comm-000067`, `step6-test-integrity-check-attempt-1-exec-13`; `comm-000070`, `step6-test-integrity-check-attempt-1-exec-16`)
- Selective redispatch communication: `comm-000065`
- Source step execution: `integration-review-attempt-1-exec-12`
- Codex-agent references: `riela-manager`, `step1-issue-intake`, `step2-design-doc-update`, `step3-design-review`, `step4-impl-plan-create`, `step5-impl-plan-review`, `step6-implement:p1-sandbox`, `step6-implement:p1-reservation`, `step6-test-integrity-check:p1-reservation`, `reconcile-implementations`, `integration-review`
- Implementation executions: native fanout branch `p1-sandbox`, runtime step `step6-implement`; original workflow execution `nested-v1-00a6e4662c9fc9db19ba23c476b2f34ef05b33ff99ca8252ce6892ac50633667`; current selective-redispatch workflow execution `nested-v1-72fb58a7978165964dd5bb24d1a19c66c6ee3a330669c93bd5733099baf882ef`

## Completion criteria

- [x] Retained only the canonical `agentSandbox: workspace-write` corrections in Step 6 and Step 8 node payloads.
- [x] Verified the canonical regression asserts intake/review nodes remain read-only and Step 6/Step 8 prompts retain accepted-plan/review boundaries.
- [x] Audited the installed owning package manifest at `/Users/taco/.riela/packages/codex-design-and-implement-review-loop/riela-package.json`; no installed-package file was edited. Serial finalization must refresh the owning source-package digest if these canonical files are packaged from this repository.
- [x] Build passed in a plan-isolated offline scratch path after seeding dependency checkouts from repository-local `tmp/` evidence.
- [x] `ImplementationWorkflowSandboxTests` selected and passed 2 tests.
- [x] Strict touched-file SwiftLint passed.
- [x] `git diff --check` passed on the moving shared tree.
- [ ] Canonical workflow artifact validation remains blocked: isolating `HOME` below the plan evidence root removes the user-home mutable-registry dependency, but validation exits 2 before node validation because the managed sandbox denies the required canonical target lock under `/var/tmp` (`workflow target lock must be a regular non-symbolic-link file`).
- [ ] Independent integrity/adversarial and combined-tree review remain downstream workflow gates.

P1-0 implementation is present and its behavioral regression passes, but this branch does not claim plan acceptance while the required CLI artifact-validation command remains blocked.

## Verification evidence

| Check | Result | Complete log |
| --- | --- | --- |
| Repository SwiftLint baseline | exit 0; existing unrelated warnings only | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-1/logs/swiftlint-baseline.log` |
| Required build, initial | exit 1; user clang module cache denied | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-1/logs/build.log` |
| Build retry | exit 1; nested SwiftPM sandbox denied | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-2/logs/build.log` |
| Offline build retries | exits 1; dependency update/submodule and copied module-cache issues retained for provenance | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-3/logs/build.log`, `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-4/logs/build.log`, `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-5/logs/build.log`, `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-6/logs/build.log` |
| Build, isolated clean offline scratch | exit 0 | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-7/logs/build.log` |
| Focused sandbox tests | exit 0; 2 selected tests, 2 passed, 0 failures | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-7/logs/sandbox-tests.log` |
| Canonical workflow artifact validation | exit 2; blocked before node validation by inaccessible mutable registry state | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-7/logs/workflow-validate.log` |
| Strict touched-file SwiftLint | exit 0 | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-7/logs/touched-swiftlint.log` |
| Shared-tree diff check after progress update | exit 0 | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-8/logs/diff-check.log` |
| Required build, selective redispatch | exit 1; exact command cannot write the default clang module cache | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-9/logs/build.log` |
| Required-scratch build with cache and SwiftPM sandbox accommodations | exit 1; the shared scratch checkout attempted a network-only missing submodule | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-10/logs/build-accommodated.log` |
| Build, plan-isolated clean scratch | exit 0 | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-10/logs/build-clean.log` |
| Focused sandbox tests, selective redispatch | exit 0; 2 selected tests, 2 passed, 0 failures | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-10/logs/sandbox-tests.log` |
| Canonical workflow artifact validation with isolated `HOME` | exit 2; blocked before node validation by denied `/var/tmp` canonical target lock | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-10/logs/workflow-validate-isolated-home.log` |
| Strict touched-file SwiftLint, selective redispatch | exit 0 | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-10/logs/touched-swiftlint.log` |
| Shared-tree diff check after selective-redispatch progress update | exit 0 | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-11/logs/diff-check.log` |
| Required build, current rerun | exit 1; exact command cannot write the default clang module cache | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-12/logs/build.log` |
| Required focused tests, current rerun | exit 1; exact command cannot write the default clang module cache | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-12/logs/sandbox-tests.log` |
| Build with plan-local module cache and SwiftPM sandbox accommodation | exit 0 | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-12/logs/build-accommodated.log` |
| Focused sandbox tests with plan-local module cache and SwiftPM sandbox accommodation | exit 0; 2 selected tests, 2 passed, 0 failures | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-12/logs/sandbox-tests-accommodated.log` |
| Required canonical workflow artifact validation, current rerun | exit 1; exact command cannot write the default clang module cache | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-12/logs/workflow-validate.log` |
| Canonical workflow artifact validation with isolated `HOME` and plan-local caches | exit 2; blocked before node validation by denied `/var/tmp` canonical target lock | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-12/logs/workflow-validate-accommodated.log` |
| Strict touched-file SwiftLint, current rerun | exit 0 | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-12/logs/touched-swiftlint.log` |
| Shared-tree diff check after current progress update | exit 0 | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-12/logs/diff-check.log` |
| Required build, current selective redispatch | exit 1; exact command cannot write the default clang module cache | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-13/logs/build.log` |
| Required focused tests, current selective redispatch | exit 1; exact command cannot write the default clang module cache | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-13/logs/sandbox-tests.log` |
| Build with plan-local module cache and SwiftPM sandbox accommodation, current selective redispatch | exit 0 | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-13/logs/build-accommodated.log` |
| Focused sandbox tests with plan-local module cache and SwiftPM sandbox accommodation, current selective redispatch | exit 0; 2 selected tests, 2 passed, 0 failures | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-13/logs/sandbox-tests-accommodated.log` |
| Required canonical workflow artifact validation, current selective redispatch | exit 1; exact command cannot write the default clang module cache | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-13/logs/workflow-validate.log` |
| Canonical workflow artifact validation with isolated `HOME` and plan-local caches, current selective redispatch | exit 2; blocked before node validation by denied `/var/tmp` canonical target lock | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-13/logs/workflow-validate-accommodated.log` |
| Strict touched-file SwiftLint, current selective redispatch | exit 0 | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-13/logs/touched-swiftlint.log` |
| Shared-tree diff check before current progress update | exit 0 | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-13/logs/diff-check.log` |
| Installed owning-package manifest audit | exit 0; manifest version `0.3.3`, integrity digest recorded, installed package unchanged | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-13/logs/manifest-audit-complete.log` |
| Required build, attempt 14 | exit 1; exact command cannot write the default clang module cache | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-14/logs/build.log` |
| Required focused tests, attempt 14 | exit 1; exact command cannot write the default clang module cache | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-14/logs/sandbox-tests.log` |
| Required canonical workflow artifact validation, attempt 14 | exit 1; exact command cannot write the default clang module cache | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-14/logs/workflow-validate.log` |
| Build with absolute plan-local module cache and SwiftPM sandbox accommodation, attempt 14 | exit 0 | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-14/logs/build-accommodated-absolute.log` |
| Focused sandbox tests with absolute plan-local module cache and SwiftPM sandbox accommodation, attempt 14 | exit 0; 2 selected tests, 2 passed, 0 failures | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-14/logs/sandbox-tests-accommodated-absolute.log` |
| Canonical workflow artifact validation with isolated `HOME` and absolute plan-local caches, attempt 14 | exit 2; executable built, then validation was blocked before node validation by the denied `/var/tmp` canonical target lock | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-14/logs/workflow-validate-accommodated-absolute.log` |
| Strict touched-file SwiftLint, attempt 14 | exit 0 | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-14/logs/touched-swiftlint.log` |
| Shared-tree diff check before attempt-14 progress update | exit 0 | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-14/logs/diff-check.log` |
| Shared-tree diff check after attempt-14 progress update | exit 0 | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-14/logs/diff-check-after-progress.log` |
| Required build, attempt 15 | exit 1; exact command cannot write the default clang module cache | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-15/logs/build.log` |
| Accommodated build, attempt 15 | exit 1; the moving shared tree now requires dependency commit `c7f269753ec36aca92d429ec13316ba033128967`, unavailable in the plan-local offline checkout | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-15/logs/build-accommodated-clean.log` |
| Required focused tests, attempt 15 | exit 1; exact command cannot write the default clang module cache | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-15/logs/sandbox-tests.log` |
| Focused prebuilt XCTest bundle, attempt 15 | exit 0; 2 selected tests, 2 passed, 0 failures; source hashes match the prior successful build | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-15/logs/sandbox-tests-xctest.log` |
| Required canonical workflow artifact validation, attempt 15 | exit 1; exact command cannot write the default clang module cache | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-15/logs/workflow-validate.log` |
| Canonical workflow artifact validation through the prebuilt CLI with isolated `HOME` and `TMPDIR`, attempt 15 | exit 2; blocked before node validation by the hard-coded denied `/var/tmp` canonical target lock | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-15/logs/workflow-validate-direct.log` |
| Strict touched-file SwiftLint, attempt 15 | exit 0 | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-15/logs/touched-swiftlint.log` |
| Installed owning-package manifest audit, attempt 15 | exit 0; version `0.3.3`, SHA-256 integrity digest `1c9e8d0cee5e942d6819c6cc475ebdb51170ed16fb5a2fe271983ef174fdc61f`; installed package unchanged | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-15/logs/manifest-audit.log` |
| Shared-tree diff check after final attempt-15 progress update | exit 0 | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-15/logs/diff-check-after-final-progress.log` |
| Required build with writable plan-local caches, attempt 16 | exit 1; complete log; nested SwiftPM `sandbox-exec` application denied by the managed environment | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-16/logs/build.log` |
| Required focused tests with writable plan-local caches, attempt 16 | exit 1; complete log; failed before test selection because nested SwiftPM `sandbox-exec` application was denied | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-16/logs/sandbox-tests.log` |
| Required canonical workflow artifact validation with writable plan-local caches, attempt 16 | exit 1; complete log; failed before executable launch because nested SwiftPM `sandbox-exec` application was denied | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-16/logs/workflow-validate.log` |
| Strict touched-file SwiftLint, attempt 16 | exit 0 | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-16/logs/touched-swiftlint.log` |
| Shared-tree diff check after final attempt-16 progress update | exit 0 | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-16/logs/diff-check-after-final-progress.log` |
| Required exact build, attempt 17 | exit 1; complete log; default clang module cache is outside writable roots | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-17/logs/build.log` |
| Required exact focused tests, attempt 17 | exit 1; complete log; failed before test selection because the default clang module cache is outside writable roots | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-17/logs/sandbox-tests.log` |
| Required exact canonical workflow artifact validation, attempt 17 | exit 1; complete log; failed before executable launch because the default clang module cache is outside writable roots | `tmp/work-runtime-p1-20260921/p1-sandbox/attempt-17/logs/workflow-validate.log` |

Selected tests:

- `ImplementationWorkflowSandboxTests.testCanonicalAuthoringNodesOwnWritesAndReviewsRemainReadOnly`
- `ImplementationWorkflowSandboxTests.testCanonicalAuthoringPromptsRetainAcceptedReviewBoundaries`

The successful build/test commands add `--disable-sandbox --skip-update`, redirect module caches below `tmp/`, and use `tmp/work-runtime-p1/build/p1-sandbox-clean` because this execution sandbox cannot write the default user caches or resolve dependencies from the network. The product source and package manifest were not changed for that accommodation.

## Author self-check

- Current SHA-256 values for both node payloads and the regression test remain `7d2acf47a1c382c9d66055e4666c96983645ee4157fc5a86e0138adf716831fa`, `6977cb794f588bc04d7f0338d2e67504161fb8d40178c43ea684b6003cd9042c`, and `25db94758e90fce9da1425610f8c3091908899c4ca81c0925f9017fe24110185`; no within-node overwrite was detected.
- The changes remain bounded to P1-0 ownership. No Package.swift, lockfile, shared index, digest, installed package, or other worker progress file was edited.
- No high or mid correctness, security, data-integrity, required-functionality, or severe maintainability finding was found in the retained hunks.
- Unresolved `comm-000063`/`comm-000067`/`comm-000070` mid finding: current-tree build, focused tests, and canonical artifact validation still require rerun in a permissive environment. Attempt-17 exact invocations have complete logs but exit 1 before build, test selection, or executable launch because the default clang module cache is outside writable roots; attempt 16 additionally proves writable plan-local caches still encounter denied nested SwiftPM sandboxing, and earlier direct validation reaches the CLI but exits 2 before node validation on the canonical `/var/tmp` lock. Attempt 18 did not repeat the unchanged commands because the current execution has the same managed permission profile and cannot provide the explicitly requested permissive environment.
