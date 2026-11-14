# Post-Merge Adversarial Review for PR #48 and PR #49

Status: design, ready for implementation review

Created: 2026-07-13

Issue reference: PR #48; PR #49

Workflow mode: issue-resolution

## Scope

This design covers one work package: post-merge adversarial review and
minimal hardening of the Swift changes merged by:

- PR #48 (`a503b16..14274b5`): loop convergence, loop evidence and stats,
  workflow history canonical coding, and sleep-node execution semantics.
- PR #49 (`14274b5..b5808b3`): Riela Note adversarial-review fixes across
  note storage, dispatch, GraphQL documents, and note UI view models.

The implementation step must treat both PR references as issue references for
one review package. Feature fanout is out of scope.

## Behavior Contract

The review is evidence-driven. A candidate issue becomes a confirmed finding
only when the reviewer can trace the runtime path to incorrect behavior or
write a failing test that demonstrates the defect. Speculative concerns are
discarded and should not drive code changes.

Confirmed findings are resolved in one of two ways:

- fixed with the smallest behavior change that preserves the merged design
  intent; or
- documented as residual risk when a fix would exceed the requested scope or
  requires a user decision.

Zero confirmed findings is an acceptable outcome when the review evidence and
verification gates are recorded.

## Review Boundaries

PR #48 review boundaries:

- `Sources/RielaCore/LoopConvergenceTracker.swift`
- `Sources/RielaCore/LoopEvidence*.swift`
- `Sources/RielaCore/LoopWorkflowStats.swift`
- `Sources/RielaCore/LoopCostAccumulator.swift`
- `Sources/RielaCore/LoopFindingFingerprint.swift`
- `Sources/RielaCore/LoopRegressionVerdict.swift`
- `Sources/RielaCore/LoopSessionOverview.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner+LoopPolicy.swift`
- `Sources/RielaCore/WorkflowLoopValidation.swift`
- `Sources/RielaCore/SleepNodeExecution.swift`
- `Sources/RielaCore/WorkflowHistoryModels.swift`
- `Sources/RielaCore/WorkflowHistoryCanonicalCoding.swift`
- corresponding tests under `Tests/RielaCoreTests`

PR #49 review boundaries:

- `Sources/RielaNote`
- `Sources/RielaNoteDispatch`
- `Sources/RielaNoteLibSQL`
- `Sources/RielaGraphQL/NoteGraphQLDocumentExecutor*.swift`
- `Sources/RielaGraphQL/NoteGraphQLDocumentInputs*.swift`
- `Sources/RielaGraphQL/NoteGraphQLDocumentParsing*.swift`
- `Sources/RielaGraphQL/NoteGraphQLContracts.swift`
- `Sources/RielaGraphQL/GraphQLNoteSchemaContract.swift`
- `Sources/RielaNoteUI/RielaNoteLibraryViewModel*.swift`
- `Sources/RielaNoteUI/RielaNoteAgentViewModel.swift`
- `Sources/RielaNoteUI/RielaNoteConfigAgentViewModel.swift`
- corresponding tests under `Tests/RielaNoteTests`,
  `Tests/RielaGraphQLTests`, `Tests/RielaNoteUITests`, and
  `Tests/RielaNoteDispatchTests`

Unrelated refactors, documentation churn outside `design-docs/`, and behavior
changes not tied to a confirmed finding are out of scope.

## Validation Focus

Loop convergence and workflow runtime validation:

- repeated-finding fingerprints must not create off-by-one stall decisions;
- evidence replay and projection must be deterministic and ordered;
- regression verdicts and workflow stats must not lose failure or cost
  information;
- workflow history decoding must remain stable for persisted snapshots;
- sleep nodes must preserve duration, cancellation, and resume semantics.

Riela Note validation:

- note schema and file migration changes must preserve persisted data
  expectations;
- auto-action dispatch must preserve retry, lease, and idempotency behavior;
- GraphQL parsing and execution must reject invalid documents consistently and
  preserve strict argument rules;
- note UI view models must guard async pagination, selection, and generation
  updates against stale writes.

## Verification Gates

The implementation step must run these commands in order:

```sh
swift build
swift test --filter LoopConvergence
swift test --filter SleepNodeExecution
swift test --filter WorkflowHistory
swift test --filter RielaNoteTests
swift test --filter NoteGraphQL
swift test --filter RielaNoteUITests
git status --short
git log --oneline -1
```

The targeted test filters are the acceptance surface for this package. A
failed gate blocks completion unless documented as residual risk with the
exact command and failure mode.

## Rollout Constraints

Work must stay inside this repository checkout. Scratch artifacts
belong under repository `tmp/` only. The implementation step must preserve
dirty-worktree safety, make a local branch or snapshot before edits, avoid
reverting user changes, commit locally when the package is complete, and not
push to origin.

No Codex Agent reference repository behavior is required for this package.
There is no Cursor-specific behavior mapping and no adapter divergence to
document.
