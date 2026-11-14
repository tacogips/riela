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
`pathsFrom` names exact repository-relative file paths, including expected new
or deleted files. Reject traversal, Git metadata and symlink ancestry, directories,
oversized files and excessive snapshots. Defaults limit a snapshot to 512 paths,
8 MB per file and 64 MB total content.

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
