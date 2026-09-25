# NRE-01: Native remote execution

```json
{
  "planId": "NRE-01",
  "planPath": "impl-plans/active/native-remote-01-graphql-contract.md",
  "dependsOn": [],
  "writePaths": [
    "Sources/RielaGraphQL/GraphQLSchemaGenerator.swift",
    "Sources/RielaGraphQL/GraphQLDocumentExecuting.swift",
    "Sources/RielaGraphQL/GraphQLWorkflowExecutionContracts.swift",
    "Sources/RielaGraphQL/GraphQLWorkflowExecutionValidation.swift",
    "Sources/RielaGraphQL/WorkflowExecutionGraphQL.swift",
    "Sources/RielaGraphQL/GraphQLVariableValidation.swift",
    "Tests/RielaGraphQLTests/WorkflowExecutionGraphQLTests.swift",
    "impl-plans/active/native-remote-nre-01-progress.md"
  ],
  "sharedPaths": [],
  "progressLogPath": "impl-plans/active/native-remote-nre-01-progress.md"
}
```

## Intent, authority and boundaries

Implement the smallest Riela-owned receiving path for the existing remote CLI,
using the accepted design at `design-docs/specs/design-native-remote-workflow-execution.md`.
Design acceptance is `comm-000006`, Step 3, decision `accepted`, no findings,
execution `codex-design-and-implement-review-loop-session-1`. Issue reference:
none supplied; title: Move remote workflow execution receiving boundary into
Riela. Codex-agent references: none; Cursor/reference divergence: not applicable.
The accepted strict-decoding revision from `comm-000004` is mandatory.

This artifact is authored in planning-only mode. All source/test tasks below
are deferred to implementation. Do not edit Swift, tests, README, historical
docs or the separate A1 checkout during this planning run. The runner-resolved
workflow provenance is authoritative; registry rediscovery/repair is not work.

Non-goals: another server, runner, queue, polling protocol, credential framework,
new library facade, legacy auto-improve compatibility, client timeout forwarding,
cleanup of historical references, deployment or branch integration. Preserve
ordinary local CLI runs, existing registry/session-control contracts and browser
security. P1 A2/A3 remains open until receiving tests pass on integrated source.
No external service is a dependency or publication target.

## Same-directory execution and evidence protocol

Before native Riela implementation/review fanout, independent reviewers must
accept this entire plan set and the accepted design plus all plans must be
committed and non-force pushed on `feat/native-remote-workflow-execution`.
This authoring step does not commit or push. No worktrees, private branches,
concurrent Git operations or worker commits. Wave 1 comprises NRE-01 and NRE-02;
wave 2 comprises NRE-03 after both pass their assigned gates. One integration
owner runs all serial reconciliation and finalization.

Before each edit, freshly read the target and dependency interfaces, record
SHA-256 before/after (ABSENT for a new file), and save an immutable intent snapshot
under `tmp/native-remote-implementation/<planId>/<attempt>/` containing accepted
requirements, intended patch, baseline HEAD and file hashes. Do not overwrite
snapshots. Recheck the current hash immediately before applying an edit. If it
changed, reread/reconcile rather than restoring an old full-file copy. Report
drift and affected paths. After join, NRE-03 compares each worker's post-hashes
and required behaviors against the actual tree, repairs lost edits serially,
and reruns affected tests. Hash equality alone is not behavioral verification.

Each worker writes only its own progress log (path in metadata), with task ID,
state pending/in_progress/complete/blocked, changed paths, intent snapshot path,
pre/post hashes, command, log path, terminal exit status, test counts and remaining
findings. Do not mark a task complete from a partial log or skipped test. Scratch
fixtures and command logs belong under repository `tmp/`; never stage them.
The workflow is ongoing until evidence handoff; remove disposable scratch only
after its evidence is consumed. Preserve complete logs until handoff.

Run foreground commands, redirect complete stdout/stderr to a per-command log
under the attempt directory, capture the real command exit status separately
and record it with the command. Do not mask failures with pipelines. Retain and
poll any yielded session through exit. Use sequential SwiftPM commands on this
shared checkout even when source work is independent: the integration owner
serializes build/test access to `.build`. Do not start a detached test/server.
Tests own and stop their listener and await all tasks before returning.

Reserve surface catalog/index edits, lockfiles, broad formatting, global plan
archiving and final Git operations for NRE-03 serial reconciliation. No dependency
or lockfile change is expected. Keep formatting limited to changed Swift files;
follow applicable Swift skill instructions during implementation. If a required
check is blocked, report its actual error and leave completion open.

## Context and deliverables

The client in `Sources/RielaCLI/WorkflowCommands.swift` already issues a mutation
and then a summary query. The schema lacks both receiving fields. The composite
in `WorkflowRegistryGraphQL.swift` strips transport credentials before fallback
preflight, so authorization must be established before entering it. This plan
owns the schema, narrow DTO/provider interface, strict validator, executor and
execution-specific credential wrapper. It does not implement the CLI provider.

## Tasks in order

1. **G1 — Schema and typed interface.** Add `ExecuteWorkflowInput`,
   `ExecuteWorkflowPayload`, `WorkflowExecutionSummary`,
   `WorkflowExecutionSessionSummary`, `WorkflowExecutionTransitionSummary` and
   `WorkflowExecutionNodeSummary` in GraphQLSchemaGenerator.swift and matching
   DTOs in GraphQLWorkflowExecutionContracts.swift. Add mutation
   `executeWorkflow(input: ExecuteWorkflowInput!): ExecuteWorkflowPayload!` and
   query `workflowExecution(workflowExecutionId: String!): WorkflowExecutionSummary`.
   Publish a narrow Sendable provider protocol with async throwing execute and
   optional summary methods; make input/output DTOs usable by RielaCLI. Use
   method names `executeWorkflow` and `workflowExecution`, not another library
   facade. Establish these signatures in the immutable G1 intent snapshot for
   NRE-03. The schema input contains exactly workflowName String!, runtimeVariables
   JSONObject, instanceIdentity String, nodePatch JSONObject, maxSteps Int,
   maxConcurrency Int, maxLoopIterations Int, disableDefaultLoopGuard Boolean,
   defaultTimeoutMs Int. Payload IDs/status are String!, exitCode Int!; both IDs
   represent the same session. Summary session has non-null sessionId/workflowName/
   workflowId, transitions is a non-null array of non-null objects with nullable
   `when: String`; nodeExecutions is a non-null array with `nodeExecId: String!`.
2. **G2 — Strict input validation.** Validate resolved dictionaries before
   Codable. Reject autoImprove and nestedSuperviser by top-level key presence,
   including false/null/zero/objects; exclude both from the schema. Reject unknown
   fields/arguments, missing or blank workflowName, blank supplied instanceIdentity,
   wrong object/Boolean types, invalid session IDs, wrong operation kind and
   invalid selections before effects. Optional null/omitted objects mean empty
   variables/no patch, optional null/omitted limits inherit defaults and loop-guard
   Boolean defaults false. Limits must be positive integral signed-32-bit values;
   accept both integer and integral-number JSON representations. Reject fractions,
   strings, booleans and overflow. Do not modify opaque runtimeVariables or
   resume/rerun contracts. Explicitly reject timeoutMs, credential, root-path,
   scope and mock-scenario keys: they are not current supported wire fields.
   GraphQLVariableValidation.swift should normally need no edit because its
   schema index is derived; change only if a failing new contract test proves
   it necessary and preserve existing semantics.
3. **G3 — Authorization and executor.** In WorkflowExecutionGraphQL.swift build
   an execution-only wrapper using existing operation parsing. Compare the
   received bearer against a nonempty server-configured expected value without
   including either in errors; use a credential-safe full-byte comparison.
   Initialize an internal execution-authorization marker to false in
   GraphQLDocumentExecuting.swift; only verified wrapper code sets it. Do not
   treat authenticatedClientId or manager-session metadata as credentials. Do
   not set local trust, mutate registry principals or leak credentials to the
   provider. Missing configuration/token and wrong token fail closed. Gated
   isLocallyTrusted requests retain the existing host path. Let documents with
   no execution roots follow the unchanged chain. Preflight all execution roots
   using the existing composite/executor pattern, including unselected operations
   where the composite requires it. Forward other domains to next; preserve
   independent registry/session authorization, aliases/fragments, operationName,
   root order and all-domain validation before mutations. Expose queryFields and
   mutationFields for coverage tests. No composite-wide auth relaxation.
4. **G4 — Deterministic GraphQL tests.** Use a counting provider spy, not a live
   runner, in WorkflowExecutionGraphQLTests.swift. Assert ordinary success,
   selected response shape, nullable absent summary and real error mapping.
   Cross each forbidden key with true/false/null/zero/object and variables,
   inline inputs, field variables and defaults; test both keys together and
   harmless nested runtimeVariables names. Test all input types/bounds, aliases,
   fragments, wrong operation kind, duplicate roots, operationName and unselected
   malformed operations. A bad later execution mutation must prevent an earlier
   mutation spy from running. Verify unauthorized reads/starts have zero provider
   calls and an execution bearer cannot enable registry/session mutations.

## Invariants and acceptance

Valid GraphQL authorization failures use HTTP 200, null data and
UNAUTHENTICATED; resolved input errors use INVALID_EXECUTION_INPUT; provider
errors use WORKFLOW_EXECUTION_FAILED. Existing parser/composite rejection codes
may remain where parsing fails first. No secret values in errors. DTO decoding
alone is not validation. Neither historical key is silently ignored. No change
to current supported CLI serialization is required.

G1–G4 complete when targeted tests pass with nonzero discovered tests, the
interface snapshot is delivered, and no high/mid finding remains. Surface catalog
parity is explicitly pending NRE-03, which owns the shared catalog; do not hide
that pending aggregate gate or modify its allowlist here.

## Verification commands and evidence

```sh
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter WorkflowExecutionGraphQLTests
git diff --check
```

Build proves schema/contracts compile. Targeted test log must establish the
G4 positive/negative matrix, zero-effect rejection and correct preflight routing.
Record these command exits/logs in this plan's progress log. NRE-03 owns aggregate
schema/catalog checks and SwiftLint after join.
