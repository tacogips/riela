# wh-07: Git branch workspace runtime progress

## Scope and implementation

Implemented the accepted `wh-07-git-branch-runtime` plan only, following the accepted protocol in `Sources/RielaWork/HandoverProtocols.swift` and design §9.1. `GitBranchWorkspaceRuntime` implements shared and worktree branch setup, checkpoint commits, allowlisted publication, published/unpublished materialization, and sorted NUL-status dirty paths capped at 512. Git invocations set `GIT_TERMINAL_PROMPT=0`; Git command failures include the attempted command and a bounded diagnostic. Checkpoints exclude `.riela`, and publication verifies the named isolation branch and captured HEAD before pushing. Pushes use no force option or forced refspec.

Added `riela/git-publish-branch@1` registration and resolver handling. It requires the existing runtime-owned execution identity, rejects unknown config, defaults to `origin`, `riela/task/*`, and branch creation enabled, refuses detached or non-allowlisted branches, rejects behind/diverged remote state, and reports `published` or `up-to-date` with the requested payload fields. The existing `DistributedWorkerNodeExecutor` allowlist policy permits this add-on; the worker test executes it through the executor. The implementation leaves task-dispatch wiring to wh-14 as planned.

Added local temporary-repository and bare-remote tests under `tmp/work-handover/wh-07-git-branch-runtime/repos/`. Coverage includes shared dirty-root refusal, worktree creation, checkpoints and trailer, `.riela` exclusion, empty checkpoint, create/repeat/fast-forward/remote-ahead publication, allowlist refusal before runtime Git calls, second-clone materialization, moved-remote refusal, unpublished `lastKnown`, rename parsing, and modified/untracked path sorting, exclusion, and cap.

Final source SHA-256 values are recorded in `tmp/work-handover/wh-07-git-branch-runtime/final-source-sha256.txt`. Per-edit preimages and intended hunks are retained under `tmp/work-handover/wh-07-git-branch-runtime/attempt-01/`. `Sources/RielaCLI/ProductionNodeAdapter.swift` matches its pre-edit bytes (`path-scope-check.log`); all implementation edits remain in the assigned write paths and stated catalog shared path.

## Verification

- `arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-07-git-branch-runtime/build-final-02.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-07-git-branch-runtime/build-final-02.log'` — exit 0; complete log: `tmp/work-handover/wh-07-git-branch-runtime/build-final-02.log`.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "GitBranchWorkspaceRuntimeTests|GitPublishBranchAddonTests|GitWorkflowAddonTests|GitWorkflowAddonContractTests" > tmp/work-handover/wh-07-git-branch-runtime/focused-final-05.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-07-git-branch-runtime/focused-final-05.log'` — 72 tests, 0 failures, exit 0; complete log: `tmp/work-handover/wh-07-git-branch-runtime/focused-final-05.log`.
- Changed-file strict SwiftLint used `tmp/work-handover/wh-07-git-branch-runtime/changed-swift-files.nul` (six changed Swift files) with `xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/work-handover/wh-07-git-branch-runtime/changed-swift-files.nul` in an arm64 shell — exit 0; complete log: `tmp/work-handover/wh-07-git-branch-runtime/swiftlint-final-04.log`.
- `git status --porcelain=v1 -uall` — exit 0; final capture: `tmp/work-handover/wh-07-git-branch-runtime/status-final-current.log`. It contains this plan's files and other active fanout plans' in-flight files.
- `git diff --check` — exit 0; final log: `tmp/work-handover/wh-07-git-branch-runtime/diff-check-final-current.log`.
- `shasum -a 256 -c tmp/work-handover/wh-07-git-branch-runtime/final-source-sha256.txt` — exit 0; all six final source/test hashes match `source-hash-check-final.log`.

Earlier verification attempts are retained and resolved by the final source-matched gates: initial build lacked `RielaWork` imports; an intermediate focused compile had a test helper default-argument error; the first add-on run had two incorrect test expectations; and a later dirty-path run asserted a lexically truncated path. These are recorded in `build.log`, `focused.log`, `focused-attempt-02.log`, and `focused-final-03.log`; the fixes are covered by the passing build, focused suite, and SwiftLint logs above.

## Completion criteria

- [x] `GitBranchWorkspaceRuntime` and `riela/git-publish-branch@1` implemented; existing git add-on suites pass (72 tests, 0 failures).
- [x] Required temporary-repository and bare-remote behaviors pass; build, focused tests, selected-file SwiftLint, and diff check exit 0.
- [x] Plan-local progress and complete verification logs recorded.

Implementation is ready for downstream test-integrity, adversarial, and serial integration review. Those formal review, any review-dependent index/documentation updates, and commit/push steps belong to later workflow steps and are not claimed here.

## Step 7 adversarial self-repair

- Finding (mid): `GitBranchWorkspaceRuntime.checkpoint` ran `git add -A` / `git commit` without confirming HEAD was still on the attempt's isolation branch, so in `.shared` isolation a step that ran `git checkout main` would have the next checkpoint (with its `Riela-Checkpoint` trailer) committed onto the operator's branch.
- Fix: after the message/trailer guard and before `git add`, `checkpoint` now throws `GitBranchWorkspaceError` when `isolation.branch` is nil/empty and otherwise calls the existing `requireCurrentIsolationBranch(branch, head: nil, root:)` (throws for detached HEAD or a different branch), mirroring `publish`.
- Test: `GitBranchWorkspaceRuntimeTests.testCheckpointRefusesWhenHeadLeftIsolationBranch` (ensureBranch in `.shared`, checkout `main`, dirty file, checkpoint must throw; `main` HEAD, isolation branch tip and index unchanged).
- Verification logs: `tmp/work-handover/wh-07-git-branch-runtime/step7-review/focused.log` (73 tests, 0 failures, exit=0) and `swiftlint.log` (exit=0).
