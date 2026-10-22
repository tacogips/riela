# pog-04-failure-kind-consumers implementation progress

Workflow mode: issue-resolution, native fanout branch `pog-04-failure-kind-consumers` (wave 2).
Issue reference: none (GitHub issue); incident: opus-luna-design-and-implement-review-loop 0.1.8 session-471.
Plan: `impl-plans/active/prompt-overflow-guard-04-failure-kind-consumers.md`.
Dependency readiness: `pog-01-contracts` is present in runtime-owned acceptedPlanIds. The accepted Part D design states `promptTooLarge` inherits adapterFailure recovery at all four gates without introducing a new route or rule.

## Implementation

- `Sources/RielaCore/DeterministicWorkflowRunner+Recovery.swift`: `retryableFailureKind` accepts `.promptTooLarge`; retry validation message names `adapter-failed, prompt-too-large or policy-blocked`.
- `Sources/RielaCLI/SessionCommands.swift`: `nonBudgetFailureResumeMessage(session:)` is internal and includes retry guidance for `.promptTooLarge`.
- `Sources/RielaWork/DeterministicDirector.swift`: `.promptTooLarge` follows `.adapterFailure` only under `rerunOnAdapterFailure`; node-timeout logic is unchanged.
- `Sources/RielaWork/TaskGuardCoordinator.swift`: attempts-budget accounting treats `.promptTooLarge` like `.adapterFailure`; node-timeout logic is unchanged.
- Added `PromptTooLargeRecoveryTests`, `PromptTooLargeResumeMessageTests`, and `PromptTooLargeRerunTests`. Coverage includes real runner classification/retry history, maxStepsExceeded rejection and diagnostic, CLI guidance, director setting on/off, and exhausted attempts budget.

## Per-edit SHA-256

| Path | Pre-edit SHA-256 | Final SHA-256 |
| --- | --- | --- |
| `Sources/RielaCore/DeterministicWorkflowRunner+Recovery.swift` | `e24d43395e195b46ae9e11f32a10aa3d56e16db95ea5396222f52ffb0cb8638a` | `9dcc211db184360b6af173e9bc28bdae4ad418b1722df00bbba9ddd5de72776b` |
| `Sources/RielaCLI/SessionCommands.swift` | `71ef8f889a9c7dd1e1f23e69d6d4c1eb8f7ab2b4f1c1867a00d815b0b3d55fce` | `8f072dc9ccdf285cb1a4f851fb858eb7b5a529ae01fafe4e7fb8a78f98f34f7e` |
| `Sources/RielaWork/DeterministicDirector.swift` | `e49cf7e8ac3d448e650f513a17e6c9a09acd397ca09050edd7f3a91dfcce6b95` | `5c79fbd650556aae8b24e36ce3755273c4fb74fbe8f877cd60995ade979d84ea` |
| `Sources/RielaWork/TaskGuardCoordinator.swift` | `51271d3d8d23ec062c6939bb1e5ae301ea0dc38f8dded864efc1a9244cd2957a` | `12ef87a34f71c0e1925151f631cd47a3e40b71079e53be8ae28466977761cbb3` |
| `Tests/RielaCoreTests/PromptTooLargeRecoveryTests.swift` | New file; edit sequence recorded in `tmp/prompt-overflow/pog-04-failure-kind-consumers/edit-intentions-02.md`, `-03.md`, `-05.md`, `-06.md`, `-07.md`, and `-08.md` with each pre-edit hash | `0ac2e037fa664574a0c86de91909c025e5b54345af9d2a302df4e4f32bf64f20` |
| `Tests/RielaCLITests/PromptTooLargeResumeMessageTests.swift` | New file; initial edit recorded in `edit-intentions-02.md`; later API correction pre-hash `1b2ac1d5078729556d554fbd95919aa3d6e435570d68c16eb90e2797b76f3ac8` | `6ce02cb398013d07630f5b99f9a15a46a94d5fac63667a506be9a297da978d8d` |
| `Tests/RielaWorkTests/PromptTooLargeRerunTests.swift` | New file; initial edit recorded in `edit-intentions-02.md` | `2b019094ea29a7e4aa4fa4ba81e431a01a741d5228aee9eccb84fc77f353ded3` |

Source edit intent: `tmp/prompt-overflow/pog-04-failure-kind-consumers/edit-intentions-01.md`. Later test/API repairs each have a plan-local intention file numbered 02–08. Changed Swift file selection is recorded as a NUL-delimited manifest at `tmp/prompt-overflow/pog-04-failure-kind-consumers/changed-swift-files.nul`.

## Verification

| Command | Exit | Result / log |
| --- | ---: | --- |
| `arch -arm64 /bin/zsh -lc 'swift build'` | 0 | Build complete; `tmp/prompt-overflow/pog-04-failure-kind-consumers/build.log`. Existing compiler warnings came from untouched files. |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "PromptTooLargeRecoveryTests|PromptTooLargeResumeMessageTests|PromptTooLargeRerunTests|DeterministicDirectorTests|WorkGuardDispatcherTests|DeterministicWorkflowRunnerTests"'` | 0 | Final source run: 69 tests, 0 failures; `tmp/prompt-overflow/pog-04-failure-kind-consumers/test-final-02.log`. |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "PromptTooLargeRecoveryTests"'` | 0 | Recovery suite: 2 tests, 0 failures; `tmp/prompt-overflow/pog-04-failure-kind-consumers/recovery-final.log`. |
| `arch -arm64 /bin/zsh -lc 'changed_swift_manifest=tmp/prompt-overflow/pog-04-failure-kind-consumers/changed-swift-files.nul; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\\n" "No Swift files changed; selected-file SwiftLint not run."; fi'` | 0 | Strict changed-file lint passed; `tmp/prompt-overflow/pog-04-failure-kind-consumers/lint-final.log`. |
| `grep -rn 'promptTooLarge' Sources/RielaCore/DeterministicWorkflowRunner+Recovery.swift Sources/RielaCLI/SessionCommands.swift Sources/RielaWork/DeterministicDirector.swift Sources/RielaWork/TaskGuardCoordinator.swift` | 0 | Four hits, one in each consumer; `tmp/prompt-overflow/pog-04-failure-kind-consumers/grep.log`. |
| `git diff --check` | 0 | No whitespace errors. |

Earlier attempts were preserved, not overwritten:
- `test.log` exit 1: initial test implementation had compile errors (async `XCTUnwrap`, nonexistent request session ID); the same compilation also surfaced transient pog-02 test diagnostics in the concurrently changing shared tree.
- `test-rerun-02.log` exit 1: remaining CLI test called the helper on the wrong type and prior recovery fixture API errors.
- `test-rerun-03.log` exit 1: test modules compiled; both recovery cases looked up a nonexistent session identity (69 tests, 2 failures).
- `recovery-rerun-04.log` exit 1: prompt-too-large retry passed, maxStepsExceeded fixture did not persist a session (2 tests, 1 failure).
- `recovery-final.log` exit 0 and `test-final-02.log` exit 0 resolve those failures on current source. The final full focused filter passed 69 tests with 0 failures.

## Completion criteria

- [x] All four recovery gates accept `.promptTooLarge` with unchanged policyBlocked/nodeTimeout handling.
- [x] Recovery validation diagnostic uses the requested phrase.
- [x] All three new focused suites pass, alongside the prescribed existing suites.
- [x] arm64 build, focused tests, changed-file strict lint, grep (4 hits), and diff check pass.
- [x] Pre-edit/final hashes and complete logs are recorded.

Formal test-integrity/adversarial/integration review, review-dependent shared documentation/index changes, staging, commit, and push remain downstream workflow steps. No review decision is claimed here.
