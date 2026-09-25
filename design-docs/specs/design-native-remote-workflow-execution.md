# Native remote workflow execution receiving boundary

Status: authored for independent design review; implementation is deferred.
Mode: planning-only (`executionMode: design-plan-only`).
Issue reference: none supplied. Issue title: Move remote workflow execution receiving boundary into Riela.
Intake: `comm-000002`, `step1-issue-intake`, execution `codex-design-and-implement-review-loop-session-1`.
Source baseline: `07f1ac0787fc08bfd0f520e1dca3fc0f88b4b518`, branch `feat/native-remote-workflow-execution`.
Codex-agent references: none supplied; Cursor CLI mapping: not applicable.

## Scope and evidence

Add the smallest authenticated receiving path for the existing CLI's
`executeWorkflow` mutation and `workflowExecution` summary query. This document
is new because the execution input, authorization and persistence contract need
dedicated detail; existing historical documentation must remain untouched in
this planning run. Only new reviewed design and implementation-plan artifacts
may subsequently be committed and non-force pushed. This step does neither.

Source observations at the baseline:

- `Sources/RielaCLI/WorkflowCommands.swift`, `remoteRunInputObject`, sends the
  fields enumerated below. `URLSessionWorkflowGraphQLRunTransport` awaits one
  mutation, then one summary query. It neither polls nor accepts an early job
  acknowledgment. It requires a numeric `exitCode` in the mutation result.
- `Sources/RielaCLI/WorkflowRunCommand.swift`, `runRemote`, resolves credentials
  from `--auth-token`, then the selected environment variable (default
  `RIELA_MANAGER_AUTH_TOKEN`). It forwards an optional manager-session header.
  That header is not proof of authorization.
- `Sources/RielaGraphQL/GraphQLSchemaGenerator.swift` has no receiving roots
  for these two operations. `GraphQLVariableValidation.swift` derives input
  types from the generated schema; custom input validation is still necessary
  before decoding, since Codable can discard unknown keys.
- `Sources/RielaGraphQL/WorkflowRegistryGraphQL.swift`,
  `CompositeGraphQLDocumentExecutor`, validates/preflights domains before effects,
  preserves root order, and strips transport credentials before fallback
  preflight and execution. An execution fallback cannot authenticate a bearer
  after that stripping.
- `Sources/RielaServer/ServerContracts.swift` extracts bearer credentials into
  `GraphQLDocumentRequest`; it does not itself verify execution credentials.
  `WorkflowServingController.swift` currently installs only a registry executor
  in its in-process listener. The comment in `ServeWebHost.swift` about the
  authenticated machine route does not establish an execution authenticator.
- `Sources/RielaCLI/ServeWebHost.swift` gates browser requests with
  `ServeWebAccess` and a profile header. `Sources/RielaApp/RielaAppWebRouter.swift`
  applies Host/Origin/CSRF/JSON checks before `RielaAppWebGraphQL.swift` grants
  local trust. Remote serve browser access uses passkeys. Preserve those gates.
- `Sources/RielaCLI/RielaLibrary.swift` delegates ordinary execution to
  `WorkflowRunCommand`; the facade exposes fewer options than the remote wire.
  Use that same command directly in the provider, without adding library APIs.
- `Sources/RielaServer/RielaLocalHTTPServer.swift` and its `+POSIX.swift`
  implementation own route tasks and cancel/drain them on stop. The macOS
  request-read timeout ends before route execution; disconnect removes the
  connection, not the running route task.

No runtime-provenance contradiction was supplied. Runner preflight is accepted;
this design adds no workflow-package discovery or readiness requirement.

## Receiving contract

Publish `Mutation.executeWorkflow(input: ExecuteWorkflowInput!): ExecuteWorkflowPayload!`
and `Query.workflowExecution(workflowExecutionId: String!): WorkflowExecutionSummary`.
Use typed objects for the nested selections; do not disguise selectable objects
as JSON scalars. The summary only exposes fields consumed by the current CLI.

| ExecuteWorkflowInput field | Type and behavior |
| --- | --- |
| workflowName | String!, nonempty scoped workflow name; server resolution and activation rules apply |
| runtimeVariables | JSONObject, omitted/null means empty object; supplied non-null value must be an object |
| instanceIdentity | String, omitted/null means no saved instance; supplied string must be nonempty; maps to WorkflowRunOptions.instance |
| nodePatch | JSONObject, omitted/null means no patch; validate with existing WorkflowInstanceResolver.nodePatches semantics |
| maxSteps | Int, omitted/null inherits runner default; supplied value must be positive |
| maxConcurrency | Int, omitted/null inherits runner default; supplied value must be positive |
| maxLoopIterations | Int, omitted/null inherits runner default; supplied value must be positive |
| disableDefaultLoopGuard | Boolean, omitted/null means false |
| defaultTimeoutMs | Int, omitted/null inherits runner default; supplied value must be positive |

Integer inputs must be finite, integral and within GraphQL signed 32-bit range;
accept JSON encodings of integral numbers emitted by the current CLI. Reject
booleans, fractional values, overflow and strings in integer positions. No
coercion from arbitrary strings or silent clamping.

`autoImprove` and `nestedSuperviser` are forbidden top-level input keys. Reject
by dictionary-key presence before Codable decoding, including false, null, zero,
empty objects and true. Omit both from the schema. Cover whole-input variables,
inline objects, field variables and variable defaults. Do not recursively ban
these names inside opaque runtimeVariables, and do not change resume/rerun input
contracts. Unknown top-level input fields and root arguments are rejected too.

These two historical fields are still conditionally emitted by the baseline
CLI when auto-improve is requested; such calls intentionally fail with an
unsupported-input error. Ordinary requests omit them and must work. Coordinate
removal of those client branches with the separate P1 removal; this receiver
must never silently accept or ignore them. `timeoutMs` exists in the Swift
remote-request DTO but is absent from `remoteRunInputObject` and does not set
URLRequest.timeoutInterval. It is not part of this receiving schema; a manually
supplied `timeoutMs` is rejected. `authToken`, `authTokenEnv`, `managerSessionId`,
working-directory, session-store, scope, mock-scenario and endpoint fields are
also not input fields. Authentication stays in transport headers. No client
option forwarding or historical feature restoration is added here.

Mutation payload fields are `workflowExecutionId: String!`, `sessionId: String!`,
`status: String!`, `exitCode: Int!`. Both IDs equal the actual persisted session
ID, consistent with Riela's existing execution/session identity mapping. Return
the runner's status and exit code, including failed or paused results with a
persisted session; do not invent successful completion.

Summary fields are:

- `session: WorkflowExecutionSessionSummary!` with `sessionId`, `workflowName`,
  `workflowId` (String!), and `transitions: [WorkflowExecutionTransitionSummary!]!`
  whose elements expose `when: String` from the persisted transition condition.
- `nodeExecutions: [WorkflowExecutionNodeSummary!]!`, elements containing
  `nodeExecId: String!` mapped from `snapshot.session.executions[].executionId`.

Project transitions from `snapshot.workflowMessages` belonging to this session,
ordered by `createdOrder`, mapping `transitionCondition` to `when` (nullable).
This counts persisted communications, including root-output messages; it does
not claim equality with the local command's transient `publishedTransitions`
counter, which also increments for cross-workflow/fanout dispatch. The remote
CLI already counts the returned array. Cover this distinction in provider tests.
Use actual persisted arrays in their stored order, including empty arrays;
never fabricate placeholder entries from counts. Read the CLI session record
and canonical runtime snapshot for the same session in the host-selected store.
`workflowName` comes from `PersistedCLIWorkflowSession`; execution records and
transitions come from its canonical runtime snapshot. Unknown well-formed IDs
return `data.workflowExecution: null`. Invalid IDs produce input errors; storage
corruption/read failures produce execution errors rather than looking absent.

The current `CLIWorkflowSessionStore.load(sessionId:strictReadOnly:)` catches
`decodeRecord` failures and throws `notFound` even when strictReadOnly is true
(`Sources/RielaCLI/CLIWorkflowSessionStore.swift:198-201`). That flag controls
read-only database access, not strict decoding; the provider must not use this
method to classify absence. Add `CLIWorkflowSessionStore.loadStrictReadOnly(sessionId:)`
with strict decoding for the receiving provider. Share the existing query and
decoder internally rather than duplicating SQL, while preserving the existing
load/loadAll behavior for unrelated callers. The new method opens strictly
read-only and returns notFound only for an absent database/table/session row.
An existing row with missing/null record text, invalid JSON, incompatible record
shape or a decoding failure throws `CLIWorkflowSessionStoreError.sqliteFailed`
with a bounded message that excludes record contents. Preserve query/open errors
as storage errors. Verify the decoded session ID matches the requested ID.

Only notFound from this strict CLI-record lookup maps to a null summary. Once
that record exists, load the same ID using the existing canonical runtime
`SQLiteWorkflowRuntimePersistenceStore.loadStrictReadOnly(sessionId:)`; missing
or corrupt runtime snapshots, mismatched session/workflow IDs and any storage
failure map to `WORKFLOW_EXECUTION_FAILED`. Use these same strict reads for the
mutation's persistence check before returning IDs. No fallback search, repair,
migration or record rewrite occurs during these reads.

## Authorization and host composition

Machine execution is an operator capability: the configured bearer grants run
and summary access within this host's execution/store context, not per-user
session isolation. Reuse the existing bearer transport and the CLI's default
`RIELA_MANAGER_AUTH_TOKEN` configuration name. A small execution-specific
wrapper verifies against the nonempty value captured from the server's own
startup environment. This is new receiving verification, not a claim that the
baseline already authenticates that token. Missing server configuration, absent
bearer and mismatched bearer all fail closed. A manager-session header, a client
ID, loopback address or a nonempty arbitrary token cannot authorize execution.
Use credential-safe comparison and never include credential values in errors.

Place the wrapper in RielaGraphQL, where GraphQLTransportCredential is readable.
It parses operation roots using the existing parser and establishes an internal
execution authorization marker on GraphQLDocumentRequest before calling the
composite. Only that marker, or already gated local host trust, authorizes the
execution domain. Transport credentials remain stripped before provider calls.
Do not set isLocallyTrusted for bearer clients, do not reuse registry read/write
capabilities as execution permission, and do not change registry authorization.
Mixed documents must still independently satisfy every domain's preflight.
Reject unauthorized execution roots before any resolver, instance load, session
read, patch application or node invocation. Preflight invalid execution roots
before any earlier registry/session-control mutation can execute.

`ServeHTTPCommand.swift` composes the execution provider and wrapper into the
machine GraphQL route in its existing HTTP adapter, retaining the original
registry executor and non-GraphQL routes. Do this at the CLI composition layer;
RielaServer must not import RielaCLI. `ServeWebHost.swift` adds the same execution
executor in its browser fallback chain after its existing access/profile gate.
`RielaAppWebGraphQL.swift` adds it to the gated desktop browser chain. The desktop
route remains its current browser/profile protocol; do not introduce a bearer
bypass there or claim that the unmodified CLI can satisfy its browser headers.
The CLI endpoint acceptance target is `riela serve`.

Capture working directory, environment and session-store context per request.
Use the host's existing workflow-resolution context and profile store root;
never derive filesystem roots from GraphQL input. The headless machine route
uses the startup working directory and resolved session-store root; browser
routes use the active profile's existing context. Freeze those values for both
the run and persistence; a later profile change must not redirect an active
run's writes. Each summary request reads only its currently authorized host
store. Explicitly pass the same resolved store to the command and reader rather
than searching other profiles when an ID is absent. Do not forward incoming
transport credentials into runtime variables, node environments or diagnostics.

## Execution and failure semantics

Add a narrow RielaCLI provider matching the existing session-control provider
pattern. Map supported input fields to WorkflowRunOptions, with endpoint nil,
autoImprove false, supervisorMode false, output JSON, and host-owned resolution,
workingDirectory and sessionStore. Serialize objects as inline JSON, never as
file references. Reuse WorkflowRunCommand.run and its existing resolution,
activation, instance matching, patch validation, durable execution and
cancellation paths. It already supplies the ordinary library execution seam;
no parallel runner, queue, HTTP framework or generalized service layer is needed.

Await the command in the HTTP route task until it returns. A successful mutation
means a real persisted result is available for the immediate summary query.
Check persistence before returning IDs. A command failure before session creation
returns a GraphQL execution error with no invented IDs. A failed run with a valid
persisted result returns its real nonzero exit code. Persistence failure is an
error, even if nodes executed. Keep errors bounded and avoid raw stderr paths,
secrets and runtime-variable values.

Long runs occupy one route task. No 202 response, polling loop, background job or
new workflowExecutionId reservation is introduced. Client/proxy timeouts can
precede completion; disconnect does not currently cancel the macOS route task.
The server continues to own it until completion or server stop. Stop cancels and
drains it through the existing listener lifecycle; prove cancellation reaches
the runner and its persistence path rather than adding an unowned Task. There
is no automatic retry or idempotency promise: retrying an ambiguous timed-out
mutation may create a second run. Existing session inspection remains recovery
for operators. Do not describe a transport timeout as a workflow timeout.

Malformed HTTP/JSON envelopes retain existing HTTP 400/413 behavior. Valid
GraphQL documents with authorization failures return HTTP 200 with top-level
`errors[].extensions.code = UNAUTHENTICATED` and null data; input failures use
`INVALID_EXECUTION_INPUT`, execution/storage failures `WORKFLOW_EXECUTION_FAILED`.
Parser failures may retain the composite's existing invalid-workflow code;
assert rejection and no effects for those cases rather than rewriting unrelated
error semantics. Preserve response aliases, selections, operationName,
fragments, operation kind checks and serial mutation order. Implement domain
preflight forwarding using the existing executor pattern.

## Implementation handoff and acceptance

Order the downstream plan as contract/validation, provider, authenticated host
composition, then integrated tests. Exact intended locations:

1. `Sources/RielaGraphQL/GraphQLSchemaGenerator.swift` for the additive schema;
   new `GraphQLWorkflowExecutionContracts.swift`, `GraphQLWorkflowExecutionValidation.swift`
   and `WorkflowExecutionGraphQL.swift` in the same directory for DTOs, strict
   validation, provider protocol, executor and authorization wrapper.
   `GraphQLDocumentExecuting.swift` carries the internal verified marker.
   `GraphQLVariableValidation.swift` is a regression target; change it only if
   schema-derived type handling requires it. Preserve unrelated validation.
2. New `Sources/RielaCLI/WorkflowExecutionProvider.swift` maps command results and
   reads `CLIWorkflowSessionStore`/`SQLiteWorkflowRuntimePersistenceStore` through
   the new strict CLI-record read specified above and the existing strict runtime
   snapshot read. Amend `Sources/RielaCLI/CLIWorkflowSessionStore.swift` to add
   that narrow read seam before implementing the provider; preserve legacy
   tolerant reads. Do not change the public library facade.
3. `Sources/RielaCLI/ServeHTTPCommand.swift`, `ServeWebHost.swift` and
   `Sources/RielaApp/RielaAppWebGraphQL.swift` wire the provider into existing
   adapters/chains. `Sources/RielaServer/ServerContracts.swift` is the HTTP
   boundary regression target; change it only if necessary to retain envelope
   behavior. Neither listener implementation needs a new lifecycle.
4. `Sources/RielaCore/SurfaceCatalog+Rows.swift` records both new GraphQL bindings;
   `Tests/RielaGraphQLTests/SurfaceParityExecutorCoverageTests.swift` includes the
   new executor without expanding the known-gap allowlist. Update affected
   schema/DTO parity expectations, not historical documentation.
5. New `Tests/RielaGraphQLTests/WorkflowExecutionGraphQLTests.swift` and
   `Tests/RielaCLITests/WorkflowExecutionProviderTests.swift`; extend
   `Tests/RielaCLITests/ServeHTTPCommandTests.swift`, `ServeWebHostTests.swift`,
   `Tests/RielaServerTests/ServerContractsTests.swift` and
   `Tests/RielaAppSupportTests/RielaAppWebRegistryProviderTests.swift` for host
   boundaries. Source-policy tests for the desktop must be identified as such;
   they do not substitute for the headless HTTP execution proof. Extend
   `Tests/RielaCLITests/CLIWorkflowSessionStoreResilienceTests.swift` for strict
   decoding and unchanged legacy tolerant-read behavior.

Required deterministic evidence:

- Start a real RielaLocalHTTPServer through production serve composition with
  a test-owned store and deterministic workflow/adapter fixture. Use the actual
  URLSessionWorkflowGraphQLRunTransport to execute the mutation and summary.
  Assert IDs, terminal status, exit code, workflow name/ID and actual nonzero
  node/transition arrays. Fixtures must not require live model credentials or
  introduce a remotely selectable mock path.
- Exercise every supported field, saved-instance workflow mismatch, node patch
  validation, unknown workflow/deactivated workflow, runner failure and durable
  read/write failure. Count provider/runner calls to prove rejected input has
  no effects. Query summary again through a fresh provider over the same store
  to prove it is persisted, not an in-memory response cache.
- In a valid test-owned database, insert a known session row whose record_json
  is valid JSON but cannot decode as PersistedCLIWorkflowSession (for example,
  `{}`). Keep a valid runtime snapshot for that same ID to isolate record
  decoding. The new strict store method must throw sqliteFailed, and an
  authenticated summary request must return WORKFLOW_EXECUTION_FAILED, not a
  successful null summary. Query a distinct safe ID absent from that same
  database and assert null without errors. Also cover malformed JSON/query
  failure, missing snapshot after a valid CLI record, and mismatched IDs; none
  may be classified as an unknown session. Assert no record/database mutation
  and retain legacy load/loadAll tolerance tests. Implement these checks in
  CLIWorkflowSessionStoreResilienceTests and WorkflowExecutionProviderTests,
  with the corrupt-versus-absent response pair exercised through GraphQL.
- Missing/wrong bearer and absent server token fail both roots with zero session
  reads or starts. Correct bearer works. Manager-session/client-ID spoofing does
  not work. A token authorized for execution cannot authorize registry writes
  or local-only session controls. Browser Host/Origin/CSRF/profile and remote
  passkey regressions remain covered, including profile changes during a run.
- For each forbidden key test true, false, null and object values across input
  variables, inline values and defaults; test both keys together. Unknown keys,
  missing workflowName, wrong types, integer bounds and malformed JSON reject.
  Opaque runtimeVariables with these names and unrelated resume/rerun inputs
  retain their existing behavior.
- Test aliases, fragments, multiple roots, unselected malformed operations and
  operationName. A malformed later execution mutation prevents earlier effects.
  Existing registry/session-control documents and ordinary local CLI runs pass.
- Use a barrier-controlled slow fixture: mutation waits; disconnect leaves only
  a listener-owned task; server stop cancels/drains it and records cancellation.
  No test relies on a guessed wall-clock sleep or an orphan subprocess.

Later implementation verification commands (not executed by this planning step):

```sh
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'RielaGraphQLTests|RielaServerTests|RielaCLITests|RielaAppSupportTests'
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint --quiet --no-cache
git diff --check
```

Run foreground checks through exit and retain complete logs and statuses under
repository `tmp/` while handing off evidence. Passing planning checks are not
passing implementation checks or publication evidence.

## Rollout, open questions and review

No unresolved user decision is required for this bounded design. Independent
design review and implementation-plan review remain pending; author self-check
is not acceptance by those reviewers. No implementation or deployment is claimed.

The separate A1 checkout remains untouched. P1 A2/A3 stays open until the native
receiving tests pass on integrated source. Implementation, branch integration
and removal of obsolete external-service references from historical tracked
material are downstream, after verified integration. No external service is a
publication target or dependency. Planning commits and non-force push follow
independent acceptance of both new artifacts.

Residual operational risks are the existing transport timeout ambiguity,
operator-wide access within the configured store, and long-running route
resource use. They are explicitly bounded by existing host access and listener
lifecycle, not grounds for a new scheduler or permission framework. No high/mid
author finding remains after resolving credential stripping, CLI-only field
compatibility and durable-summary ambiguity in this document.

Review revision: `comm-000004` (Step 3, revision_required) identified one mid
finding: strictReadOnly did not preserve CLI record-decoding errors. Addressed
by the explicit strict-decoding store seam, provider error mapping, exact store
file/test targets and corrupt-versus-absent acceptance case above. Independent
re-review remains pending; no implementation evidence is claimed.
