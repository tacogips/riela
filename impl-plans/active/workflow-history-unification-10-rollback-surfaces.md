# whu-10-rollback-surfaces: CLI `workflow definition rollback check|list|approve|reject`, GraphQL rollback provider, restore CAS input

```json
{
  "planId": "whu-10-rollback-surfaces",
  "planPath": "impl-plans/active/workflow-history-unification-10-rollback-surfaces.md",
  "dependsOn": [],
  "wave": 5,
  "writePaths": [
    "Sources/RielaCLI",
    "Tests/RielaCLITests/WorkflowRollbackCommandTests.swift",
    "Tests/RielaCLITests/WorkflowRollbackGraphQLTests.swift",
    "Sources/RielaCore/LoopEngineeringModels.swift",
    "Sources/RielaCore/LoopRegressionVerdict.swift",
    "Sources/RielaCore/WorkflowLoopValidation.swift",
    "Sources/RielaCore/WorkflowRollbackProposalStore.swift",
    "Sources/RielaGraphQL/GraphQLSchemaGenerator.swift",
    "Sources/RielaGraphQL/GraphQLVariableValidation.swift",
    "Sources/RielaGraphQL/WorkflowDefinitionGraphQL.swift",
    "Sources/RielaGraphQL/WorkflowHistoryGraphQLContracts.swift",
    "Tests/RielaCoreTests/WorkflowRollbackProposalStoreTests.swift",
    "Tests/RielaGraphQLTests/WorkflowHistoryGraphQLContractTests.swift",
    "Tests/RielaCLITests/WorkflowDefinitionCommandTests.swift",
    "Tests/RielaCLITests/WorkflowDefinitionGraphQLTests.swift",
    "impl-plans/progress/whu-10-rollback-surfaces.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

Design §5.5 and §6. Approve and reject are available on both the CLI and
GraphQL, along with check and list, with closed error codes.

The GraphQL `restoreWorkflowDefinition` also honors the new optional
`expectedVersionId`. This is the design §7 CAS that the web screen sends:
whu-03 added the input field and whu-05 added the service parameter. This
plan depends on whu-09 only to serialize edits to
`WorkflowDefinitionGraphQLProvider.swift`. Follow the execution protocol in
the index plan.

Code:

- **CLI.**
  - `WorkflowDefinitionCommandOperation` (`WorkflowDefinitionArguments.swift:12-25`)
    is table-driven, with value and flag sets (`:32-40`) and per-operation
    allowed options (`:141-192`).
  - `RielaClientFamilyArguments.swift:79-84` holds the parallel enum used
    by the client-family parser. Keep the two in sync.
  - Command execution: `WorkflowDefinitionCommand.swift`, for example the
    `.purgeHistory` case at `:285`. Text/JSON output follows existing
    `--output` handling.
- **GraphQL.** Error mapping is at `WorkflowDefinitionGraphQLProvider.swift:280-300`
  (`.definitionConflict`/`.staleHead` → `DEFINITION_STALE`). The restore
  method calls `WorkflowDefinitionService.restore`. whu-09 already made the
  stored properties internal.
- **whu-08.** `WorkflowRegressionRollbackService` and its error codes.

## Non-goals

- No service logic; whu-08 owns it.
- No catalog rows, help text or SDL; whu-11 owns those.

## CLI contract

```
riela workflow definition rollback check   <workflow> [--session <id>]
riela workflow definition rollback list    <workflow> [--status recorded|pending|applying|applied|rejected|superseded|failed] [--limit <n>]
riela workflow definition rollback approve <workflow> --proposal <id> [--reason <r>] [--actor <id>]
riela workflow definition rollback reject  <workflow> --proposal <id> --reason <r> [--actor <id>]
common: [--session-store <dir>] [--scope project|user|auto] [--output text|json]
```

- Add `case rollback` to both enums. The token after `rollback` is the
  action (`check|list|approve|reject`), followed by `<workflow>`. A missing
  or unknown action is a usage error naming the four actions.
- New value options: `--session`, `--status`, `--proposal`.
- Actor: `cli`, id `--actor` or the OS user. `--actor-kind` is not accepted
  for rollback.
- Exit codes:
  - 0 on success, including `check` outcomes `noBaseline`,
    `noRegression`, `notEligible`, `existing` and `proposed`;
  - usage errors (missing `--proposal`, blank `--reason` on reject, an
    invalid `--status`) use the existing usage exit code;
  - service errors exit non-zero with the closed snake-case code first on
    stderr, and in JSON as `{"error": {"code": …, "message": …}}`,
    imitating existing definition command errors.
- Text output, one line per proposal:
  `<proposalId> <status> <policy> <regressedVersionId>-><rollbackToVersionId> <mode>`.
  For check: `outcome=<…> [eligibility=<…>] [proposal=<id> status=<…>]`.

## GraphQL rollback provider (`WorkflowDefinitionGraphQLProvider+Rollback.swift`)

- Implement `workflowRollbackProposals`, `checkWorkflowRegressionRollback`,
  `approveWorkflowRollbackProposal` and `rejectWorkflowRollbackProposal`
  over `WorkflowRegressionRollbackService(workingDirectory:,
  sessionStore: sessionStoreRoot, scope: storeScope ?? auto, environment:)`.
- Actor: `actorKind` must be `user` or `api` (default `api`). Both
  `improvementNode` and `system` → `INVALID_DEFINITION_INPUT`.
- Error mapping: snake code → upper snake. `rollback_snapshot_unavailable`
  and other apply failures → `ROLLBACK_FAILED`, with the original code in
  the message prefix.
- DTO mapping: dates as ISO-8601, `policy` as its raw value, `status` as
  the case name.

## Restore CAS (`WorkflowDefinitionGraphQLProvider.swift`)

The `restoreWorkflowDefinition` provider passes `input.expectedVersionId`
to `WorkflowDefinitionService.restore(expectedVersionId:)`. A mismatch
maps through the existing `.definitionConflict` → `DEFINITION_STALE`.
Nothing else in this file changes.

## Pitfalls

- Keep the two subcommand enums in sync, or the client-family parser
  rejects `rollback`.
- `reject` without `--reason` must be a usage error before any store
  access.
- Never call `approve` from `list` or `check` paths.

## Tests

`WorkflowRollbackCommandTests` (in-process `RielaCLIApplication`; reuse
whu-08's fixture helpers by copying the minimal setup, never by importing
test files across plans):

- `rollback check` → JSON outcome `proposed` with the proposal.
- `rollback list --status pending` → contains it.
- `rollback approve --proposal <id> --reason r` → the status is `applied`,
  and `workflow definition history` shows operation `rollback` with the
  reason containing `approved: r`.
- `rollback reject` without `--reason` → usage exit, nothing changed.
- `rollback approve` on a recorded (manual) proposal → non-zero exit,
  stderr starts with `rollback_proposal_not_pending`.
- `rollback frobnicate` → usage error listing the actions.

`WorkflowRollbackGraphQLTests` (through the document executor):

- The same four operations, with results matching the CLI JSON for the
  same fixture (parity).
- `actorKind: "system"` → `INVALID_DEFINITION_INPUT`.
- Approve after the head moved → `ROLLBACK_SUPERSEDED`.
- `restoreWorkflowDefinition(expectedVersionId: <stale>)` →
  `DEFINITION_STALE`, and the head is unchanged. With the current head →
  restores.

## Verification (logs under `tmp/workflow-history-unification/whu-10/`)

- `arch -arm64 /bin/zsh -lc 'swift build' > tmp/workflow-history-unification/whu-10/build.log 2>&1; echo exit=$?`
  → `exit=0`.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowRollbackCommandTests|WorkflowRollbackGraphQLTests|WorkflowDefinitionCommandTests|WorkflowDefinitionGraphQLTests"' > tmp/workflow-history-unification/whu-10/tests.log 2>&1; echo exit=$?`
  → `exit=0`.
- `swiftlint lint --quiet` on owned Swift files → exit 0.

## Done criteria

- [ ] The CLI and GraphQL rollback operations work with closed error codes.
- [ ] The restore CAS is honored. All tests above pass.

## Operator standing directive (2026-11-02)

When an acceptance criterion needs an API-shape or naming choice that is additive and can be made inside this plan's writePaths/sharedPaths, choose the minimal additive option, record the decision in the progress file, and continue. Block only when the work truly needs a path outside this plan or contradicts the design.

## Operator note (2026-11-02)

Project/direct sources stay immutable for self-improve and restore; any coverage uses mutable registry/user-scope workflows. whu-07 and whu-09 are accepted in b523407f.

## Operator amendment (2026-11-02, resume #16)

Every path in `writePaths` may be edited by this plan, including the former sharedPaths that have now been moved there.

## Operator amendment (2026-11-02, resume #21)

whu-08 is accepted (0628d7a5). whu-10 owns the whole `Sources/RielaCLI` directory and the CLI definition, GraphQL and enumeration test suites in writePaths. Update the 12-item expectation in `testDefinitionCLIEnumeratesAllOperationsAndRejectsBadGrammar` for the new rollback subcommand(s). Implement the whole plan in this dispatch.
