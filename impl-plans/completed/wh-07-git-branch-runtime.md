# wh-07: GitBranchWorkspaceRuntime and `riela/git-publish-branch@1`

```json
{
  "planId": "wh-07-git-branch-runtime",
  "planPath": "impl-plans/active/wh-07-git-branch-runtime.md",
  "wave": "W2",
  "dependsOn": ["wh-01-contracts"],
  "writePaths": [
    "Sources/RielaCLI/GitBranchWorkspaceRuntime.swift",
    "Sources/RielaCLI/ProductionNodeAdapter+GitPublishBranch.swift",
    "Sources/RielaCLI/ProductionNodeAdapter+GitAddons.swift",
    "Tests/RielaCLITests/GitBranchWorkspaceRuntimeTests.swift",
    "Tests/RielaCLITests/GitPublishBranchAddonTests.swift",
    "impl-plans/progress/wh-07-git-branch-runtime.md"
  ],
  "sharedPaths": ["Sources/RielaAddons/RielaAddons.swift"],
  "sharedPathNotes": [
    {"path": "Sources/RielaAddons/RielaAddons.swift", "intendedEdit": "Append `.init(name: \"riela/git-publish-branch\", version: \"1\")` to `gitAddons` only. wh-14 later adds the handover-request descriptor."}
  ],
  "progressLog": "impl-plans/progress/wh-07-git-branch-runtime.md"
}
```

## Intent and context

This plan gives each repository task attempt its own branch `riela/task/<taskId>/g<generation>`, commits
step-boundary checkpoints, publishes the branch (create allowed, never force, only `riela/task/*`), and
materializes it on a successor clone. Design §9.1 and §14 (branch scope), §17 (fence race), §21 R7 and R18.
The protocol `WorkspaceHandoverRuntime` and `PublishedBranch` are pinned in wh-01
(`Sources/RielaWork/HandoverProtocols.swift`).

Non-goals: wiring into task dispatch (wh-14), changing `riela/git-push` or `riela/git-commit`, a finalization journal
for checkpoints (R18), and gc of branches.

## Execution rules

Follow the umbrella common execution contract (hashes and intents in `tmp/work-handover/wh-07-git-branch-runtime/`,
writePaths only, arm64 logs, no git state changes in the **project** repository; tests use temporary
repositories under `tmp/`, never the project repo, and the progress log is this plan's own).

## Deliverables

### `GitBranchWorkspaceRuntime` (`public actor`, conforms to `WorkspaceHandoverRuntime`)

`init(git: any GitCommandRunning = FoundationGitCommandRunner(), environment: [String: String] = …)`. Build
`GitCommandInvocation` as the existing git add-ons do (`ProductionNodeAdapter+GitProcess.swift`), with
`GIT_TERMINAL_PROMPT=0`. Every git failure becomes `GitBranchWorkspaceError` with the command and the stderr head.

- `ensureBranch(root:attempt:task:generation:base:isolation:template:)`: the branch = template with `{taskId}`
  and `{generation}` substituted, validated with `git check-ref-format --branch`. For `.shared`, refuse a dirty
  root (`git status --porcelain=v1 -z` non-empty, excluding `.riela/`), then run `git checkout -B <branch> <base ?? HEAD>`
  only if the branch does not exist; if it exists, check it out. For `.worktree`, run `git worktree add -B <branch>
  <root>/.riela/worktrees/<attemptId> <base ?? HEAD>`. Return an `IsolationRef {path, branch, baseRevision}`
  (the existing type in `WorkContext.swift:67`).
- `checkpoint(_:message:trailer:paths:)`: `git add -A -- <paths or .> ':(exclude).riela'`. If nothing is staged
  (`git diff --cached --quiet` exit 0), return nil. Otherwise run `git commit -m <message> -m <trailer>` and return the new HEAD sha.
  A missing author identity is an error.
- `publish(_:remote:allowCreate:branchAllowlist:)`: the branch must match the allowlist glob. `*` matches any
  characters **including `/`**, so `riela/task/*` matches `riela/task/T1/g2`. Refuse otherwise. Run `git ls-remote --heads
  <remote> <branch>`. If the branch is absent and `allowCreate` is false, refuse. If it is present, run `git fetch <remote> refs/heads/<branch>` and require
  `git merge-base --is-ancestor FETCH_HEAD HEAD`; refuse "behind or diverged" otherwise. Push with
  `git push <remote> HEAD:refs/heads/<branch>` (`--set-upstream` when created). **Never** use `--force` or `+refspec`.
  Return `PublishedBranch {remote, branch, sha, created}`.
- `materialize(_:into:worktree:attempt:)`: `git fetch <remote> refs/heads/<branch>`. For `.published`, require
  `FETCH_HEAD == headCommit` (refuse "remote branch moved"). For `.unpublished(lastKnown)`, start from
  `lastKnown` if `git cat-file -e` finds it, else from `baseRevision`. For `worktree`, run `git worktree add -B <branch>
  <root>/.riela/worktrees/<attemptId> <commit>`. Otherwise refuse a dirty root and run `git checkout -B <branch> <commit>`.
- `dirtyPaths(_:)`: parse `git status --porcelain=v1 -z` (handle rename entries that carry two paths), exclude
  `.riela/`, cap at 512, sort.

### `riela/git-publish-branch@1`

- `BuiltinGitAddon` gains `case publishBranch = "riela/git-publish-branch"`. `executeGitAddon`'s switch routes it
  to `executeGitPublishBranch` (new file). The existing requirement of a runtime-owned execution identity applies
  unchanged.
- Config: `remote` (default `origin`), `branchAllowlist` (default `riela/task/*`), `allowCreateBranch`
  (default true). Unknown config keys → `policyError`. It operates on the current branch of the repository resolved by
  `loadGitRepository()`, as `riela/git-push` does. Detached HEAD → `policyError`.
- Output payload: `{"git": {"operation": "publish", "status": "published" | "up-to-date", "pushedRemote",
  "pushedBranch", "created", "headCommit"}}`. Return `up-to-date` when the remote sha already equals HEAD.
- Workers: `DistributedWorkerNodeExecutor` denies only `riela/git-commit`, `riela/git-push` and
  `riela/workflow-create-register-run`, so publish-branch is allowed with no source change. Prove it with a test (design §9.1).

## Existing code to imitate

`ProductionNodeAdapter+GitPush.swift` (identity guard, `policyError`, repository loading, transport environment);
`GitWorkflowAddonTests` temp-repo fixtures (`GitWorkflowAddonCommandRunnerFixtures.swift`).

## Pitfalls

- A nested worktree under `.riela/worktrees` inside the root must never be staged. That is why the `:(exclude).riela` pathspec is required.
- Tests must not depend on a global git identity. Set `user.name` and `user.email` in each temp repository.
- The allowlist check runs **before** any network or git call. A branch name with `..` or `~` fails `check-ref-format`.

## Tests

`GitBranchWorkspaceRuntimeTests` (temp repo + `git init --bare` remote under `tmp/work-handover/wh-07-git-branch-runtime/`):
- `ensureBranch` shared → on the new branch; shared with a dirty root → refused; worktree → path exists and the branch is checked out there
- two checkpoints → two commits with the trailer; no changes → nil; `.riela/` content not committed
- publish creates the remote branch (`created = true`); a second publish fast-forwards; a remote ahead (commit pushed from a
  second clone) → refused; the branch `main` with allowlist `riela/task/*` → refused before any push
- materialize in a second clone → HEAD equals the published sha; the remote moved → refused; unpublished with lastKnown → HEAD = lastKnown
- `dirtyPaths` lists a modified file and an untracked file, excludes `.riela/`, and caps at 512

`GitPublishBranchAddonTests`: missing execution identity → policy error; allowlist refusal; publish → output
payload fields; up-to-date on repeat; the `DistributedWorkerNodeExecutor` denial predicate does not deny `riela/git-publish-branch`.

## Verification

```
arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-07-git-branch-runtime/build.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-07-git-branch-runtime/build.log'
arch -arm64 /bin/zsh -lc 'swift test --filter "GitBranchWorkspaceRuntimeTests|GitPublishBranchAddonTests|GitWorkflowAddonTests|GitWorkflowAddonContractTests" > tmp/work-handover/wh-07-git-branch-runtime/focused.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-07-git-branch-runtime/focused.log'
git status --porcelain=v1 -uall   # must show only this plan's files plus other plans' in-flight edits; no stray repos
git diff --check
```

The build and tests must end with exit=0 and a non-zero count.

## Done criteria

- [x] The runtime and add-on are implemented; the existing git add-on suites stay green
- [x] Every listed test passes against temp repositories and a bare remote (no network)
- [x] The progress log is complete

**Closure (2026-10-01, Step 8)**: accepted; implemented in `d043cbad` (waves 1-2), acceptance recorded in `7182232d`. Evidence: `impl-plans/progress/wh-07-git-branch-runtime.md`. Archived to `impl-plans/completed/`.
