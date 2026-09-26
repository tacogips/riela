# Fanout dependency waves and change evidence

## Naming and scope

Use the existing vocabulary: an input **item** creates a **fanout branch**;
branches belong to a **fanout group** and aggregate at a **join step**. A branch
has a child workflow session and may execute several steps and review loops.
Do not introduce `sub task`, `mapTask`, or rename steps. A **Git branch** is a
separate repository concept; many fanout branches may share one Git branch.
Map/reduce describes this execution pattern, not a second scheduling API.

## Authored contract

```json
{
  "toStepId": "implement",
  "fanout": {
    "groupId": "implementation",
    "itemsFrom": "/items",
    "itemVariable": "implementation",
    "concurrency": 4,
    "joinStepId": "reconcile",
    "failurePolicy": "collect-partial",
    "resultOrder": "input",
    "writeOwnership": { "mode": "shared-workspace" },
    "dependencies": {
      "branchIdFrom": "/id",
      "dependsOnFrom": "/dependsOn",
      "completedBranchIdsFrom": "/acceptedIds"
    },
    "changeTracking": { "pathsFrom": "/trackedPaths" }
  }
}
```

`itemsFrom` and `completedBranchIdsFrom` are JSON Pointers into the dispatching
step's accepted payload. The other pointers are relative to each item. Complete
item contracts and stable input ordering are preserved on every dispatch.
`shared-workspace` explicitly means cooperative shared writes, not isolation.
Its new enum value also prevents old runners silently executing the new bundle
while ignoring dependency/change-tracking fields.

## Dependency scheduling and selective retry

Validate all unique branch IDs and the full dependency graph before execution:
unknown IDs, duplicate completion IDs, cycles and accepted branches with missing
accepted dependencies fail. Dispatch only incomplete branches whose dependencies
are accepted. Retain original input indices when skipping accepted/dependent
items. Existing concurrency caps, input-order aggregation and failure policies
apply to the selected wave.

The join returns `branches` with branchId/index/item/status/output/sessionId plus
`dispatchedBranchIds`, `pendingBranchIds`, `completedBranchIds` and
`allBranchesCompleted`. Pending IDs include dispatched candidates until the
reducer independently accepts them. `collect-partial` waits for every branch and
delivers failed records too. The reducer can accept successes and redispatch the
same complete item set with accepted IDs, retrying only pending work. Persist
accepted IDs in ordinary workflow output/session artifacts; do not infer
completion from the existence of edited files. This is explicit workflow-driven
recovery, not a claim of transactional exactly-once agent execution after a crash.

## Native change evidence

The host binds `DeterministicWorkflowRunner.fanoutWorkspaceRoot` to the actual
execution directory. The CLI supplies its resolved working directory; library
hosts opt in explicitly. No workflow-authored root can redirect snapshots.
`pathsFrom` names explicit repository-relative file or directory paths, including
expected new or deleted paths. Directories recursively include their descendants;
these are bounded selections, not globs or permission to scan the workspace.
Reject traversal, Git metadata, symlink ancestry and entries, special files,
oversized files and excessive snapshots. Limits remain 512 declared paths,
512 unique expanded entries, 8 MB per file and 64 MB total content. Directory
and missing entries count toward the expanded-entry limit; overlapping selections
count each repository-relative entry and its file bytes only once.

Preflight every selected branch's paths before starting any writer. Capture
before and after each workflow node (including called workflow nodes), preserving
observed bytes, SHA256 and mode in unique private files under workspace
`tmp/riela-fanout/<generated-id>`. `fanoutBranchId` and
`fanoutChangeEvidencePath` expose stable identity and the latest artifact to
workers. Original evidence is never replaced by a later attempt.

The join's `changeEvidence` contains artifactPaths, observations, hasDrift,
requiresSemanticReview and observationBoundary. Compare observed states with the
stable final tree after every branch stops. Do not include source bytes in the
joined output or diagnose hash drift as confirmed data loss. Keep source-bearing
artifacts private and untracked.

Snapshots observe cooperative workers at node boundaries. They are not an OS
filesystem watcher, write lock, or proof that transient overwrites within an
agent invocation were observed. Workers must still reread before contextual
edits, preserve intentions, and never discard concurrent changes. The serial
repair step combines intentions; independent review and combined acceptance
tests prove behavior survives. Generic Riela does not resolve semantic conflicts.

## Registry migration

Codex design and plan authors remain single nodes (Astra). Implementation uses
SOL, branch implementation/integrity/adversarial review uses Terra, combined
design/implementation consistency uses Astra, other Codex steps use SOL.
Preserve existing Claude/Fable models. Commit accepted plans once before native
fanout. Reconcile and review between dependency waves; serialize final Git
commit/push/base integration. Python remains only for plan-specific Markdown
assessment/archival, not generic fanout evidence or scheduling.

## Verification

Engine tests cover ordering/concurrency, failure policies, DAG waves, incomplete
dependencies, overwritten bytes, new/deleted states, symlink/path rejection and
protected finalization evidence. Registry mock runs cover multiple branches,
planning-only, branch review revisions and serial overwrite repair. Live model
quality, crash recovery across external edits and remote Git policies remain
separate integration concerns and are not established by mocks.

## Issue #118: bounded directory snapshots

Source of truth: Step 1 intake for
<https://github.com/tacogips/riela/issues/118>, mode `issue-resolution`, and the
effective workflow input. The reported failure is an explicit directory
`writePaths` selection rejected after the first dependency wave. `writePaths`
is an item field selected by `changeTracking.pathsFrom`; no new schema or
scheduler behavior is required. Implementation is limited to
`Sources/RielaCore/WorkflowFanoutChangeEvidence.swift` and focused tests in
`Tests/RielaCoreTests/WorkflowFanoutMapReduceTests.swift`.

### Snapshot and reduce contract

- Retain each capture's original declared roots alongside its expanded `files`
  map in the private evidence record. Capture roots before dispatch and at the
  existing node boundaries. Preserve immutable artifacts, file bytes, hashes,
  modes, branch/step attribution and the existing join envelope.
- Walk directories in deterministic repository-relative order, including hidden
  entries and empty directories. Record directory kind, mode and sorted immediate
  child names, regular-file state in the existing format, and explicit missing
  roots. Do not synthesize missing descendants during enumeration.
- A missing root can become a file or directory in a later capture or wave.
  File/directory replacement, removal of an entire directory and empty-directory
  membership changes must remain observable. A later wave snapshots its current
  roots; it does not reuse an earlier wave's expansion or imply cross-wave
  persistence of the actor's records.
- Reduce re-enumerates each record's declared roots after workers stop and
  compares the sorted union of recorded and current entry keys. Absence on one
  side differs from presence on the other. Emit observations for newly added
  and removed files as well as changed content, mode, kind or directory
  membership. Preserve the existing `content-or-mode-drift` reason for regular
  file-state changes; use `directory-membership-drift` for changed directory
  child lists and `entry-added`, `entry-removed`, or `entry-kind-drift` for those
  cases. Prefer added/removed, then kind, then membership, then content/mode
  when more than one description applies to an entry. Keep `hasDrift` derived
  from observations and `requiresSemanticReview: true`.

### Safety and limits

Validate every declared and discovered path using the existing relative-path
rules. Reject any symlink, including dangling links and symlink ancestors,
`.git` entries, traversal, non-regular/non-directory entries and unreadable
entries. Enumeration errors fail the capture; never skip hidden or unsafe
entries. Only genuine absence of a declared root is a missing state. Reject
selections containing the actor's evidence directory so capture cannot recursively
observe its own artifacts. This needs no blanket exclusion of other `tmp/` data.

Enforce 1...512 declared paths before deduplication, at most 512 unique expanded
entries (including selected directories and missing roots), 8,000,000 bytes per
regular file and 64,000,000 aggregate regular-file bytes per snapshot. Apply the
same limits in preflight, node captures and reduce; reaching a limit is allowed,
exceeding it fails without publishing a partial record. Enforce entry limits
during traversal and byte limits before content loading and against actual bytes
read. Overlapping roots must not bypass bounds or double-charge content.

Retain before/after file identity, size and modification checks and recheck file
type, mode and symlink safety. Recheck directory identity and sorted membership
after reading descendants; detected disappearance, replacement or mutation
during traversal fails with a retryable snapshot error. Unsafe paths remain
policy failures. These checks preserve the cooperative node-boundary model;
they do not promise an atomic filesystem view or eliminate transient races.

### Acceptance and verification handoff

Focused tests must cover stable nested directories, hidden files, empty
directories, overlapping roots, missing-root creation, file/directory replacement,
new and removed descendants, directory removal, overwritten bytes and mode drift.
Exercise two dependency waves using a directory created/populated in the first
wave and snapshotted again for the second, then assert reduce observations by
path and branch. Preserve existing ordering, acceptance and exact-file tests.
Test traversal, direct/ancestor/dangling symlinks, discovered `.git` and special
entries, enumeration failures, and detected concurrent mutation without relying
on timing-only success. Test inclusive and exceeded entry, per-file and aggregate
limits, including over-limit growth first seen at reduce.

The intake reports a 60-path/407-file package plan but supplies no manifest or
fixture path. Add a deterministic fixture with 60 declared paths and 407 unique
regular files, with explicit directory and overlap counts that keep total
expanded entries within 512. Verify capture, a subsequent wave and reduce drift
for added/removed descendants. Record the fixture's actual counts. This proves
the reported scale; it must not be described as replaying the original package
plan. If the original manifest is supplied downstream, replay it locally within
the same limits and record its identity; do not rediscover workflow registries.

Implementation verification commands, run in the foreground with complete logs
and terminal exit codes under repository `tmp/issue-118/`, are:

```sh
swift test --filter WorkflowFanoutMapReduceTests
swift test --filter DeterministicWorkflowRunnerFanoutTests
swiftlint lint --strict --path Sources/RielaCore/WorkflowFanoutChangeEvidence.swift
swiftlint lint --strict --path Tests/RielaCoreTests/WorkflowFanoutMapReduceTests.swift
swift build
git diff --check
```

Use the installed SwiftLint's equivalent file-selection syntax if `--path` is
unsupported and record the exact executed command. These are downstream gates,
not passing results from this design-only step. Self-review and the required
independent adversarial review precede final commit and non-force push on
`fix/fanout-directory-change-tracking`; do not release, merge or write sibling
worktrees. No workflow, prompt, script, skill or package-manifest change is needed.

### Open questions and reference mapping

No unresolved user design decisions. The original 60-path/407-file manifest is
an evidence limitation, not a design or workflow-readiness blocker. The issue
title/body were unavailable at intake, so this section uses the supplied brief.
No codex-agent references or Cursor CLI behavior were supplied; no adapter
mapping or intentional reference divergence applies. No Step 3 or Step 5 review
feedback was supplied to this execution.
