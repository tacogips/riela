# Native remote workflow execution receiving boundary

Status: accepted NRE-01/NRE-02/NRE-03 contracts and publication are already on the P1 branch per effective intake. Current work continues from checkpoint `2f472b3bd4d203f21bf72497900e58b88c2ece3b`: A2/A3 and V7 receipts are complete; independent A4 decisions and A5 publication remain pending. Preserve source-matched removal receipts.
Mode: `issue-resolution`; Step 2 updates design only.
Issue: “Complete P1-7a A4 independent evidence handoff and A5 publication”; `tacogips/riela`, no issue number/URL supplied; Step 1 `comm-000002`, execution `codex-design-and-implement-review-loop-session-1`.
Handoff: `feat/remaining-impl-plans`, Draft PR #109.

## Current P1-7a receiving integration

The current continuation in
`design-docs/specs/design-work-runtime-consolidation.md` §17.10 governs A2–A5.
The historical NRE-only scope, pending PR #110 publication, and separate-checkout
restrictions below describe earlier execution checkpoints, not current gates.
Preserve the accepted receiver; no replacement protocol or service is needed.
Remove legacy client emission with P1-7a while retaining native top-level
`autoImprove`/`nestedSuperviser` rejection by presence before provider effects,
including false/null and all accepted input forms. Opaque `runtimeVariables`
remain permitted. Preserve authenticated ordinary execution, strict persisted
summaries, host-owned paths, cancellation and actual terminal outcomes.

Require `swift test --filter WorkflowExecutionGraphQLTests` and
`swift test --filter ServeHTTPCommandTests` receipts matched to final removal
source, alongside P1-7a V0–V9 and independent reviews. Reuse complete unaffected
receipts only after source comparison; renew missing or invalidated checks.
The attempt-2 evidence index is
`tmp/work-runtime-p1-7a-native-a2-a5/plans/p1-dispatch/attempt-2/verification-evidence.json`.
Its passing checks and baseline comparisons do not substitute for A4 acceptance.
Section 17.10's current A4/A5 continuation retains the separate repository-wide final and
checkpoint lint receipts, diagnostic-level comparison and strict changed-file
gate. Renew native tests only when their source/dependencies or evidence are
invalidated; this documentation amendment adds no receiver behavior. Preserve
all nonzero aggregate outcomes for independent test-integrity, Sol adversarial
and Astra integration disposition. V7 is complete (970 Swift files, both exits 0, 24 unchanged warnings); strict
21-file lint passed separately. Both broad aggregates remain FAILED, exit 1,
and each requires its own integrity, adversarial and Astra disposition. Carry
A0's historical environment-metadata limitation and runtime-owned checkpoint
projection through integration; workers do not edit the dispatch manifest.
No new remote protocol or publication dependency is introduced.
Existing source/tests establish where the contract lives, not a new passing
receipt. No archived `rielflow`
publication is a dependency. Historical NRE aggregate failures and unavailable
browser evidence retain their recorded outcomes; do not transplant historical
baseline attribution onto new failures without comparing their causes.
No new user decision, codex-agent reference mapping or Cursor adapter is required.

## Receiving usage and review disposition

Start `riela serve` with a nonempty `RIELA_MANAGER_AUTH_TOKEN` in its
environment. An ordinary client run uses
`riela workflow run <name> --endpoint <server-origin>/graphql` and sends the
matching bearer from `--auth-token` or the selected `--auth-token-env` (default
`RIELA_MANAGER_AUTH_TOKEN`). The mutation waits for the durable result; the
client then queries `workflowExecution` in the same host-selected store. Failed
persisted runs retain their actual status and exit code. The server fixes the
working directory and store; a client timeout does not reserve an idempotent
job, and a retry may start another run. Remote auto-improve input is rejected.

Independent adversarial review (`step7-adversarial-review`, `comm-000013`)
and combined-tree Astra integration review accepted the receiver with no high
or mid findings. The focused provider/storage and host/GraphQL suites,
generated-schema parity, source build, and strict changed-file SwiftLint
passed with complete attempt-4 logs under
`tmp/native-remote-receiver-20260925/NRE-03/attempt-4/`. The full
`RielaGraphQLTests|RielaServerTests|RielaCLITests|RielaAppSupportTests`
aggregate exited 1; its 11 App assertions in six cases match the preserved
preimplementation baseline, and independent review accepted that attribution
without treating the aggregate as passing. `cd web && CI=1 bun run test:e2e`
exited 1 before launching Playwright tests because its transform cache write
failed with `EPERM`; browser E2E results remain unavailable.
Intake: `comm-000002`, `step1-issue-intake`, execution `codex-design-and-implement-review-loop-session-1`.
Accepted planning baseline: `9b1c935bc7e9fe4d586142e4ead035f84ef18ee7`, branch `feat/native-remote-workflow-execution`; preserve this commit.
Accepted amendment checkpoint: `611dc100c25bf297368df7b51fe1aeff429d835c`; preserve this commit and all dirty/untracked implementation.
Pre-implementation comparison checkpoint: `72a9dae65c6ca99cd06746d2100dcf3465fc3e8f`.
Codex-agent reference: `/root` — Step 6 NRE-03 integration review, `comm-000039`; Cursor CLI mapping: not applicable (workflow review reference, not reference-repository input).

## Scope and evidence

Add the smallest authenticated receiving path for the existing CLI's
`executeWorkflow` mutation and `workflowExecution` summary query. This document
uses dedicated detail for the execution input, authorization and persistence
contract. The current intake authorizes completing only NRE-03 on the accepted
NRE-01/NRE-02 base, followed by independent test-integrity, adversarial and Astra
integration reviews, documentation refresh, and reviewed code/docs commit and
non-force push. Preserve all existing dirty/untracked implementation and history.
No reset, stash, force push, separate P1 checkout edits or A2/A3 completion claim
is authorized. This Step 2 edits only this existing design; Step 4 owns focused
plan/manifest alignment before implementation. Historical-reference cleanup
remains outside this run.

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
the runner's actual status and exit code after agreement with durable records,
including failed results; do not invent completion or a paused status. The
NRE-03 disposition below explicitly corrects the earlier paused-result requirement.

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

The accepted plans are archived under `impl-plans/completed/`. Their
implementation history and progress records remain available without expanding
the reviewed scope:

- `impl-plans/completed/native-remote-01-graphql-contract.md` (NRE-01): contract,
  validation and authorization.
- `impl-plans/completed/native-remote-02-strict-storage.md` (NRE-02): strict read-only
  storage; independent of NRE-01.
- `impl-plans/completed/native-remote-03-provider-host-integration.md` (NRE-03):
  provider, authenticated host composition and integrated tests, after both
  NRE-01 and NRE-02 pass their gates.

The effective input authorizes one focused NRE-03 implementation dispatch.
NRE-01/NRE-02 are fixed, accepted external prerequisites from integration review
`comm-000039`, not active fanout tasks. Preserve their source, tests, progress
logs and acceptance evidence; do not redispatch them or reopen their ownership.
Step 4 must emit exactly one NRE-03 task with predecessor dependencies recorded
as already satisfied, preserving links to earlier evidence. Existing contract
and strict-storage locations below describe accepted components, not new edit
assignments. Only existing NRE-03 ownership and the generated-schema exception
below are eligible for implementation.

### Generated-schema parity ownership

The existing dirty `Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift`
contains the prior generator repair and is now allocated in the accepted NRE-03
plan writePaths/sharedPaths. Preserve that allocation and the existing rule from
`scripts/surface-parity/generate-sdl.sh`; Step 4 must retain it in the focused
manifest rather than treating it as a new ownership blocker. The script is a reviewed generation
input, not an added write path; NRE-01/NRE-02 files remain fixed. Preserve current
generated bytes during planning; do not regenerate speculatively or hand-edit
SDL. During implementation, if regeneration is necessary, run
`bash scripts/surface-parity/generate-sdl.sh` with the Xcode Swift toolchain
resolved by its login shell, record the actual toolchain and complete log/exit,
and verify `SurfaceParityGraphQLTests` plus the combined SurfaceParity gate.
Generated content must match the accepted schema and catalog bindings; unrelated
generated drift needs review rather than expanded predecessor ownership.

Existing implementation locations:

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
   snapshot read. `Sources/RielaCLI/CLIWorkflowSessionStore.swift` supplies
   that narrow read seam, already accepted under NRE-02; preserve legacy
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

Later implementation verification commands (not executed by this design step):

```sh
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'WorkflowExecutionProviderTests|CLIWorkflowSessionStoreResilienceTests'
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'WorkflowExecutionGraphQLTests|ServeHTTPCommandTests|ServeWebHostTests|ServerContractsTests|RielaAppWebRegistryProviderTests|SurfaceParity'
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'RielaGraphQLTests|RielaServerTests|RielaCLITests|RielaAppSupportTests'
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint --quiet --no-cache
git diff --check
```

Also run `/usr/bin/xcrun swiftlint lint --strict --quiet --no-cache
--use-script-input-files` with the NRE-03 plan's exact changed/untracked Swift
selection against `9b1c935` and its Xcode environment. Record selected paths;
repository-wide lint does not replace strict changed-file lint.

Run foreground checks through exit and retain complete logs and statuses under
repository `tmp/` while handing off evidence. Passing planning checks are not
passing implementation checks or publication evidence.

## NRE-03 paused-result disposition and verification ownership

Integration review `comm-000039` reports three mid findings: paused-result
contract/ownership mismatch, missing provider/browser/cancellation evidence, and
incomplete aggregate verification. Its decision retains NRE-01/NRE-02 acceptance
and leaves NRE-03 pending. Read-only evidence is the `workflow_messages` row in
`tmp/native-remote-workflow-execution-implementation/sessions/runtime-records/runtime-message-log.sqlite`;
the extracted payload is retained at
`tmp/native-remote-design-amendment-step2/integration-review.log`.

**Disposition: correct the contract, do not add a persisted paused status.**
The accepted amendment at `611dc100c25bf297368df7b51fe1aeff429d835c` resolves the
former acceptance case; retain it without reopening Core status ownership. It is
not a passing implementation claim. Evidence extends beyond the enum:

- `Sources/RielaCore/RuntimeSession.swift:3` defines created/running/completed/failed.
  `WorkflowSession` decodes that enum directly; no paused decoding exists.
- `Sources/RielaCore/DeterministicWorkflowRunner.swift:323` throws on maxSteps
  exhaustion; its catch finalizes interruption as failure. The final result at
  lines 426–435 reads the stored session, with exit 0 for completed or the internal
  stop-after-step path, otherwise 1. It creates no paused result.
- `Sources/RielaCore/DeterministicWorkflowRunner+Cancellation.swift` maps cancellation
  to `cancelled` and step exhaustion to `maxStepsExceeded`, marks the session failed
  and emits exit 1. `Sources/RielaCore/RuntimeStore.swift:549` persists failed status
  and the failure kind. `DeterministicWorkflowRunner+Recovery.swift:61` resumes a
  maxSteps failure using this existing representation.
- The internal `stopAfterStepId` path retains the stored status and can return 0;
  its CLI caller is `Sources/RielaCLI/ScopedParityCommands.swift`, not ordinary
  `WorkflowRunCommand`. Neither it nor `stopBeforeStepId` is an execution input.
  A sleep node remains an in-flight run, not a persisted paused result.
- `Sources/RielaCLI/WorkflowRunCommand.swift` persists the final record/snapshot
  before rendering its result; its failure envelope uses live-persistence identity.
  At the earlier review, `Sources/RielaCLI/WorkflowExecutionProvider.swift` checked
  identity without establishing status agreement. Attempt 3 reports that repair
  and passing focused evidence; renewed final-source verification and independent
  acceptance remain required.

No RuntimeSession, runner, storage-schema or status-consumer ownership expansion
is justified. No enum value, migration, schema version or rewritten historical
record is required; old record decoding, resume and rerun behavior remain unchanged.
Do not use a handwritten paused JSON record or inject an impossible runner result
to meet acceptance. Step 4 must retain the corrected NRE-03 I2/I5 and manifest
`supportedEdgeCases` in the focused dispatch, keeping predecessor evidence intact.
Keep NRE-03 writePaths/trackedPaths unchanged unless a concrete implementation
need is independently reviewed; baseline diagnosis grants no App test/source edits.

Required NRE-03 invariants and deterministic evidence:

1. Successful payload IDs, workflow identity and status agree across command
   result, strict CLI record and canonical snapshot in the captured store. Return
   the actual command exit code; reject missing/corrupt records or contradictory
   status/identity with WORKFLOW_EXECUTION_FAILED rather than normalizing success.
   Apply this to both normal result and failure-envelope branches. Exit code is
   command evidence, not a newly persisted field; no storage expansion is needed.
2. In `Tests/RielaCLITests/WorkflowExecutionProviderTests.swift`, use real ordinary
   runner fixtures for completed/0, persisted failure/nonzero, and a two-step
   workflow with maxSteps=1 yielding failed/maxStepsExceeded/nonzero. Verify both
   persisted stores and the immediate summary; pre-session resolution failure
   produces an error with no invented IDs. Add controlled contradictory-result
   rejection coverage without calling that a real-run acceptance fixture.
3. Existing `ServeHTTPCommandTests.swift`/`ServeWebHostTests.swift` ownership covers
   real HTTP failure mapping, gated browser execution and barrier-controlled
   profile switching: active run writes stay in the captured store and a summary
   in another profile cannot discover it. Desktop source-policy evidence in
   `Tests/RielaAppSupportTests/RielaAppWebRegistryProviderTests.swift` remains labeled.
4. Use a barrier-controlled running node to prove disconnect leaves a listener-owned
   task and server stop cancels/drains it. Strict reads must establish failed with
   failureKind cancelled, not paused/completed. Await cancellation/persistence/exit;
   do not require delivery of an HTTP payload after disconnect. Preserve bounded
   errors and cancellation persistence; incomplete evidence keeps NRE-03 pending.

### Bounded App baseline attribution

The complete log `tmp/native-remote-implementation/NRE-03/attempt-2/app-failures-rerun.log`
records 11 XCTest tests and 11 assertion failures (1 unexpected); review
`comm-000039` records exit 1. They span RielaAppSettingsEditorNavigationTests,
RielaAppUXOnboardingControllerTests and RielaAppWindowContentInsetTests. The trailing
Swift Testing zero-test success does not supersede XCTest failure. Attempt 3
subsequently established matching baseline/current signatures, as recorded below.

The following retained procedure governs the comparison evidence. Preserve its
completed logs; do not restart baseline diagnosis merely because this is a new
workflow execution. Renew current-source gates after changes and revisit baseline
evidence only when source/environment drift or different failures invalidates it:

1. Record HEAD, dirty diff, untracked file hashes, source/test hashes, Package.resolved,
   Swift/Xcode/SDK/architecture and test environment. Freeze source during comparison.
   Export the preserved pre-implementation checkpoint `72a9dae65c6ca99cd06746d2100dcf3465fc3e8f`
   using `git archive` into repository `tmp/native-remote-baseline/source/`; verify
   exported relevant source/test hashes against the commit. Use an archive, not a
   worktree, reset, stash or edits to the current checkout. Confirm the checkpoint
   contains no NRE implementation before treating it as the baseline.
2. Build baseline and current source into distinct fresh scratch directories using
   the same toolchain, dependency versions, architecture and environment; never use
   `--skip-build` or a pre-existing App executable. Run each side once with:

   ```sh
   /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --disable-automatic-resolution --scratch-path <side-specific-build-path> --filter 'RielaAppSettingsEditorNavigationTests|RielaAppUXOnboardingControllerTests|RielaAppWindowContentInsetTests'
   ```

   Execute from the respective source root; log that root and exact expanded command.
   No lockfile/dependency changes are allowed to make the comparison pass. If fresh
   builds cannot resolve identical dependencies, report attribution blocked.
3. Compare named test/assertion signatures and counts, not just exit 1. Permit one
   additional run per side only for differing/flaky signatures. Bound each command
   to 15 minutes under a foreground owner that terminates and waits for timed-out
   work; retain timeout status, never a passing partial log. No endless reruns.
4. Identical source-matched baseline failures may be proposed to independent review
   for a named, explicit baseline disposition; they are not automatically excluded.
   New/different failures remain regressions or unresolved. If an out-of-scope fix
   is necessary, return its evidence for narrow ownership review; do not suppress
   assertions, widen writePaths or edit those three App test files speculatively.
5. Run the full aggregate command listed above on the final combined source, plus
   the NRE-03 focused/build/lint gates. No filters or skips may hide these failures.
   Record the full aggregate's real nonzero status if failures persist; acceptance
   requires either a clean gate or independent approval of individually proven
   baseline failures with all remaining tests passing. Unfinished, mismatched or
   timed-out evidence leaves the aggregate gate and NRE-03 pending.

## Rollout, open questions and review

No unresolved user decision blocks design authoring. The remaining decision is
independent review acceptance or rejection of the 11 baseline-identical App
assertions; matching signatures are evidence, not permission to waive a gate.

### Continuation from terminal attempt 4

The authoritative intake resumes after terminal attempt 4; it is not a live
write owner. Preserve HEAD `905947f947ee439abf331120e9a40727bdd70cf5`, accepted
checkpoints, all dirty/untracked source, and
`impl-plans/active/native-remote-nre-03-progress.md`. That progress file's latest
attempt-4 section supersedes its historical incomplete I5/I6 and ownership notes.
`/root` is the NRE-03 integration owner. Prior read-only agents
`/root/test_gaps`, `/root/source_gaps`, `/root/baseline_evidence`,
`/root/code_audit` and `/root/test_audit` are evidence references only; no
Codex-reference repository or Cursor adapter work is required.

Attempt-4 evidence is retained under
`tmp/native-remote-receiver-20260925/NRE-03/attempt-4/`. Exact commands appear in
the latest progress section; every log below has its corresponding `.exit`:

| Evidence | Recorded terminal result |
| --- | --- |
| `provider-storage-final.log` | 13 tests, zero failures, exit 0 |
| `host-final.log` | 96 tests, one skipped, zero failures, exit 0 |
| `parity-final.log` | 6 tests, one skipped, zero failures, exit 0 |
| `build-final.log` | Build exit 0 |
| `lint-final.log` | Strict lint on 20 selected Swift paths, exit 0 |
| `aggregate-final.log` | 1,469 tests, two skipped, 11 assertions (one unexpected), exit 1 |

`source-manifest-pre-progress.json` records the implementation identity before
the progress-only edit. `aggregate-baseline-comparison.json` reports 11 matching
assertion signatures and no differences; `aggregate-case-comparison.json`
reports the same six failed cases. Preserve the source-matched baseline logs
under `tmp/native-remote-baseline/`, including `baseline-app.log`,
`comparison-final.json` and `source-manifest-final.json`. The aggregate is failed;
its review state is `baselineReviewPending`, not a passing gate or an approved
waiver. Independent reviewers must verify source/environment identity, complete
terminal logs and test integrity before accepting or rejecting attribution.
Do not rerun unchanged expensive gates without a source-identity or evidence
reason; targeted repairs require renewed affected gates and final-source evidence.

Attempt 4 reports I5/I6 complete. Independently verify these retained cases
without redispatching completed work or expanding components or ownership:

| Accepted case | Required observable evidence | Assigned test path |
| --- | --- | --- |
| Invalid node patch, saved-instance mismatch, deactivated workflow | Real command rejects before node invocation or new durable session; assert actual store and invocation effects, not only error text | `Tests/RielaCLITests/WorkflowExecutionProviderTests.swift` |
| Malformed record JSON and query failure | Existing record/storage failure yields bounded execution error, never unknown-session null; reads leave stores unchanged | `Tests/RielaCLITests/WorkflowExecutionProviderTests.swift` |
| Write failure | Deterministic persistence failure cannot return successful IDs; distinguish any nodes already executed from a rejected pre-session request | `Tests/RielaCLITests/WorkflowExecutionProviderTests.swift` |
| Ordered and cross-workflow summaries | Fresh provider reads canonical persisted arrays with session filtering, createdOrder ordering and actual node IDs; no equality assumption with transient dispatch counts | `Tests/RielaCLITests/WorkflowExecutionProviderTests.swift` |
| Malformed HTTP/JSON envelope and size limit | Production HTTP path preserves existing 400/413 rejection and existing limits, with zero execution/session effects | `Tests/RielaCLITests/ServeHTTPCommandTests.swift` |
| Rejected-request effects | Unauthorized or invalid requests cannot invoke runner/nodes or create/change durable records; retain existing bearer, browser/profile and cancellation regressions | `Tests/RielaCLITests/ServeHTTPCommandTests.swift` and `Tests/RielaCLITests/ServeWebHostTests.swift` |

One owner serializes edits and SwiftPM checks. Bounded read-only investigation
and test design may be delegated; only NRE-03 is dispatched. Reuse the existing
plan's focused, build, strict changed-file lint and unfiltered aggregate commands
above, with complete logs, actual exits and final source hashes under `tmp/`.
Any new/different failure requires resolution or explicit ownership review.
Independent test-integrity, the single adversarial review and Astra integration
review must each record their decision on the combined source and explicitly
accept or reject baseline attribution. A nonzero aggregate remains nonzero even
if those reviewers accept individually evidenced baseline failures. No test
suppression, speculative App UI repair or predecessor changes are authorized.

Implementation completeness covers I5/I6 behavior and final-source evidence;
formal reviews, review-dependent documentation and publication are later gates.
Do not self-block completed implementation on those later tasks, and do not
claim overall completion before they finish. After acceptance, refresh receiving
docs and commit/non-force push reviewed source/docs to
`feat/native-remote-workflow-execution`. Verify existing PR #110 is open, Draft,
targets `main`, and its head equals the reviewed pushed commit using:

```sh
git rev-parse HEAD
git ls-remote --heads origin refs/heads/feat/native-remote-workflow-execution
gh pr view 110 --repo tacogips/riela --json number,state,isDraft,baseRefName,headRefName,headRefOid,url
```

All three hashes must match; PR state must be OPEN and isDraft true. These are
post-push verification commands, not checks performed by this design node. Do not checkout,
merge, commit or push `main`. P1 A2/A3 and retired-reference cleanup stay separate.

Step 3 reviews this focused issue-resolution handoff without reopening the accepted
amendment. Step 4 aligns only
`impl-plans/completed/native-remote-03-provider-host-integration.md` and
`impl-plans/active/native-remote-receiver-20260925-dispatch.json`: one NRE-03 task,
satisfied external predecessors, generated-schema ownership/rule, and unchanged
bounded aggregate attribution. Step 5 reviews the resulting plan/manifest before
any material repair. Preserve prior accepted planning checkpoints; alignment must
carry attempt-4 completion and `baselineReviewPending` forward, not demand a
repeat implementation or a green aggregate before independent review.
Independent test-integrity, adversarial and Astra integration
reviews must accept the combined source and its source-matched verification;
resolve every high/mid finding before reviewed source/docs are committed and
non-force pushed. Preserve checkpoint `611dc100c25bf297368df7b51fe1aeff429d835c`
and all prior implementation/evidence. This design step neither commits nor
pushes. NRE-03 remains pending; P1 A2/A3 remains open in its separate workflow.

Residual operational risks remain synchronous timeout ambiguity, operator-wide
store access and long-running route resource use. Independent confirmation of
I5/I6 test integrity and aggregate disposition remain open at review level;
this design update does not decide them.
Historical strict-decoding feedback (`comm-000004`, subsequently accepted in
`comm-000006` during prior planning) remains addressed by the unchanged strict-read
contract. The retained amendment responds to integration review `comm-000039`; the current
Step 1 intake (`comm-000002`) authorizes its focused independent-review continuation.
There is no new Step 3/Step 5 review decision for this handoff yet.

Current disposition (2026-09-25): the preceding planning and pending-review
language records the earlier checkpoint. Step 6 test integrity, Step 7
adversarial review (`comm-000013`), and combined-tree Astra integration review
subsequently accepted NRE-03 with no high or mid findings. Independent review
accepted baseline attribution for the aggregate Swift exit 1; browser E2E
could not launch because Playwright's transform cache returned `EPERM`
(`comm-000019`). The three NRE plans are archived under
`impl-plans/completed/`. Final commit, non-force push, and Draft PR #110 head
verification remain pending.
