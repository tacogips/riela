# Design: riela/git-commit rename guard (HEAD-aware tracked-deletion check)

Status: accepted (fable-and-improve-opus, 2026-09-21; revised same day on the
resumed run to record the `stagedPaths --no-renames` companion change)
Branch: fix/git-commit-rename-guard (base == implementation branch)

## Problem

`validateCommitPaths` (Sources/RielaCLI/ProductionNodeAdapter+GitRepository.swift:294-315)
handles a committedFiles entry that is missing from the working tree by running
`ls-files --error-unmatch -- <path>` and refusing on nonzero exit with
`riela/git-commit missing path is not an exact tracked deletion`. `ls-files`
reads only the INDEX. After `git mv old new`, `old` is already removed from the
index while still tracked in HEAD, so the legitimate deletion-half of a staged
rename is refused and the workflow dies at its commit step.

The rest of the commit pipeline is already rename-safe (verified):

- ProductionNodeAdapter+GitCommit.swift:67-72 — pre-staged real-index paths must
  be allowlisted in committedFiles; a `git mv` pair (old:D, new:A) passes when
  both paths are supplied.
- GitCommit.swift:75 — the attempt index copies the real index.
- GitRepository.swift:380-385 — `stageCommitPaths` answers a missing path with
  `update-index --remove -- <path>` (idempotent for the already-removed old path).
- GitCommit.swift:84-85 — `requireExactStagedPaths` compares the attempt-index
  `diff --cached` set ({old:D, new:A}) with committedFiles exactly.

Only the guard blocks the scenario.

## Decision

In the `.missing` branch of `validateCommitPaths`, when
`ls-files --error-unmatch` exits nonzero, additionally probe HEAD membership:

```swift
case .missing:
  let tracked = try runRepositoryGitResult(
    ["ls-files", "--error-unmatch", "--", path],
    repository: repository
  )
  if tracked.exitCode != 0 {
    let inHead = try runRepositoryGitResult(
      ["cat-file", "-e", "HEAD:\(path)"],
      repository: repository
    )
    guard inHead.exitCode == 0 else {
      throw policyError("riela/git-commit missing path is not an exact tracked deletion")
    }
  }
```

A missing path is accepted iff it is tracked in the index OR in HEAD; a path
absent from all three of working tree, index and HEAD keeps the identical
policy error. No new flags, no opt-out, no message change.

### Why `cat-file -e HEAD:<path>`

- Runs through `runRepositoryGitResult` (GitRepository.swift:253-265), which
  pins `--git-dir`/`--work-tree` to the preflighted repository context and
  returns nonzero exits without throwing — satisfying the pinning constraint
  and giving unborn-HEAD safety for free: when HEAD does not resolve (no
  commits yet), git exits nonzero, the guard refuses, nothing crashes.
- The rev spec embeds the path after `HEAD:`, so the argument never starts
  with `-` (no option injection even though `cat-file -e` takes no `--`
  path separator). `validateRepositoryRelativePath` (GitRepository.swift:317-329)
  already bans NUL/LF/CR, empty/`.`/`..` segments and a leading `:`; the
  `<rev>:<path>` form treats the path literally (no pathspec magic).

### Companion change: `stagedPaths` must not collapse the rename pair

Implementation surfaced a second blocker the original draft missed: git enables
rename detection by default (`diff.renames`), so the attempt-index
`diff --cached --name-only` that feeds `requireExactStagedPaths`
(GitCommit.swift:84-85) can collapse the staged `git mv` pair into a single
rename entry instead of reporting the literal {old:D, new:A} set. The exactness
check would then refuse the very committedFiles pair the guard now accepts.

Decision: pin the staged-set read to literal semantics —

```swift
// stagedPaths (GitRepository.swift): rename detection would collapse a
// `git mv` pair into the destination path alone and hide the allowlisted
// deletion of the old path.
["diff", "--cached", "--name-only", "--no-renames", "-z", "--"]
```

Blast radius is contained by construction: `stagedPaths` has exactly two
callers, both inside the git-commit pipeline — the pre-staged allowlist check
(GitCommit.swift:67) and `requireExactStagedPaths` (GitCommit.swift:84). Both
want the literal per-path set; a user-staged rename now surfaces both paths and
both must be allowlisted, which is exactly the requested committedFiles
semantics. No allowlist widening: the reported set can only get more explicit,
never smaller, so every existing refusal is preserved or strengthened.

### Alternatives considered

1. `ls-tree -z HEAD -- <path>` + non-empty-output check — equivalent
   semantics but needs output parsing and errors differently on unborn HEAD;
   more code for no additional safety. Rejected.
2. `rev-parse --verify HEAD^{commit}` pre-check before the probe — clearer
   intent but an extra process per missing path; `cat-file -e` already fails
   closed on unborn HEAD. Rejected.
3. Requiring the HEAD object to be a blob (`cat-file -t == blob`) to exclude
   tree paths — unnecessary: a committedFiles entry naming a HEAD directory is
   accepted by the probe but produces no `update-index --remove` effect, so
   `requireExactStagedPaths` refuses the staged-set mismatch downstream.
   Defense in depth is preserved with less code. Rejected.

## Security / compatibility analysis

- Newly accepted class is exactly index-absent-but-HEAD-present, i.e. a
  deletion staged earlier (`git mv`, `git rm --cached`). Committing it removes
  the path from the tree — precisely the deletion semantics committedFiles
  allowlists. Exactness is still enforced by `requireExactStagedPaths`.
- Untouched: `validateRepositoryRelativePath`, the repository-escape check,
  `rejectCustomCleanFilters` (still runs on every path), pre-staged allowlist
  semantics, finalization journal, all other refusals.
- Unborn HEAD: probe exits nonzero → same refusal as today, no crash. The
  commit pipeline itself always requires a resolvable parent
  (`headRevision`, GitRepository.swift:431-437; `commit-tree -p`,
  GitCommit.swift:106), so behaviour beyond the guard is unchanged.
- NO backward-compatibility shims (per constraints): the check changes in place.

## Data flow / state transitions

validateCommitPaths runs read-only before any index mutation
(GitCommit.swift:60, before the canonical index read at :62). A refusal leaves
HEAD, the real index and the finalization store untouched — existing tests
assert this pattern and the new refusal tests re-assert it.

## Test design (Tests/RielaCLITests/GitWorkflowAddonContractTests.swift)

Fixture facts: `GitTestRepository` (Tests/RielaCLITests/GitWorkflowAddonTests.swift:729)
commits `tracked.txt` on `main` in init. `loadGitRepository` requires the index
file to be an existing single-link regular file (regularPathEntryIdentity), so
an unborn-HEAD fixture must `git add` something to create the index before the
add-on runs. `git show --name-status` may auto-detect renames (R100), so tree
assertions use `ls-tree`/`rev-parse`, not diff output.

1. `testCommitSupportsStagedRenameAcrossOldAndNewPaths` (end to end):
   `git mv tracked.txt renamed.txt`; execute git-commit with
   files ["tracked.txt", "renamed.txt"]; assert status "committed", one new
   commit (`rev-parse HEAD^` == pre-rename HEAD), tree drops the old path and
   carries the new one (`ls-tree --name-only HEAD` == "renamed.txt"), content
   preserved (`show HEAD:renamed.txt` == "initial").
2. `testCommitRejectsMissingPathAbsentFromIndexAndHead`: files ["ghost.txt"]
   (never existed); assert AdapterExecutionError.code == .policyBlocked, HEAD
   and index bytes unchanged, no finalization journals (pattern of
   ContractTests.swift:52-69).
3. `testCommitRejectsMissingPathOnUnbornHeadWithoutCrashing`:
   `GitTestRepository(commitInitialFile: false)` — new default-true init
   parameter that writes and `git add`s tracked.txt but skips the initial
   commit (index exists, HEAD unborn). Execute git-commit with
   files ["ghost.txt"]; assert .policyBlocked (guard refusal reached, no
   crash), repository still has zero commits (`rev-list --all --count` == "0"),
   no journals.
4. Regression kept: `testCommitSupportsExactTrackedDeletion`
   (ContractTests.swift:32) — plain tracked deletion (gone from working tree,
   still in index) — must stay green, plus every existing refusal in the
   contract suite.

## Rollout

Single work package on fix/git-commit-rename-guard; commit and push that
branch only. No config, schema or docs-site changes. Design + plan artifacts:
this file and design-docs/specs/impl-plan-git-commit-rename-guard.md.
