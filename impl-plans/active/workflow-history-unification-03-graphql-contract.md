# whu-03-graphql-contract: DTOs, protocol methods, dispatch and generator rows for the 7 new GraphQL operations

```json
{
  "planId": "whu-03-graphql-contract",
  "planPath": "impl-plans/active/workflow-history-unification-03-graphql-contract.md",
  "dependsOn": [],
  "wave": 1,
  "writePaths": [
    "Sources/RielaGraphQL/WorkflowHistoryGraphQLContracts.swift",
    "Sources/RielaGraphQL/WorkflowDefinitionGraphQL.swift",
    "Sources/RielaGraphQL/GraphQLSchemaGenerator.swift",
    "Sources/RielaGraphQL/GraphQLVariableValidation.swift",
    "Tests/RielaGraphQLTests/WorkflowHistoryGraphQLContractTests.swift",
    "impl-plans/progress/whu-03-graphql-contract.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

Design §4.3 and §6 (GraphQL). This plan pins the GraphQL contract that the
following consume:

- whu-04 (web);
- whu-09 (versions provider);
- whu-10 (rollback provider).

Providers that do not implement an operation return
`DEFINITION_OPERATION_UNSUPPORTED`, the existing undo/redo pattern. Follow
the execution protocol in the index plan.

Imitate the `undoWorkflowDefinition` wiring exactly:

- protocol requirement plus default implementation in an extension:
  `WorkflowDefinitionGraphQL.swift:230-240`;
- root-field list: `:262`;
- dispatch `case`: `:324-325` (using `requiredInput`, `stringArg`,
  `intArg`, `boolArg`, `definitionJSON`);
- SDL type text: `workflowDefinitionGraphQLSchemaTypes`, `:393-480`;
- field descriptors: `GraphQLSchemaGenerator.swift:631`
  (`"Mutation.undoWorkflowDefinition": .init(name:arguments:type:)`), plus
  the matching `Query.*` entries.

## Non-goals

- No provider implementations; whu-09 and whu-10 write them.
- Do not edit `GraphQLContractProjector+Schema.swift`; whu-11 regenerates
  it.
- No catalog rows.

## Variable validation of generated root fields (checkpoint amendment, integration finding WHU-INT-02)

Correction to the original premise: `GraphQLVariableValidation.swift:429`
only collects input type names from `schemaContract +
GraphQLSchemaGenerator.render()`. The root argument index
(`graphQLInputSchemaIndex`, about `:530-545`) builds `queryArguments` and
`mutationArguments` from the checked-in `schemaContract` only. Generated
input fields are merged into it; generated root arguments are not. The 7
new operations therefore get no variable-type validation until the SDL is
regenerated.

- **Change.** In `graphQLInputSchemaIndex`, merge
  `graphQLRootArgumentTypes(in: executionSchema, typeName: "Query")` into
  `queryArguments`, and the same with `"Mutation"` into
  `mutationArguments`. Use `{ existing, _ in existing }`, so checked-in
  schema entries win, exactly as the existing `inputFields.merge`. Keep the
  explicit `workflowExecution` and `executeWorkflow` overrides unchanged.
- **Forbidden.** No other change to this file. Do not weaken or remove the
  negative variable-type test.
- **Resume.** Resume from the preserved partial whu-03 edits. The
  integer-argument decoding fix (limit 3 reaching the provider) is
  unverified and must be confirmed by the focused run.

## Pinned GraphQL contract (SDL; names are binding)

```graphql
type WorkflowBundleSnapshotSummary { snapshotId: String! parentSnapshotId: String createdAt: String! bundleDigest: String!
  createdBySessionId: String createdBeforeChangeSetId: String createdBeforeRestoreId: String
  mutationReferences: [String!]! restoreReferences: [String!]! }
type WorkflowVersionsPayload { workflowId: String! snapshots: [WorkflowBundleSnapshotSummary!]! nextBeforeSnapshotId: String }
type WorkflowVersionContentDiff { unified: String binary: Boolean! tooLarge: Boolean! limitBytes: Int }
type WorkflowVersionDifference { relativePath: String! kind: String! content: WorkflowVersionContentDiff }
type WorkflowVersionDiffPayload { workflowId: String! from: String! to: String! differences: [WorkflowVersionDifference!]! }
input RestoreWorkflowVersionInput { workflowName: String! scope: String snapshotId: String! apply: Boolean reason: String actorKind: String actorId: String }
type RestoreWorkflowVersionPayload { workflowId: String! sourceSnapshotId: String! dryRun: Boolean! restored: Boolean!
  beforeBundleDigest: String! requestedBundleDigest: String! preRestoreSnapshotId: String
  restoredFiles: [String!]! dirtyConflicts: [String!]! definitionVersionId: String definitionAuditId: String
  definitionWarnings: [String!] }
type WorkflowRollbackRegression { kind: String! gateId: String detail: String! }
type WorkflowRollbackProposal { proposalId: String! workflowName: String! regressedVersionId: String! rollbackToVersionId: String!
  mode: String! bundleSnapshotId: String baselineSessionId: String! targetSessionId: String!
  regressions: [WorkflowRollbackRegression!]! policy: String! status: String!
  decidedActor: WorkflowDefinitionActor decisionReason: String appliedVersionId: String appliedAuditId: String
  failureCode: String diagnostics: [String!]! createdAt: String! updatedAt: String! }
input CheckWorkflowRegressionRollbackInput { workflowName: String! storeScope: String targetSessionId: String }
type CheckWorkflowRegressionRollbackPayload { outcome: String! eligibilityCode: String regressions: [WorkflowRollbackRegression!]!
  proposal: WorkflowRollbackProposal diagnostics: [String!]! }
input ApproveWorkflowRollbackProposalInput { workflowName: String! storeScope: String proposalId: String! reason: String actorKind: String actorId: String }
input RejectWorkflowRollbackProposalInput { workflowName: String! storeScope: String proposalId: String! reason: String! actorKind: String actorId: String }
# Query
workflowVersions(workflowName: String!, scope: String, limit: Int, beforeSnapshotId: String): WorkflowVersionsPayload!
workflowVersionDiff(workflowName: String!, scope: String, from: String!, to: String!, includeContent: Boolean): WorkflowVersionDiffPayload!
workflowRollbackProposals(workflowName: String!, storeScope: String, status: String, limit: Int): [WorkflowRollbackProposal!]!
# Mutation
restoreWorkflowVersion(input: RestoreWorkflowVersionInput!): RestoreWorkflowVersionPayload!
checkWorkflowRegressionRollback(input: CheckWorkflowRegressionRollbackInput!): CheckWorkflowRegressionRollbackPayload!
approveWorkflowRollbackProposal(input: ApproveWorkflowRollbackProposalInput!): WorkflowRollbackProposal!
rejectWorkflowRollbackProposal(input: RejectWorkflowRollbackProposalInput!): WorkflowRollbackProposal!
```

- **Existing input extended.** `RestoreWorkflowDefinitionInput` gains
  optional `expectedVersionId: String`, in both the Swift struct
  (`WorkflowDefinitionGraphQL.swift:170`) and the SDL text (`:461`). This
  is the design §7 restore CAS used by the web screen. whu-10 makes the
  provider pass it to `WorkflowDefinitionService.restore(expectedVersionId:)`,
  which whu-05 adds.
- Swift DTOs use the GraphQL type names prefixed with `GraphQL` (for
  example `GraphQLWorkflowRollbackProposal`), plus input structs named
  after the inputs. All are `Codable`, `Equatable` and `Sendable`, live in
  `WorkflowHistoryGraphQLContracts.swift`, and have field names identical
  to the SDL.
- `status` and `policy` are strings. Status values are the store's case
  names; policy uses the `manual | approval-required | automatic` raw
  values.
- Dates are ISO-8601 strings, as for existing definition DTOs.
- Protocol requirements on `WorkflowDefinitionGraphQLProviding`, with
  default throwing implementations:
  `workflowVersions(workflowName:scope:limit:beforeSnapshotId:)`,
  `workflowVersionDiff(workflowName:scope:from:to:includeContent:)`,
  `restoreWorkflowVersion(input:)`,
  `workflowRollbackProposals(workflowName:storeScope:status:limit:)`,
  `checkWorkflowRegressionRollback(input:)`,
  `approveWorkflowRollbackProposal(input:)`,
  `rejectWorkflowRollbackProposal(input:)`.
  All are `async throws`.
- `restoreWorkflowVersion`: `apply` defaults to `false` when absent; the
  dispatcher passes `apply ?? false`.
- Error codes: keep `WorkflowDefinitionGraphQLError(code:message:)`.
  Providers throw `ROLLBACK_PROPOSAL_NOT_FOUND`,
  `ROLLBACK_PROPOSAL_NOT_PENDING`, `ROLLBACK_SUPERSEDED`,
  `ROLLBACK_IN_PROGRESS`, `ROLLBACK_FAILED`,
  `DEFINITION_ROLLBACK_IN_PROGRESS`, `DEFINITION_SYNC_PENDING`,
  `DEFINITION_SYNC_FAILED`, `WORKFLOW_VERSION_NOT_FOUND`,
  `WORKFLOW_RESTORE_DIRTY_CONFLICTS` and `WORKFLOW_IMMUTABLE`. The
  dispatcher passes any code through unchanged. Declare these as `static
  let` string constants on a `WorkflowHistoryGraphQLErrorCode` enum for
  reuse.

## Pitfalls

- Every new field must be added in three places: the root-field list (or
  the executor will not claim the operation), the dispatch `case`, and the
  generator descriptor.
- Optional args must stay optional. Missing `apply` means a dry run, never
  an apply.
- Do not rename or alter existing definition types or fields.

## Tests (`WorkflowHistoryGraphQLContractTests`; input → expected)

- A stub provider implementing all 7 methods: each operation document
  dispatches to its method with correctly decoded arguments and returns
  JSON whose keys equal the SDL field names.
- A `restoreWorkflowVersion` document without `apply` → the stub receives
  `apply == false`.
- A default (non-implementing) provider → each operation returns error
  code `DEFINITION_OPERATION_UNSUPPORTED`.
- `GraphQLSchemaGenerator.render()` contains each of the 7 field
  signatures verbatim.
- Variable validation accepts a query using the new fields
  (`GraphQLVariableValidation` path).

## Verification (logs under `tmp/workflow-history-unification/whu-03/`)

- `arch -arm64 /bin/zsh -lc 'swift build' > tmp/workflow-history-unification/whu-03/build.log 2>&1; echo exit=$?`
  → `exit=0`.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowHistoryGraphQLContractTests|WorkflowDefinitionGraphQLTests|GraphQLContractsTests|SingleParserTests|SessionMutationTests"' > tmp/workflow-history-unification/whu-03/tests.log 2>&1; echo exit=$?`
  → `exit=0`.
- `SurfaceParityDTOSchemaTests` / `SurfaceParityGraphQLTests` may fail
  until whu-11 regenerates the SDL. Record their status as `expected-until-W6`.
- `swiftlint lint --quiet` on owned files → exit 0.

## Done criteria

- [ ] All 7 operations are dispatchable, with descriptors and SDL type text
      matching the pinned block.
- [ ] The tests above pass and the build is green.
