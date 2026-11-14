# Named Kaiba API Instances And KaibaClient Migration Implementation Plan

**Status**: IN_PROGRESS — implementation evidence is recorded task-by-task;
clean KaibaClient dependency publication and current-executable screenshots
remain external release gates
**Workflow Mode**: `issue-resolution`
**Workflow Execution**: `codex-design-and-implement-review-loop-session-111`
**Issue Reference**: `local-request:/Users/taco/gits/tacogips/riela:Add named Kaiba API instances and migrate every kaiba node to KaibaClient`
**Design Reference**: `design-docs/specs/design-kaiba-api-instances.md`
**Created**: 2026-09-05
**Last Updated**: 2026-09-05
**Commit Authorized**: No
**Push Authorized**: No

## Accepted Contract And Traceability

Step 3 accepted `design-docs/specs/design-kaiba-api-instances.md` with no high,
mid, or low findings and declared implementation ready for planning. That design
is the sole normative product contract for this plan. The gitignored
`tmp/kaiba-api-instances/ideal-spec.md` is intake provenance only and must not be
required after scratch cleanup.

Codex-agent and source references:

- `AGENTS.md`: keep all scratch/evidence under `tmp/`; refresh
  `riela-package.json` digests after any workflow, prompt, script, or skill edit.
- `.codex/skills/riela-impl-workflow/SKILL.md`: preserve workflow evidence,
  refresh affected repository-facing documentation before finalization, and
  keep the issue as one atomic work package.
- `.codex/skills/riela-usability-improvement-loop/SKILL.md`: verify real CLI and
  App journeys with isolated roots and actionable cross-surface recovery copy.
- `.codex/skills/swift-coding-agent/SKILL.md`: use the Xcode Swift toolchain,
  run SwiftLint, keep responsibilities testable, and leave every non-generated
  Swift file below 1,000 lines.
- `.agents/skills/rielaapp-ui-verification/SKILL.md`: verify the current direct
  debug executable, capture windows by CGWindow ID, and inspect screenshots.
- `/Users/taco/gits/tacogips/kaiba/design-docs/specs/kaiba-client-sdk.md`,
  `/Users/taco/gits/tacogips/kaiba/design-docs/specs/graphql-schema-discovery-cli.md`,
  and `/Users/taco/gits/tacogips/kaiba/Sources/KaibaClient`: provide the
  first-party client, typed operations, arbitrary GraphQL, endpoint/auth policy,
  readiness, redaction, transport seam, and idempotency contracts.
- `Sources/RielaCore/DeterministicWorkflowRunner+Addons.swift`,
  `Sources/RielaCore/DeterministicWorkflowRunner+ExecutionEvents.swift`, and
  `Tests/RielaCoreTests/WorkflowAddonExecutionIdentityTests.swift`: own runtime
  execution/retry lineage used to derive mutation operation identity.

Accepted divergences from the intake ideal spec are implementation requirements:

- Use `show` and `set-default`; do not add `instance default`.
- Persist one user-wide catalog/default, not project/profile catalogs or
  workflow/package recommendations.
- Accept only server-root or `/graphql` endpoints and normalize to `/graphql`;
  reject custom paths even though the SDK can transport them.
- Store only a bearer environment-variable name or unauthenticated mode; never
  add a value-bearing secret field.
- Treat local-store inputs as inert compatibility fields and legacy remote
  connection fields as exact-match assertions; neither can route or create a
  fallback.
- Reconstruct successful arbitrary GraphQL compatibility output as status 200
  plus `{ "data": ... }`; the SDK intentionally exposes no raw envelope/status.
- Keep caller-owned document preparation, but reject S3/config-derived features
  that have no SDK operation as `unsupported_kaiba_client_feature`.
- Do not add package enablement/update metadata, Web Config, secret management,
  retries, non-HTTP(S) transport, or Cursor adapter changes.

## Delivery Order

```text
K0 baseline and package boundary
  -> K1 strict catalog model/store
  -> K2 binding scanner, selector, client factory, readiness
       -> K3 CLI management surface ------------------+
       -> K4 runtime identity and preflight ----------+
       -> K5 all kaiba/* add-on migration ------------+--> K9 integration/docs
       -> K6 RielaAppSupport use cases -> K7 App UI --+       -> K10 atomic gates
                                  K8 compatibility/redaction hardening --^
```

K3, K4, K5, and K6 may proceed in parallel only after K2 freezes the shared
interfaces and only while their listed write scopes remain disjoint. K7 depends
on K6. K8 is a cross-cutting review task after production paths exist. K9 and
K10 are serial integration tasks. Never ship or present an intermediate state
where named instances exist but any registered `kaiba/*` add-on can still open a
local store.

## K0. Preserve Baseline And Establish The Package Boundary

**Status**: IN_PROGRESS — internal KaibaClient support target added against the
explicitly authorized editable checkout; publishing the Kaiba revision remains
a release gate

**Write scope**:

- `Package.swift`
- `Package.resolved`
- `tmp/kaiba-api-instances-impl/` (evidence only)

**Tasks**:

- [x] Record `git status --short`, the diff for every overlapping dirty file,
  current Kaiba add-on inventory, current focused test results, and current
  Swift file sizes under `tmp/kaiba-api-instances-impl/baseline/` without
  staging or reverting anything.
- [x] Confirm the explicitly authorized sibling checkout exports the
  dependency-free `KaibaClient` product used by the accepted SDK source. Use
  `swift package edit kaiba --path /Users/taco/gits/tacogips/kaiba` for this
  worktree's implementation and verification. Do not commit `Packages/kaiba`,
  an absolute package path, or other editable-dependency state. Record the
  missing published revision as a release/publishability gate rather than
  blocking source implementation.
- [x] Add the internal `RielaKaibaSupport` target and
  `RielaKaibaSupportTests` target. Make `RielaKaibaSupport` depend on
  `RielaCore` and `KaibaClient`; link/import `KaibaClient` only in
  `RielaKaibaSupport` and `RielaKaibaAddons`. Do not add an unnecessary public
  library product.
- [x] Replace `RielaKaibaAddons` dependencies on Kaiba `AppCore` and
  `AppGraphQL` with `KaibaClient` and `RielaKaibaSupport`; add
  `RielaKaibaSupport` to `RielaCLI` and `RielaAppSupport`.
- [x] Keep caller-owned document preparation at the Riela boundary without a
  Kaiba service, configuration, storage, or GraphQL dependency.
- [x] Update comments in `Package.swift` so they describe the HTTP client
  boundary rather than the current local service boundary.
- [x] Integrate rather than overwrite the pre-existing dirty `Package.swift`
  and `Package.resolved` edits.

**Deliverables**:

- A compiling SwiftPM graph using the explicitly authorized editable Kaiba
  checkout, with no committed local Kaiba path or editable-dependency artifact.
- Baseline evidence that distinguishes pre-existing failures/dirty changes from
  work-package regressions.

**Depends on**: accepted Kaiba SDK worktree for implementation and verification;
published Kaiba SDK revision before final clean-checkout commit/release.

**Verification**:

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift package describe
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --target RielaKaibaSupport
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --target RielaKaibaAddons
git diff --check -- Package.swift Package.resolved
```

## K1. Strict User-Wide Catalog Model And Transactional Store

**Status**: IN_PROGRESS — normalized catalog persistence, strict duplicate-key
decode, advisory mutation locking, resolver, and client/readiness foundations
added; complete mutation policy, CLI, and App integration remain pending

**Write scope**:

- `Sources/RielaKaibaSupport/KaibaInstanceModels.swift` (new)
- `Sources/RielaKaibaSupport/KaibaInstanceValidation.swift` (new)
- `Sources/RielaKaibaSupport/KaibaInstanceStore.swift` (new)
- `Sources/RielaKaibaSupport/KaibaInstanceStoreTransaction.swift` (new if needed
  to keep responsibilities and file sizes bounded)
- `Sources/RielaKaibaSupport/KaibaInstanceDiagnostics.swift` (new)
- `Tests/RielaKaibaSupportTests/KaibaInstanceModelTests.swift` (new)
- `Tests/RielaKaibaSupportTests/KaibaInstanceStoreTests.swift` (new)
- `Tests/RielaKaibaSupportTests/KaibaInstanceStoreConcurrencyTests.swift` (new)

**Tasks**:

- [x] Model schema version 1, immutable lowercase UUID IDs, normalized display
  names, the closed authentication union, enabled, default, and policy flags,
  and the safe `lastTest` state. Public result DTOs may expose only the credential
  environment-variable name, never a value.
- [x] Implement strict duplicate-key/unknown-key/version/enum/token-like-field
  rejection before normal Codable projection. Encode sorted keys with one
  canonical representation.
- [x] Resolve `<home>/.riela/kaiba/instances.json` through an injectable home
  URL; absent file means empty, while unreadable/non-regular/symlink/invalid
  state fails closed with the accepted stable code.
- [x] Apply endpoint, name, environment-variable, auth-policy, exactly-one-
  default, enabled-default, selector, add/update/disable/remove/set-default, and
  `lastTest` transition rules in one shared validation/domain layer.
- [x] Use the existing platform lock pattern for reload-validate-mutate-
  revalidate, same-directory sorted-key temporary write, synchronization, and
  atomic replace. Inject file system, clock, and ID generation for deterministic
  failure and race tests.
- [x] Guarantee a rejected mutation leaves original bytes unchanged and that
  concurrent CLI/App writers cannot lose updates or violate invariants.
- [x] Test sentinel credentials against encoded bytes, reflection, public DTOs,
  and all model/store error renderings.

**Deliverables**:

- One strict catalog/store API shared by CLI, runtime, scanner, and App support.
- Stable, fixed Riela-owned diagnostic code/message/next-action projection.

**Depends on**: K0.

**Verification**:

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaKaibaSupportTests
git diff --check -- Sources/RielaKaibaSupport Tests/RielaKaibaSupportTests
```

## K2. Binding Discovery, Resolution, Client Construction, And Readiness

**Status**: IN_PROGRESS — fail-closed explicit/default selection, environment
credential client construction, strict definition/instance-patch scanning,
scanner-backed CLI removal, immutable resolved-client snapshot, and CLI
workflow/session/direct-node readiness preflight are implemented; the snapshot is
handed to catalog dispatch, while K5 HTTP operation consumption remains pending

**Write scope**:

- `Sources/RielaKaibaSupport/KaibaBindingReference.swift` (new)
- `Sources/RielaKaibaSupport/KaibaBindingScanner.swift` (new)
- `Sources/RielaKaibaSupport/KaibaInstanceResolver.swift` (new)
- `Sources/RielaKaibaSupport/KaibaClientFactory.swift` (new)
- `Sources/RielaKaibaSupport/KaibaReadinessService.swift` (new)
- `Sources/RielaKaibaSupport/KaibaExecutionSnapshot.swift` (new)
- `Tests/RielaKaibaSupportTests/KaibaBindingScannerTests.swift` (new)
- `Tests/RielaKaibaSupportTests/KaibaExecutionSnapshotTests.swift` (new)
- `Tests/RielaKaibaSupportTests/KaibaInstanceResolverTests.swift` (new)
- `Tests/RielaKaibaSupportTests/KaibaReadinessServiceTests.swift` (new)

**Tasks**:

- [x] Implement the finite project/user/profile/registered external root scan,
  existing workflow/package discovery rules, supported JSON-only reads,
  canonical-path deduplication, no root-escaping symlink traversal, strict
  changed/malformed/unreadable failure, and the accepted deterministic sort.
- [x] Preserve the accepted dependency direction: callers supply project,
  home, App, profile, registered-project, and standalone-workflow root
  descriptors; `RielaKaibaSupport` may use `RielaCore` contracts or its own
  narrowly scoped source readers but must not import `RielaCLI`,
  `RielaAddons`, `RielaAppSupport`, or `RielaApp` to discover them.
- [x] Extract only effective authored `addon.config.kaibaInstanceId` from
  definitions and instance patches. Never template-expand it or read it from
  variables, payloads, models, or environment values.
- [x] Coordinate every Riela-managed binding write and remove scan with the
  catalog lock. Ordinary removal blocks on references; forced removal leaves
  bindings untouched and returns the exact sorted affected-reference DTOs.
- [x] Resolve explicit ID first and otherwise the snapshot default. Never
  substitute the default for an unknown, disabled, or invalid explicit binding.
- [x] Resolve a bearer environment value only during client construction from
  the supplied effective environment, instantiate `KaibaBearerToken`, and map
  policy flags directly to `KaibaClientConfiguration`.
- [x] Provide an injected `KaibaHTTPTransporting` factory and immutable
  execution snapshot containing one client per distinct instance. Coalesce one
  generic readiness request per distinct instance and one additional
  `longTermMemoryNotebook()` capability probe where any selected node requires
  it.
- [x] Map cancellation unchanged and all other SDK/readiness/control-plane
  outcomes to fixed Riela codes without copying SDK descriptions, server data,
  documents, variables, headers, or URLs from errors.
- [x] Implement App/CLI test revision checks: snapshot before I/O, release the
  lock during I/O, and persist a result only if transport-relevant fields still
  match after locked reload.

**Deliverables**:

- One deterministic binding scanner and one immutable fail-closed execution
  resolver consumed by every surface.
- A frozen support interface allowing K3-K6 to work in disjoint scopes.

**Depends on**: K1.

**Verification**:

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'KaibaBindingScannerTests|KaibaInstanceResolverTests|KaibaReadinessServiceTests'
git diff --check -- Sources/RielaKaibaSupport Tests/RielaKaibaSupportTests
```

## K3. Canonical CLI CRUD, Test, Default, And Stable Rendering

**Status**: IN_PROGRESS — canonical command route, fixed instance text/JSON
rendering, option-conflict rejection, and stale-test transport guard added;
scanner-backed removal is implemented; complete error DTOs and full golden
coverage require further completion

**Write scope**:

- `Sources/RielaCLI/RielaClientCommandRouter.swift`
- `Sources/RielaCLI/RielaCommand.swift`
- `Sources/RielaCLI/RielaCLIApplication.swift`
- `Sources/RielaCLI/KaibaInstanceCommands.swift` (new)
- `Sources/RielaCLI/KaibaInstanceCommandModels.swift` (new)
- `Tests/RielaCLITests/KaibaInstanceCommandParsingTests.swift` (new)
- `Tests/RielaCLITests/KaibaInstanceCommandTests.swift` (new)
- `Tests/RielaCLITests/KaibaInstanceCommandRedactionTests.swift` (new)

**Tasks**:

- [x] Add only the canonical `riela kaiba instance
  list|show|add|update|remove|test|set-default` hierarchy and accepted flags.
  Keep workflow `riela instance` unchanged and do not add `instance default`.
- [x] Parse typed command options, reject contradictory auth/update flags, and
  preserve the accepted validation order so each invocation has one stable
  primary error.
- [x] Inject the home URL into the command runner in tests through the existing
  environment/home-directory boundary; do not add a public CLI `--home-root`
  option. Route removal's accepted `--working-dir` and `--app-root` options into
  the shared scanner.
- [x] Render the exact list/show/mutation text contracts, sorted-key newline-
  terminated JSON success/error objects, sorted instances/references, stdout vs
  stderr rules, and exit 0/1/2 semantics.
- [x] Make `test` use K2 readiness and safe `lastTest` persistence; disabled
  tests perform no transport and memory capability is not part of generic test.
- [ ] Cover every fixed error-table row, empty list, default replacement,
  force semantics, stale test completion, transport categories, help, golden
  output, and sentinel redaction.

**Deliverables**:

- Stable CLI management and readiness behavior over isolated user roots.

**Depends on**: K2.

**Parallelization**: May run with K4, K5, and K6 after K2; no shared writes.

**Verification**:

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'KaibaInstanceCommandParsingTests|KaibaInstanceCommandTests|KaibaInstanceCommandRedactionTests'
.build/debug/riela kaiba instance --help
.build/debug/riela kaiba instance list --output json
```

## K4. Runtime-Owned Idempotency Identity And Preflight Integration

**Status**: IN_PROGRESS — runtime-owned retry operation identity and fail-closed
workflow/session/direct-node Kaiba preflight and catalog snapshot handoff are
implemented; K5 resolved-client HTTP operation consumption remains pending

**Write scope**:

- `Sources/RielaCore/WorkflowAddonExecution.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner+Addons.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner+ExecutionEvents.swift` only if
  execution-record plumbing requires it
- `Sources/RielaCLI/ProductionNodeAdapter.swift`
- `Sources/RielaCLI/ProductionNodeAdapter+Kaiba.swift` (new if extraction keeps
  composition cohesive and file sizes bounded)
- `Sources/RielaCLI/NodeCommandRunner.swift`
- `Sources/RielaCLI/WorkflowRunCommand.swift`
- `Sources/RielaCLI/WorkflowRunCommand+AutoImprove.swift` only where shared run
  composition requires the same gate
- `Tests/RielaCoreTests/WorkflowAddonExecutionIdentityTests.swift`
- `Tests/RielaCoreTests/WorkflowAddonResolvedInputPayloadTests.swift`
- `Tests/RielaCLITests/KaibaWorkflowPreflightTests.swift` (new)
- `Tests/RielaCLITests/KaibaNodeRunPreflightTests.swift` (new)

**Tasks**:

- [x] Extend runtime-owned execution identity with validated
  `operationExecutionId`: current `stepExecutionId` on first attempt, otherwise
  oldest ID in the consecutive unaccepted retry lineage. Reject empty,
  duplicate, self-containing, or singular/array-inconsistent lineage before
  add-on transport.
- [x] Keep accepted loop iterations, new runs, and explicit reruns outside the
  prior lineage so they receive new operation identities; preserve one identity
  through any number of consecutive resumable failures.
- [x] Snapshot and preflight all declared `kaiba/*` nodes after effective node
  patches and workflow environment resolution but before scheduling business
  work. Cache one client/readiness result per selected distinct instance.
- [x] Ensure static failures and readiness failures prevent every business
  GraphQL operation from starting. Add the memory capability probe only for
  selected consolidate/recall nodes.
- [x] Give direct `riela node run`/`rrun` the same single-node gate. Authored
  keys work normally; an automatic mutation key requires identity supplied by
  a non-authored runtime boundary and otherwise fails as
  `missing_idempotency_identity`. Never synthesize it from command arguments,
  variables, payloads, or another authored value.
- [x] Pass only resolved clients/safe instance metadata and validated operation
  identity into `RielaKaibaAddons`; do not expose the catalog or raw environment
  for route selection inside an add-on.
- [x] Leave Cursor and every non-Kaiba add-on adapter path unchanged.

**Deliverables**:

- Fail-closed workflow/direct-node startup and deterministic retry lineage.
- A single runtime composition path from catalog snapshot to Kaiba add-on call.

**Depends on**: K2.

**Parallelization**: May run with K3, K5, and K6 after K2; K2 interfaces must be
frozen and `ProductionNodeAdapter.swift` belongs exclusively to K4.

**Verification**:

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter WorkflowAddonExecutionIdentityTests
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'KaibaWorkflowPreflightTests|KaibaNodeRunPreflightTests'
```

## K5. Migrate Every Registered `kaiba/*` Add-On To `KaibaClient`

**Status**: IN_PROGRESS — HTTP-only catalog dispatch, safe fixed projections,
document source attachment, memory compatibility outputs, and injected transport
coverage are implemented; caller-owned OCR/translation and final acceptance
coverage remain required.

**Write scope**:

- `Sources/RielaKaibaAddons/KaibaAddonCatalog.swift`
- `Sources/RielaKaibaAddons/KaibaAddonInputs.swift`
- `Sources/RielaKaibaAddons/KaibaJSONBridge.swift`
- `Sources/RielaKaibaAddons/KaibaNoteAddonDispatch.swift`
- `Sources/RielaKaibaAddons/KaibaNoteAddons.swift`
- `Sources/RielaKaibaAddons/KaibaKnowledgeAddons.swift`
- `Sources/RielaKaibaAddons/KaibaNoteAttachmentSupport.swift`
- `Sources/RielaKaibaAddons/KaibaNoteIngestSupport.swift`
- `Sources/RielaKaibaAddons/KaibaNoteGraphQLDocument.swift`
- `Sources/RielaKaibaAddons/KaibaRemoteGraphQLAddon.swift`
- `Sources/RielaKaibaAddons/KaibaLongTermMemoryAddons.swift`
- `Sources/RielaKaibaAddons/KaibaDocumentPreparation.swift` (new)
- `Sources/RielaKaibaAddons/KaibaDocumentOCR.swift` (new if OCR remains a
  separate responsibility)
- `Sources/RielaKaibaAddons/KaibaDocumentTranslation.swift` (new if translation
  remains a separate responsibility)
- New responsibility-based projection/idempotency files under
  `Sources/RielaKaibaAddons/` as needed
- Existing and new files under `Tests/RielaKaibaAddonsTests/`

**Tasks**:

- [x] Replace the local/remote catalog split with one inventory matching every
  `kaiba/*` descriptor in `Sources/RielaAddons/RielaAddons.swift` exactly.
- [x] Remove `AppCore`, `AppGraphQL`, `NoteService`, SQLite,
  `GraphQLHTTPDocumentClient`, note-root, database-path, and local-store client
  construction from all production paths.
- [x] Implement each accepted matrix row through the named typed SDK operation:
  note create/update/get/search/tag search/graph neighbors/chain/tag apply,
  attachment list/add, memo/comment, notebook ingest, document ingest,
  conversation save, and long-term-memory operations.
- [x] Route both GraphQL add-on names through `KaibaClient.execute`; preserve
  variable behavior, sole-field flattening, deterministic reconstructed
  `{ "data": ... }` body, `handled: true`, and compatibility status 200.
- [x] Require `result.accepted == true` for control-plane payloads and map
  rejected, transport, GraphQL, decode, and cancellation behavior through the
  shared safe diagnostic projector.
- [x] Keep bounded caller-owned document preparation and inline attachment
  projection on the caller side. Never send server-local paths;
  reject S3/config-fallback options that the SDK cannot express.
- [x] Preserve output fields and existing aliases/bounds except the accepted
  removal of `noteRoot`/`databasePath` and unsupported feature failures.
- [x] Implement explicit authored idempotency keys and automatic SHA-256 keys
  from length-prefixed workflow/operation/workflow/step/node/add-on/
  discriminator fields. Use distinct primary/translation discriminators and
  never derive from authored data or the current retry ID alone.
- [x] Add injected-transport request assertions and lost-response tests with at
  least two retries for notebook ingest, primary and translated document
  ingest, and memory consolidation. Prove identical body/key replay, differing
  document keys, changed-body conflict visibility, cross-run explicit replay,
  and new keys after accepted iterations/new runs.
- [x] Integrate carefully with the pre-existing dirty
  `KaibaLongTermMemoryAddons.swift` and `KaibaNoteAddons.swift` changes.

**Deliverables**:

- All 19 existing version-1 add-ons use only HTTP(S) `KaibaClient` execution.
- Payload compatibility and intentional divergences are fixture-tested.

**Depends on**: K2 and the frozen resolved-client execution interface. K4 is
required for end-to-end automatic-key tests, but typed operation migration can
proceed against injected identities first.

**Parallelization**: May run with K3, K4, and K6 after K2. Within K5, read-only,
write, GraphQL, ingest/document, and memory groups may be assigned separately
only when each group owns disjoint source/test files and one owner integrates
shared catalog/bridge/idempotency files.

**Verification**:

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaKaibaAddonsTests
comm -3 <(rg -o 'kaiba/[a-z][a-z0-9-]*' Sources/RielaAddons/RielaAddons.swift | sort -u) <(rg -o 'kaiba/[a-z][a-z0-9-]*' Sources/RielaKaibaAddons/KaibaNoteAddonDispatch.swift | sort -u)
rg -n 'import (AppCore|AppGraphQL)|NoteService|SQLiteNoteDatabaseDriver|GraphQLHTTPDocumentClient|KaibaConfigurationLoader|ImportDocumentConverter|AgentGatewayImageOCRConverter|AITranslationService|KAIBA_NOTE_ROOT|RIELA_NOTE_ROOT' Sources/RielaKaibaAddons
```

The inventory comparison must produce no differences. The forbidden-symbol
gate must produce no matches.

## K6. RielaAppSupport Use Cases And View Models

**Status**: IN_PROGRESS — shared App-support catalog façade, scanner-backed
fail-closed removal, typed binding-row choices, workflow-effective readiness/
recovery state, and focused safe CRUD/default/readiness coverage added;
App-target start approval is rechecked after asynchronous catalog work; scanner
equivalence is complete while full cross-surface redaction coverage remains pending

**Write scope**:

- `Sources/RielaAppSupport/RielaAppKaibaInstanceModels.swift` (new)
- `Sources/RielaAppSupport/RielaAppKaibaInstanceController.swift` (new)
- `Sources/RielaAppSupport/RielaAppKaibaBindingController.swift` (new)
- `Sources/RielaAppSupport/RielaAppKaibaRecoveryAction.swift` (new)
- `Tests/RielaAppSupportTests/RielaAppKaibaInstanceControllerTests.swift` (new)
- `Tests/RielaAppSupportTests/RielaAppKaibaBindingControllerTests.swift` (new)
- `Tests/RielaAppSupportTests/RielaAppKaibaRecoveryActionTests.swift` (new)

**Tasks**:

- [x] Wrap the shared store/scanner/readiness APIs in testable sendable use cases
  for list/add/edit/enable/default/test/remove and affected references.
- [x] Expose only safe display fields, environment-variable presence, warnings,
  closed readiness state, fixed copy, timestamp, one typed recovery action, and
  AppKit-independent binding-row state.
- [x] Execute file/client work off the main actor; cancel tests on selection or
  profile changes and suppress results whose instance ID/config revision no
  longer matches. AppKit regressions cover stale selection and profile results;
  final start-approval snapshot changes are covered in App behavior regressions.
- [x] Build per-workflow-instance Kaiba node rows from registered `kaiba/*`
  nodes, effective definitions/patches, and the shared catalog: default,
  enabled named, disabled unavailable, and missing-ID states.
- [x] Merge/reset only `addon.config.kaibaInstanceId`, prune empty wrappers, and
  preserve every unrelated node-patch field. Coordinate the write with the
  catalog lock and the existing daemon preference transaction.
- [x] Compute start readiness and exactly one accepted recovery action without
  using historical `lastTest` as authorization.
- [x] Test App process-environment vs workflow effective-environment credential
  behavior.
- [x] Test CLI/App removal-reference sequence equivalence against identical
  scanner roots.

**Deliverables**:

- Thin-AppKit-ready state/actions with deterministic race and recovery behavior.

**Depends on**: K2.

**Parallelization**: May run with K3, K4, and K5 after K2; no shared writes.

**Verification**:

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'RielaAppKaibaInstanceControllerTests|RielaAppKaibaBindingControllerTests|RielaAppKaibaRecoveryActionTests'
```

## K7. Native Kaiba Settings And Per-Node Binding UI

**Status**: IN_PROGRESS — native Kaiba sidebar/list, safe instance CRUD/default/
removal confirmation, per-node binding editor, workflow-effective Start gating,
and typed recovery guidance added; cross-surface visual evidence remains pending

**Write scope**:

- `Sources/RielaApp/DaemonWorkflowWindowController.swift`
- `Sources/RielaApp/DaemonWorkflowWindowController+Types.swift`
- `Sources/RielaApp/DaemonWorkflowWindowController+SettingsShell.swift`
- `Sources/RielaApp/DaemonWorkflowWindowController+Navigation.swift`
- `Sources/RielaApp/DaemonWorkflowWindowController+KaibaPane.swift` (new)
- `Sources/RielaApp/DaemonWorkflowWindowController+KaibaBindings.swift` (new)
- `Sources/RielaApp/DaemonWorkflowWindowController+DetailView.swift`
- `Sources/RielaApp/EntryPoint.swift`
- `Sources/RielaApp/EntryPoint+KaibaInstances.swift` (new)
- `Sources/RielaApp/EntryPoint+DaemonNodePatch.swift`
- AppKit layout/accessibility tests under `Tests/RielaAppSupportTests/`

**Tasks**:

- [x] Add a `Kaiba` sidebar destination and native Settings-style list/detail/
  editor states with normal content inset, grouped rows, compact-width behavior,
  icon-only toolbar controls, tooltips, and accessibility labels.
- [x] Implement safe add/edit auth choices, environment-variable name/presence,
  enable/disable, set-default, generic test, last-test rendering, explicit
  remote HTTP/unauthenticated warnings, and no secret input or label.
- [x] Show removal references and exact Cancel/Remove Anyway semantics; disable
  both removal paths on scan failure and leave forced-removal bindings dangling.
- [x] Add a Kaiba Nodes section to workflow-instance detail. Display default,
  enabled choices, disabled unavailable choices, missing-ID error state, reset,
  and the accepted one-action recovery guidance.
- [x] Disable Start when current static credential/instance/readiness preflight
  fails, but do not confuse process-level generic test with workflow effective-
  environment readiness.
- [x] Keep asynchronous work outside the main actor and prevent stale selection,
  profile, edit-revision, or probe completion from changing visible state.
- [x] Re-resolve the preference, workflow candidate, and catalog after final
  asynchronous preflight work before App runtime start; reject any changed
  approval snapshot.
- [x] Extend settings-navigation, layout, selection, constrained-width,
  interaction, and accessibility tests without growing existing large test
  files past 1,000 lines.

**Deliverables**:

- Complete native instance management and per-node selection with CLI-equivalent
  policy and results.

**Depends on**: K6; K4 for final Start gate wiring.

**Verification**:

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'RielaAppKaiba|RielaAppSettings|DaemonWorkflowNodePatchTests'
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --product RielaApp
```

## K8. Compatibility, Redaction, And Failure-Mode Hardening

**Status**: IN_PROGRESS — automated compatibility, fail-closed, transport,
redaction, and log-source audits pass; screenshot inspection remains externally
blocked by the current macOS capture permission

**Write scope**:

- `Tests/RielaKaibaSupportTests/KaibaRedactionTests.swift` (new)
- `Tests/RielaKaibaAddonsTests/KaibaCompatibilityAndRedactionTests.swift` (new)
- `Tests/RielaCLITests/KaibaInstanceCommandRedactionTests.swift`
- `Tests/RielaAppSupportTests/RielaAppKaibaRedactionTests.swift` (new)
- The smallest owning production files from K1-K7 when a test exposes a defect;
  the owning K-task applies each production fix to prevent overlapping writes.

**Tasks**:

- [x] Test `noteRoot`, `configPath`, `databasePath`, `KAIBA_NOTE_ROOT`, and
  `RIELA_NOTE_ROOT` as inert values that emit only
  `legacy_kaiba_local_config_ignored` and never affect routing/output.
- [x] Test every legacy remote assertion exact-match rule, independent
  contradiction, malformed assertion type, and
  `legacy_kaiba_connection_mismatch` before readiness/transport.
- [x] Place a unique bearer sentinel through persistence/reflection, CLI
  stdout/stderr/JSON, add-on output, and AppSupport catalog output. Any
  occurrence is blocking.
- [x] Extend sentinel coverage to endpoint-path rejection, SDK and GraphQL
  errors, transport failures, and typed fixed-copy App labels/alerts.
- [ ] Capture and inspect log and screenshot sentinel coverage.
- [x] Verify remote HTTP and remote unauthenticated require their separate
  explicit opt-ins; TLS validation cannot be disabled and redirects remain SDK-
  refused.
- [x] Verify unknown/disabled/missing/invalid instances, missing credentials,
  incompatible servers, memory capability failures, scan failures, concurrent
  edits, cancellation, and transport failures all fail closed with one fixed
  recovery action.
- [x] Audit logs to allow only operation, workflow/step/node identity, instance
  ID, stable code, duration, and safe endpoint description.

**Deliverables**:

- Cross-surface proof that secrets and unsafe server diagnostics do not escape.
- Compatibility preserved only through the intentional accepted rules.

**Depends on**: K3-K7 production paths.

**Verification**:

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter KaibaRedactionTests
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter KaibaCompatibilityAndRedactionTests
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'KaibaEndpointAuthTests|KaibaWorkflowPreflightTests|RielaAppKaibaWorkflowReadinessTests'
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter KaibaInstanceCommandRedactionTests
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaAppKaibaRedactionTests
```

## K9. Integration, User Journeys, Documentation, And Package Digests

**Status**: IN_PROGRESS — README now documents the named HTTP instance contract;
isolated CLI/App catalog, binding, force-remove, fail-closed, repair, readiness,
read, GraphQL, ingest, and memory journeys are covered while package digest review remains pending

**Write scope**:

- `README.md`
- `.codex/skills/riela-impl-workflow/SKILL.md` only if repository-facing Kaiba
  guidance/evidence must be refreshed
- affected files under `examples/`
- `Tests/RielaCLITests/RielaExampleCatalog.swift`
- `Tests/RielaCLITests/RielaExampleParityTests.swift`
- `riela-package.json` if any workflow, prompt, script, or skill changed
- this implementation plan's task status/progress log

**Tasks**:

- [x] Build the CLI and perform an isolated catalog/App journey: list an empty
  catalog; add local and remote instances; update and set default; bind a Kaiba
  node; block referenced removal; force removal; observe dangling binding fail
  closed; and repair it through the shared App-support catalog.
- [x] Run isolated readiness/read, arbitrary GraphQL, ingest, and memory
  operations against the deterministic Kaiba HTTP fixture.
- [x] Update README/help/examples to configure a default once, select stable IDs,
  use environment-variable names, explain secure transport opt-ins, and remove
  deprecated local-store inputs or replace remote routing fields with bindings.
- [x] Preserve unrelated dirty example/test changes and specifically reconcile
  `RielaExampleCatalog.swift`, `RielaExampleParityTests.swift`, and
  `examples/note-rag-retrieval-fusion/` rather than replacing them.
- [ ] Refresh `.codex/skills/riela-impl-workflow/SKILL.md` with only durable,
  accepted behavior and final review evidence if directly affected. If that
  skill or any workflow/prompt/script changes, refresh `riela-package.json`
  digests and verify them with repository tooling.
- [x] Remove disposable scratch output from
  `tmp/kaiba-api-instances-impl/`; retain only evidence explicitly needed for
  the ongoing workflow and never stage it.

**Deliverables**:

- Discoverable CLI/App guidance and examples matching the shipped contract.
- Recorded real-operation evidence with no secret values.

**Depends on**: K3-K8.

**Verification**:

```bash
mkdir -p tmp/kaiba-api-instances-impl/home tmp/kaiba-api-instances-impl/project tmp/kaiba-api-instances-impl/app-root
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter KaibaInstanceCommandTests
.build/debug/riela kaiba instance --help
.build/debug/riela kaiba instance list --output json
rg --files -g 'riela-package.json' -g '!tmp/**'
```

The `KaibaInstanceCommandTests` journey must invoke the production command
runner with its injected home URL to perform the complete isolated CRUD/default/
test/remove sequence without changing the operator's real home. Run readiness
and representative read/GraphQL/ingest/memory paths against the isolated
deterministic Kaiba HTTP fixture established by the implementation tests. The
compiled binary checks are read-only. Record expected operational failures
separately from command-contract failures; never place a bearer value in a
command argument or evidence file.

## K10. Atomic Cutover And Final Verification

**Status**: IN_PROGRESS — focused support/add-on verification, file-size,
inventory, forbidden-symbol, and SwiftLint checks passed; clean-checkout test
and screenshot-inspection gates remain pending

**Tasks**:

- [x] Run focused suites first, then the full build/test gate with the explicit
  Xcode toolchain. Fix work-package failures and document genuinely pre-existing
  failures without weakening checks.
- [x] Run SwiftLint with Xcode environment and `--no-cache`; fix introduced
  findings rather than suppressing them.
- [x] Inventory all non-generated Swift files and split meaningful
  responsibilities until every file is below 1,000 lines. Do not create
  mechanical numbered splits.
- [x] Prove add-on inventory equality and zero forbidden local-store symbols.
- [x] Launch `.build/arm64-apple-macosx/debug/RielaApp` directly with isolated
  `tmp/rielaapp-ui-review/` roots. Do not use `.build/debug/RielaApp.app` unless
  its executable is proven current.
- [ ] Capture list, detail, editor, binding, missing/disabled/error, force-remove,
  and remote-warning windows by CGWindow ID at normal and constrained widths;
  inspect every screenshot, including sentinel absence.
- [x] Re-run `git status --short`, compare against K0 baseline, preserve all
  unrelated changes, run `git diff --check`, and leave every work-package file
  unstaged and uncommitted.
- [x] Update this plan's completion boxes and progress log with exact commands,
  results, screenshot paths/window IDs, executable path, remaining risks, and
  review-required deviations.

**Deliverables**:

- A complete automated/manual evidence matrix tied to every completion
  criterion and accepted design verification category.
- A preserved, unstaged, uncommitted worktree ready for independent
  implementation review.

**Depends on**: K0-K9.

**Required verification commands**:

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaKaibaSupportTests
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaKaibaAddonsTests
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaCLITests
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaAppSupportTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint --quiet --no-cache
comm -3 <(rg -o 'kaiba/[a-z][a-z0-9-]*' Sources/RielaAddons/RielaAddons.swift | sort -u) <(rg -o 'kaiba/[a-z][a-z0-9-]*' Sources/RielaKaibaAddons/KaibaNoteAddonDispatch.swift | sort -u)
rg -n 'import (AppCore|AppGraphQL)|NoteService|SQLiteNoteDatabaseDriver|GraphQLHTTPDocumentClient|KaibaConfigurationLoader|ImportDocumentConverter|AgentGatewayImageOCRConverter|AITranslationService|KAIBA_NOTE_ROOT|RIELA_NOTE_ROOT' Sources/RielaKaibaAddons
rg --files Sources Tests -g '*.swift' | xargs wc -l | sort -nr | head -25
.build/debug/riela kaiba instance --help
.build/debug/riela kaiba instance list --output json
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --product RielaApp
.build/arm64-apple-macosx/debug/RielaApp --app-root tmp/rielaapp-ui-review/app-root --home-root tmp/rielaapp-ui-review/home-root --project-root "$PWD" --open-workflows --no-autostart-daemons
git diff --check
git status --short
```

The inventory command must report no differences; the forbidden-symbol command
must report no matches. UI evidence must record the direct executable and exact
window IDs. No commit or push is part of this plan.

## Dependency Summary

| Task | Depends on | Blocks |
| --- | --- | --- |
| K0 | accepted editable Kaiba SDK worktree; published revision is a release gate | K1 |
| K1 | K0 | K2 |
| K2 | K1 | K3, K4, K5, K6 |
| K3 | K2 | K8, K9 |
| K4 | K2 | K7, K8, K9 |
| K5 | K2; K4 for end-to-end automatic keys | K8, K9 |
| K6 | K2 | K7 |
| K7 | K6, K4 | K8, K9 |
| K8 | K3-K7 | K9 |
| K9 | K3-K8 | K10 |
| K10 | K0-K9 | completion |

External/runtime dependencies:

- The explicitly authorized SwiftPM editable checkout is the implementation and
  verification source for this work package. Before a clean-checkout commit or
  release, a published pinned Kaiba revision must export the same accepted
  `KaibaClient` API. An SDK contract gap returns to design/review; it must never
  be bridged by local-store access.
- Local and remote verification require reachable Kaiba HTTP(S) fixtures or an
  injected `KaibaHTTPTransporting` test transport. Automated tests must not
  depend on a live personal server.
- Current-executable macOS UI evidence requires an interactive GUI session with
  Screen Recording permission sufficient for window-ID capture.

## Parallelizable Tasks

- After K2, K3 (CLI), K4 (runtime), K5 (add-ons), and K6 (AppSupport) are
  parallelizable because their production and test write scopes are disjoint.
- Within K5, read operations, write operations, arbitrary GraphQL,
  ingest/document, and memory can be parallelized only after one owner freezes
  shared catalog/bridge/idempotency interfaces; each worker must own distinct
  files.
- K7 AppKit work is not parallel with another writer touching
  `DaemonWorkflowWindowController*`, `EntryPoint*`, or related AppKit tests.
- K8-K10 are integration/review gates and are not parallel implementation work.

## Completion Criteria

**Current reconciliation (2026-09-05)**: These are package-level release gates,
so their checkboxes remain open until every subcondition is verified on a clean
published KaibaClient dependency. Implemented portions are recorded in K0-K8
task boxes and dated entries below; the clean published-dependency and screenshot
gates are explicitly retained as open work rather than implied complete.

- [ ] The strict user-wide catalog persists IDs, names, normalized HTTP(S)
  endpoints, env-name-only auth or unauthenticated mode, enabled state, exactly
  one enabled default when non-empty, safe historical test state, and no token
  values.
- [ ] CLI list/show/add/update/remove/test/set-default matches the accepted text,
  JSON, ordering, stdout/stderr, exit, force, and fixed-diagnostic contracts.
- [ ] Every declared `kaiba/*` node resolves only explicit stable ID or absent-
  binding default, snapshots before execution, and fails closed before business
  transport for every invalid/readiness/capability condition.
- [ ] All 19 registered Kaiba add-ons use `KaibaClient` over HTTP(S), preserve
  accepted payload compatibility/idempotency, and have no direct or fallback
  store/service path.
- [ ] RielaApp supports instance CRUD/test/default/removal and every-node binding
  with deterministic recovery, accessibility, stale-task suppression, and the
  same scanner/policy/results as CLI.
- [ ] Sentinel tests and screenshot inspection find no credential/server-body/
  unsafe-path leaks in persistence, logs, reflection, CLI, add-on, or UI output.
- [ ] Focused and full Swift tests, build, SwiftLint, inventory/source gates,
  CLI journeys, current-executable App UI evidence, file-size checks,
  `git diff --check`, and package digest verification when applicable pass.
- [ ] README/help/examples and durable workflow guidance describe the shipped
  behavior; scratch artifacts are cleaned; all pre-existing dirty work is
  preserved; changes remain unstaged, uncommitted, and unpushed.
- [ ] Any SDK/payload incompatibility discovered during implementation has
  returned to design/adversarial review rather than creating an unaccepted
  divergence or local fallback.

## Progress Log Expectations

For every implementation session, append one dated entry below containing:

- tasks/checklist items completed and still in progress;
- exact repository-relative files changed, including overlap with the K0 dirty
  baseline;
- exact verification commands and pass/fail/blocked status;
- test counts and relevant fixture/screenshot evidence paths;
- blockers, pre-existing failures, and residual risks with owner/trigger;
- any proposed design divergence and its review state; and
- confirmation that no files were staged, committed, or pushed.

Do not mark a task done from compilation alone when its contract requires a real
CLI/App journey, transport assertion, failure-path test, or screenshot.

## Progress Log

### 2026-09-05 — Step 6 Review-Finding Repair: Published-Pin Check, App Surface, And Compatibility Evidence

- Addressed the dependency finding at `Package.swift:62`: the pin is the
  published `kaiba` `v0.1.12` revision (`b436b91d…`), verified with
  `git ls-remote`, and no absolute dependency path was added to the manifest.
  The published source still does **not** contain `KaibaClient`; the temporary
  SwiftPM editable checkout under `Packages/kaiba` is used only to build this
  uncommitted implementation and must be removed before clean-checkout review.
- Added `RielaAppKaibaInstanceController` as the App-support façade for the
  shared strict catalog. It exposes safe list/add/update/default/remove/test
  actions and stores only normalized safe readiness state. The App now exposes
  a `Kaiba` settings sidebar destination that lists only endpoint/auth-env-name
  state and executes generic readiness through the current process environment.
- `KaibaKnowledgeAddonTests` now executes every registered note add-on through
  the injected HTTP fixture and asserts exact top-level/nested values, key sets,
  JSON types, and omitted provider/local-path fields for search, graph,
  attachments, comments, memos, tags, GraphQL, ingest, document import, and
  conversation output.
- README removed the obsolete direct/local-store description and documents
  named HTTP instances, default/binding semantics, credential redaction, and
  inert legacy local configuration fields.
- Passed: `swift test --filter RielaAppKaibaInstanceControllerTests` (1),
  `swift test --filter KaibaKnowledgeAddonTests` (6), and
  `swift test --filter RielaKaibaSupportTests` (25), all with zero failures.
  `swift build --product RielaApp` also passed while the temporary authorized
  Kaiba editable checkout was active. The broad `swift test --filter
  RielaCLITests` run was deliberately stopped after more than three minutes
  without completion, so it is not verification evidence. SwiftLint completed
  with pre-existing warning-only findings outside the changed files.
- Current-executable attempt: launched
  `.build/arm64-apple-macosx/debug/RielaApp` with isolated
  `tmp/kaiba-ui-review/{app-root,home-root}` and found window ID `3199`; macOS
  denied the window screenshot (`could not create image from window`). The
  launched isolated process was stopped. This is a Screen Recording evidence
  gap, not a UI pass.
- Cleanup: `swift package unedit kaiba` removed `Packages/kaiba`; the worktree
  no longer contains an untracked editable-package path. Consequently the
  clean-checkout build remains correctly blocked until Kaiba publishes a
  revision containing `KaibaClient`.
- Remaining review blockers: published KaibaClient availability, bounded
  Riela-owned non-text OCR/translation, full native management/binding UI,
  current-executable screenshots, all five pre-existing Swift files over 1,000
  lines, complete test/lint gates, and clean-checkout validation.

### 2026-09-05 — Step 6 Revision: HTTP-Only Kaiba Add-On Cutover

- K5 is **IN_PROGRESS**. `KaibaAddonCatalog` now requires the resolved client
  captured by preflight for every registered note and memory add-on. The note,
  attachment, comment, graph, ingest, conversation, arbitrary GraphQL, and
  long-term-memory paths invoke `KaibaClient` typed operations or its arbitrary
  GraphQL API; production catalog dispatch has no local store, configuration,
  or service construction path. Ingest and memory use explicit keys or a
  length-prefixed SHA-256 runtime-identity key.
- The `RielaKaibaAddons` target now depends on `KaibaClient`, not Kaiba
  `AppCore` or `AppGraphQL`. Removed the old production local-store support
  files and retained a structural Riela/SDK JSON bridge only.
- Files changed in this revision: `Package.swift`,
  `Sources/RielaKaibaAddons/KaibaAddonCatalog.swift`,
  `KaibaNoteAddons.swift`, `KaibaLongTermMemoryAddons.swift`,
  `KaibaRemoteGraphQLAddon.swift`, `KaibaJSONBridge.swift`, and
  `KaibaInputValidation.swift`; obsolete local-store implementation files were
  removed. Existing dirty files were not reverted or staged.
- Passed: `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --target RielaKaibaAddons`,
  `swift test --filter KaibaBoundaryTests` (6 tests),
  `swift test --filter 'KaibaWorkflowPreflightTests|KaibaSessionPreflightTests'`
  (5 tests), `git diff --check`, the K5 forbidden-symbol source gate (zero
  matches), and the registered add-on inventory comparison (zero differences).
  The initial test retry had an SDKROOT typo; the later commands used the
  correct Xcode SDK path. SwiftLint completed after the source edit with
  existing repository warnings plus introduced style warnings, but no remaining
  error-level finding after the long line was split.
- Remaining blockers: K5 needs deterministic HTTP transport fixtures for every
  operation and lost-response/replay coverage; K6-K7 App support/UI, current
  executable screenshots, K8-K10 integration gates, and docs are untouched.
  The pinned published Kaiba revision still lacks `KaibaClient`; the local
  editable checkout is only an implementation aid and cannot make a clean
  checkout resolve until Kaiba publishes the SDK revision. No files were
  staged, committed, or pushed.

### 2026-09-05 — Step 6 Revision: Binding Scan And Safe Removal

- K2 remains **IN_PROGRESS**. Added a dependency-free, fail-closed binding
  scanner that examines the finite project, user, App-profile, and registered
  external workflow/package roots; it avoids symlink traversal, accepts only
  `kaiba/*` authored `addon.config.kaibaInstanceId` bindings, and returns
  deterministic reference DTOs. Malformed or unreadable scanned workflow JSON
  fails the scan without deleting an instance.
- K3 remains **IN_PROGRESS**. `riela kaiba instance remove` now scans while the
  catalog mutation lock is held, blocks ordinary removal when references exist,
  and lets `--force` delete only the catalog row while returning sorted
  `affectedReferences`. The bindings themselves remain unchanged.
- Files changed: `Sources/RielaKaibaSupport/KaibaBindingScanner.swift`,
  `Sources/RielaCLI/KaibaInstanceCommandRunner.swift`,
  `Tests/RielaKaibaSupportTests/KaibaBindingScannerTests.swift`,
  `Tests/RielaCLITests/KaibaInstanceCommandTests.swift`, and this plan.
  Verification passed:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'KaibaBindingScannerTests|KaibaInstanceCommandTests'`
  (7 focused tests, zero failures) and
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --target RielaCLI`.
  Remaining K2 work: durable instance-patch source coverage once node patches
  can bind add-on configuration, immutable execution snapshots, and workflow/
  direct-node preflight. K4-K10 and the clean-checkout KaibaClient pin remain
  incomplete. No files were staged, committed, or pushed.

### 2026-09-05 — Step 6 Revision: Remove Failure And Syntax Ordering Repair

- K3 remains **IN_PROGRESS**. Every Kaiba instance command now validates its
  command-specific syntax before any catalog read used to discover a selected
  instance. The fixed `kaiba_instance_in_use` message and next action return
  usage exit code 2. Forced text removal emits the stable `Removed` line plus
  one deterministic `AFFECTED` line per sorted reference.
- Focused CLI coverage verifies the fixed in-use JSON contract, forced text
  references, and invalid syntax failure before catalog selection. K2 scanner
  completeness (instance-patch files, duplicate-key rejection, and scan-change
  detection) remains outstanding; K4-K10 remain incomplete.
- Files changed: `Sources/RielaCLI/KaibaInstanceCommandRunner.swift`,
  `Tests/RielaCLITests/KaibaInstanceCommandTests.swift`, and this plan. No
  files were staged, committed, or pushed.

### 2026-09-05 — Step 6 Revision: Scan Completeness And Syntax Preflight

- K2 remains **IN_PROGRESS**. Binding discovery now reads project, user,
  profile, and registered-project instance files plus profile preferences,
  extracts only Kaiba add-on instance-patch IDs, deduplicates canonical source
  paths, rejects duplicate-key JSON, and fails if a scanned file changes
  between read and projection. Execution snapshots and runtime preflight remain
  incomplete.
- K3 remains **IN_PROGRESS**. Contradictory update flags, no-op updates,
  malformed update booleans, and non-absolute removal paths fail before any
  catalog lookup. Tests use an unavailable `HOME=/dev/null` catalog location
  to prove invalid syntax retains the usage result.
- Files changed: `Sources/RielaKaibaSupport/KaibaBindingScanner.swift`,
  `Sources/RielaKaibaSupport/KaibaInstanceStore.swift`,
  `Sources/RielaCLI/KaibaInstanceCommandRunner.swift`,
  `Tests/RielaKaibaSupportTests/KaibaBindingScannerTests.swift`,
  `Tests/RielaCLITests/KaibaInstanceCommandTests.swift`, and this plan. No
  files were staged, committed, or pushed.

### 2026-09-05 — Step 6 Revision: Whole-Scan Source Snapshot

- K2 remains **IN_PROGRESS**. The scanner now snapshots every finite root,
  profile registration, instance/profile-state file, and discovered
  `workflow.json` source before scanning, then re-enumerates and compares the
  complete source set and bytes before returning references. A changed root,
  registration, source membership, or source content fails closed; ordinary
  and forced removal therefore cannot consume a partial declared-root scan.
- Added a deterministic scanner hook test that removes one workflow source and
  adds another after the initial snapshot; scanning returns
  `kaiba_binding_scan_failed`. Corrected the earlier
  `KaibaBindingScannerTests|KaibaInstanceCommandTests` evidence from 36 to 7
  tests, matching the command's recorded result at that revision.
- Verification passed:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter KaibaBindingScannerTests`
  (7 tests, zero failures) and
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'RielaKaibaSupportTests|KaibaInstanceCommandTests|WorkflowAddonExecutionIdentityTests|KaibaLongTermMemoryAddonTests'`
  (40 tests, zero failures). The full Swift suite, RielaApp build, and
  executable UI verification remain blocked by incomplete K2/K4-K10 work.
- Files changed: `Sources/RielaKaibaSupport/KaibaBindingScanner.swift`,
  `Tests/RielaKaibaSupportTests/KaibaBindingScannerTests.swift`, and this plan.
  No files were staged, committed, or pushed.

### 2026-09-05 — Step 6 Revision: Immutable Binding Projection

- K2 remains **IN_PROGRESS**. Binding references are now projected exclusively
  from the initial immutable source snapshot, then the full root/source set is
  revalidated before return. A source changed during projection and restored
  before final revalidation cannot suppress an in-use reference.
- Added a deterministic change-parse-restore regression: the source changes
  after snapshot capture, is restored before final validation, and the original
  captured binding remains reported. Execution snapshots and workflow/direct-
  node preflight remain incomplete.
- Files changed: `Sources/RielaKaibaSupport/KaibaBindingScanner.swift`,
  `Tests/RielaKaibaSupportTests/KaibaBindingScannerTests.swift`, and this plan.
  This revision also rejects fixed project/user/profile-state files that are
  symlinks or resolve outside their declared root during either snapshot, with
  project and user `instances.json` symlink-escape regression coverage.
  Verification passed:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter KaibaBindingScannerTests`
  (9 tests, zero failures),
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'KaibaBindingScannerTests|KaibaInstanceCommandTests'`
  (11 tests, zero failures), and
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'RielaKaibaSupportTests|KaibaInstanceCommandTests|WorkflowAddonExecutionIdentityTests|KaibaLongTermMemoryAddonTests'`
  (42 tests, zero failures). Also passed:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --target RielaKaibaSupport && /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --target RielaCLI && /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --product riela`,
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint --quiet --no-cache`
  (existing unrelated warnings only), `git diff --check`, and
  `wc -l Sources/RielaKaibaSupport/KaibaBindingScanner.swift Tests/RielaKaibaSupportTests/KaibaBindingScannerTests.swift Sources/RielaCLI/KaibaInstanceCommandRunner.swift Tests/RielaCLITests/KaibaInstanceCommandTests.swift`.
  The full Swift suite was **not run** (the command is runnable, but the
  atomic feature remains incomplete); the RielaApp build was **not run**
  (App integration is absent); executable UI verification and workflow/direct-
  node preflight are **blocked** (the required UI and preflight implementations
  do not exist). The clean-checkout KaibaClient pin and forbidden-dependency
  gates still fail.
  No files were staged, committed, or pushed.

### 2026-09-05 — Step 6 Revision: Immutable Resolved-Client Snapshot

- K2 remains **IN_PROGRESS**. Added `KaibaExecutionSnapshot`, an immutable
  support-boundary projection that resolves explicit bindings/default fallback
  against one validated catalog before execution, constructs one `KaibaClient`
  per distinct selected instance, and never re-reads the catalog when a caller
  asks for a captured client. Its generic readiness pass probes each captured
  client once in deterministic capture order.
- Added isolated injected-transport coverage for default fallback, explicit
  unknown-ID failure before execution, stable deduplication, and readiness
  result ordering. Workflow/direct-node preflight does not yet construct or
  retain this snapshot, and long-term-memory capability probing remains
  unimplemented.
- Files changed: `Sources/RielaKaibaSupport/KaibaExecutionSnapshot.swift`,
  `Tests/RielaKaibaSupportTests/KaibaExecutionSnapshotTests.swift`, and this
  plan. Verification passed:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter KaibaExecutionSnapshotTests`
  (3 tests, zero failures) and
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'KaibaExecutionSnapshotTests|KaibaBindingScannerTests|KaibaInstanceCommandTests'`
  (14 tests, zero failures),
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'RielaKaibaSupportTests|KaibaInstanceCommandTests|WorkflowAddonExecutionIdentityTests|KaibaLongTermMemoryAddonTests'`
  (45 tests, zero failures), and
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --target RielaKaibaSupport`.
  `git diff --check` passed; `wc -l
  Sources/RielaKaibaSupport/KaibaExecutionSnapshot.swift
  Tests/RielaKaibaSupportTests/KaibaExecutionSnapshotTests.swift` reported 103
  and 90 lines. SwiftLint passed with existing baseline warnings and no
  changed-file finding:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint --quiet --no-cache`.
  The full Swift suite and RielaApp build were not run; executable UI
  verification remains blocked because App integration is absent. The
  `git -C Packages/kaiba cat-file -e
  b436b91d39a5eaee8243a43096dd13f1e8ad819e:Sources/KaibaClient` clean-
  checkout gate and the `rg -n 'import (AppCore|AppGraphQL)|NoteService|SQLiteNoteDatabaseDriver|GraphQLHTTPDocumentClient|KaibaConfigurationLoader|ImportDocumentConverter|AgentGatewayImageOCRConverter|AITranslationService|KAIBA_NOTE_ROOT|RIELA_NOTE_ROOT' Sources/RielaKaibaAddons`
  forbidden-production-dependency gate remain failed. No files were staged,
  committed, or pushed.

### 2026-09-05 — Step 6 Revision: Workflow And Direct-Node Snapshot Preflight

- K2/K4 remain **IN_PROGRESS**. `KaibaExecutionSnapshot` now accepts immutable
  per-node capability requests, probes ordinary readiness once per captured
  instance, and calls `longTermMemoryNotebook()` exactly once only for selected
  `kaiba/memory-consolidate` or `kaiba/memory-recall` instances. It preserves
  cancellation and reports only fixed Riela-owned preflight states.
- Added `KaibaExecutionPreflight` as the RielaCLI composition boundary. Local
  `workflow run` invokes it after effective node patches/environment resolution
  and before scheduler construction; local `node run`/`rrun` invokes the same
  gate before installed add-on and business execution. Scenario-only runs do
  not perform real business transport. The snapshot is not yet handed to K5
  add-on execution because the required KaibaClient-only migration remains
  incomplete.
- Files changed: `Sources/RielaKaibaSupport/KaibaExecutionSnapshot.swift`,
  `Sources/RielaCLI/KaibaExecutionPreflight.swift`,
  `Sources/RielaCLI/WorkflowRunCommand.swift`,
  `Sources/RielaCLI/NodeCommandRunner.swift`,
  `Tests/RielaKaibaSupportTests/KaibaExecutionSnapshotTests.swift`,
  `Tests/RielaCLITests/KaibaWorkflowPreflightTests.swift`,
  `Tests/RielaCLITests/KaibaNodeRunPreflightTests.swift`, and this plan.
- Verification passed:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'KaibaExecutionSnapshotTests|KaibaWorkflowPreflightTests|KaibaNodeRunPreflightTests'`
  (6 tests, zero failures) and
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --target RielaCLI`.
  Also passed: `git diff --check` and
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint --quiet --no-cache`
  with baseline warnings only and no changed-file finding. All changed Swift
  files remain below 1000 lines.
  Full-suite, RielaApp build, and executable UI verification remain not run or
  blocked by the incomplete K5-K10 scope. The clean-checkout KaibaClient pin
  and forbidden-production-dependency gates remain failed. No files were
  staged, committed, or pushed.

### 2026-09-05 — Step 6 Revision: Effective Binding And Snapshot Handoff

- K2/K4 remain **IN_PROGRESS**. Effective workflow-instance node patches now
  project a stable `kaibaInstanceId` only into the selected `kaiba/*` node's
  effective `addon.config`; workflow preflight reads that projected config
  rather than the unpatched definition. Invalid empty identifiers and binding
  patches targeting a non-Kaiba node fail closed.
- `KaibaExecutionPreflight` now returns its validated immutable snapshot.
  Local workflow runs and direct node runs carry it in the runtime-owned
  `KaibaAddonExecutionContext` through add-on dispatch. The catalog resolves
  the client only from that snapshot and cannot re-read the instance catalog.
  K5 still must use that client for every HTTP operation and remove every
  legacy AppCore/AppGraphQL/local-store path.
- Readiness now preserves `server_rejected` and `incompatible_response` as
  detail codes and maps them to the accepted
  `incompatible_kaiba_instance` preflight diagnostic. Generic stored status
  remains the safe closed `incompatible` value.
- Files changed: `Package.swift`,
  `Sources/RielaKaibaSupport/KaibaReadinessService.swift`,
  `Sources/RielaKaibaSupport/KaibaExecutionSnapshot.swift`,
  `Sources/RielaKaibaAddons/KaibaExecutionContext.swift`,
  `Sources/RielaKaibaAddons/KaibaAddonCatalog.swift`,
  `Sources/RielaCore/WorkflowInstanceModel.swift`,
  `Sources/RielaCore/WorkflowInstanceResolver.swift`,
  `Sources/RielaCLI/KaibaExecutionPreflight.swift`,
  `Sources/RielaCLI/WorkflowRunCommand.swift`,
  `Sources/RielaCLI/WorkflowRunCommand+KaibaPreflight.swift`,
  `Sources/RielaCLI/NodeCommandRunner.swift`,
  `Tests/RielaCoreTests/WorkflowInstanceResolverTests.swift`,
  `Tests/RielaKaibaSupportTests/KaibaExecutionSnapshotTests.swift`, and this
  plan.
- Verification passed:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'KaibaExecutionSnapshotTests|KaibaWorkflowPreflightTests|KaibaNodeRunPreflightTests|WorkflowInstanceResolverTests'`
  (12 tests, zero failures) and
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --target RielaCLI`.
  Full Swift verification, RielaApp build, and executable UI verification
  remain not run or blocked by incomplete K5-K10 scope. The clean-checkout
  KaibaClient pin and forbidden-production-dependency gates remain failed. No
  files were staged, committed, or pushed.

### 2026-09-05 — Step 6 Revision: Session Preflight And Binding Preservation

- K2/K4 remain **IN_PROGRESS**. Session rerun and resume now project effective
  `kaibaInstanceId` patches, construct the workflow-effective environment,
  preflight the immutable snapshot, and carry it through add-on dispatch. A
  production Kaiba dispatch without a validated snapshot now fails closed;
  scenario and unit-test execution retain explicitly scoped non-production
  behavior.
- Effective node-patch merges are now field-preserving. A model/effort override
  no longer drops an inherited Kaiba binding. An explicit
  `kaibaInstanceId: null` reset removes only the binding and preserves the
  remaining add-on config wrapper and unrelated node-patch fields.
- K5 remains **NOT_STARTED**: the snapshot client is still not consumed by
  legacy business operations, and AppCore/AppGraphQL/NoteService/local-store
  paths remain prohibited release blockers. K6-K10, including native binding
  management and current-executable RielaApp verification, remain incomplete.
- Files changed: `Sources/RielaCore/WorkflowInstanceModel.swift`,
  `Sources/RielaCore/WorkflowInstanceResolver.swift`,
  `Sources/RielaKaibaAddons/KaibaExecutionContext.swift`,
  `Sources/RielaKaibaAddons/KaibaAddonCatalog.swift`,
  `Sources/RielaCLI/SessionCommands.swift`,
  `Sources/RielaCLI/SessionCommands+KaibaPreflight.swift`,
  `Sources/RielaCLI/SessionCommands+Support.swift`,
  `Sources/RielaCLI/WorkflowRunCommand.swift`,
  `Sources/RielaCLI/NodeCommandRunner.swift`,
  `Tests/RielaCoreTests/WorkflowInstanceResolverTests.swift`, and this plan.
- Verification passed:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'WorkflowInstanceResolverTests|KaibaExecutionSnapshotTests|KaibaWorkflowPreflightTests|KaibaNodeRunPreflightTests|RielaKaibaAddonsTests'`
  (38 tests, zero failures),
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --target RielaCLI`,
  `git diff --check`, and
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint --quiet --no-cache`
  with baseline warnings only. The file-size command reports every changed
  Swift file below 1,000 lines. The clean-checkout KaibaClient pin and
  forbidden-production-dependency gates remain failed. No files were staged,
  committed, or pushed.

### 2026-09-05 — Step 6 Revision: Explicit Test Scope And Callee Preflight

- K2/K4 remain **IN_PROGRESS**. Missing snapshots now fail closed regardless
  of ambient process environment. Legacy unit fixtures must opt into the
  internal `withMockExecutionForTesting` scope; setting XCTest process
  variables cannot bypass production preflight.
- Workflow, direct-node, and session workflow preflight now share one callee
  resolver with execution and recursively include statically declared
  cross-workflow callees in effective-binding collection, immutable snapshot
  construction, and readiness/capability preflight before parent business
  scheduling. Dynamic callee targets remain intentionally rejected by the
  existing deterministic resolver policy.
- Added regressions for a missing add-on snapshot, an explicit test-only
  mock scope, a callee-only Kaiba binding that fails preflight before caller
  scheduling, and a session effective-binding preflight failure.
- K5 remains **NOT_STARTED**: catalog dispatch now proves that a selected
  snapshot client exists, but legacy implementations still do not consume it
  for HTTP operations. The KaibaClient pin, all add-on migration,
  notebook/document replay transport, App UI, integration journeys, full
  suite, RielaApp build, and current-executable UI verification remain open.
- Files changed: `Sources/RielaKaibaAddons/KaibaExecutionContext.swift`,
  `Sources/RielaKaibaAddons/KaibaAddonCatalog.swift`,
  `Sources/RielaCLI/KaibaExecutionPreflight.swift`,
  `Sources/RielaCLI/WorkflowRunCommand.swift`,
  `Sources/RielaCLI/WorkflowRunCommand+KaibaPreflight.swift`,
  `Sources/RielaCLI/SessionCommands.swift`,
  `Sources/RielaCLI/SessionCommands+KaibaPreflight.swift`,
  `Tests/RielaKaibaAddonsTests/KaibaBoundaryTests.swift`,
  `Tests/RielaKaibaAddonsTests/KaibaEndpointAuthTests.swift`,
  `Tests/RielaKaibaAddonsTests/KaibaKnowledgeAddonTests.swift`,
  `Tests/RielaKaibaAddonsTests/KaibaLongTermMemoryAddonTests.swift`,
  `Tests/RielaCLITests/KaibaWorkflowPreflightTests.swift`,
  `Tests/RielaCLITests/KaibaSessionPreflightTests.swift`, and this plan.
- Verification passed:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'KaibaSessionPreflightTests|KaibaWorkflowPreflightTests|KaibaNodeRunPreflightTests|KaibaBoundaryTests|KaibaEndpointAuthTests|KaibaKnowledgeAddonTests|KaibaLongTermMemoryAddonTests|WorkflowInstanceResolverTests'`
  (38 tests, zero failures),
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --target RielaCLI`,
  `git diff --check`, and
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint --quiet --no-cache`
  with baseline warnings only. `wc -l` confirms every listed changed Swift
  file is below 1,000 lines. The `XCTestConfigurationFilePath` semantic gate
  is now clean. The committed KaibaClient pin and forbidden-production-route
  gates remain failed. No files were staged, committed, or pushed.

### 2026-09-05 — K0 Baseline And Dependency Gate

- Completed: recorded the dirty-worktree, add-on-inventory, diff-stat, pinned
  Kaiba revision, and Swift file-size baseline under
  `tmp/kaiba-api-instances-impl/baseline/`; no baseline artifact is tracked.
- Release-only blocker: committed Kaiba revision
  `b436b91d39a5eaee8243a43096dd13f1e8ad819e` does not export the
  `KaibaClient` product. The sibling checkout exposes it only through
  uncommitted changes. The current untracked `Packages/kaiba` SwiftPM edit is
  an absolute symlink to that checkout; it is explicitly authorized for this
  worktree's source implementation and verification, but must never be
  committed or represented as clean-checkout evidence.
- Verification: `swift package resolve` passed by using the local SwiftPM edit.
  The temporary K0 `RielaKaibaSupport` target made
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --target RielaCLI`
  fail at package planning because the pinned product was absent. After the
  scaffolding was reverted,
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --target RielaKaibaAddons`
  passed against that local edit. These results establish the approved local
  development boundary; they do not validate a clean checkout against the
  committed pin.
- No Riela production code remains from the attempted K0 scaffolding. Existing
  dirty `Package.swift` and `Package.resolved` pin changes are preserved.
  No files were staged, committed, or pushed.

### 2026-09-05 — Step 6 Rerun After Self-Review

- Addressed: restored the progress-entry heading ownership and corrected the
  K0 command evidence. No TypeScript, workflow definition, production Swift,
  test, App, or documentation source was added while the dependency gate is
  unsatisfied.
- Current verification: `swift package show-dependencies --format json` shows
  Kaiba at `/Users/taco/gits/tacogips/kaiba` through untracked
  `Packages/kaiba`; this confirms local development state only. The committed
  dependency declaration still points to the revision that lacks `KaibaClient`.
- Main-agent resolution: the user-scoped task covers both dirty sibling
  repositories and explicitly supplied
  `/Users/taco/gits/tacogips/kaiba` as `kaibaClientLocalDevelopmentPath`.
  Continue K0-K10 against that editable checkout. Publishing and pinning the
  sibling SDK remains required before clean-checkout commit/release, not before
  source implementation. No local path or symlink is to be committed.
- Git finalization: no staging, commit, or push authorized or performed.

### 2026-09-05 — Step 6 Review-Finding Repair: Retry-Stable Operation Identity

- Addressed the Step 7 high finding
  `codex-design-and-implement-review-loop-session-111-step3-design-review-attempt-1-finding-1`:
  `WorkflowAddonExecutionIdentity` now carries a runtime-owned
  `operationExecutionId`. The deterministic runner derives it from the oldest
  member of its newest-to-oldest consecutive unaccepted retry lineage, rather
  than from the current retry's newly allocated `stepExecutionId`.
- The identity validator fails closed with `missing_idempotency_identity` or
  `invalid_idempotency_identity` for absent, empty, duplicate, self-containing,
  or singular/array-inconsistent lineage. The runner converts this to an
  `invalid_input` failure before add-on transport.
- The existing automatic `kaiba/memory-consolidate` key now consumes that
  validated identity and produces the accepted length-prefixed SHA-256 wire
  key. Authored non-empty keys remain exact cross-run keys; absent runtime
  identity fails closed rather than deriving from variables or the retry ID.
- Changed files: `Sources/RielaCore/WorkflowAddonExecution.swift`,
  `Sources/RielaCore/DeterministicWorkflowRunner+Addons.swift`,
  `Sources/RielaKaibaAddons/KaibaLongTermMemoryAddons.swift`,
  `Tests/RielaCoreTests/WorkflowAddonExecutionIdentityTests.swift`,
  `Tests/RielaKaibaAddonsTests/KaibaLongTermMemoryAddonTests.swift`, and this
  plan. The narrow long-term-memory edit was integrated without overwriting its
  pre-existing dirty recall behavior; other Kaiba, package, example, and skill
  changes were not modified.
- Verification passed:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'WorkflowAddonExecutionIdentityTests|KaibaLongTermMemoryAddonTests'`
  (20 tests, zero failures),
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --target RielaCore`,
  `git diff --check`, `git diff --no-index --check /dev/null
  impl-plans/active/kaiba-api-instances.md`, and the 1,000-line file-size gate
  (417, 222, 413, 717, and 284 lines respectively). SwiftLint completed with
  existing warnings outside this change set and none in the changed Core,
  Kaiba, or test files. No files staged,
  committed, or pushed.

### 2026-09-05 — Step 6 Revision: Kaiba Support Boundary And Catalog Foundation

- Added the internal `RielaKaibaSupport` SwiftPM target with the first-party
  `KaibaClient` product and made it available to `RielaCLI`; added its focused
  test target.
- Added a user-wide `<home>/.riela/kaiba/instances.json` model/store foundation
  with closed authentication modes, UUID IDs, enabled/default invariants,
  endpoint-policy checks, safe last-test fields, atomic writes, and no bearer
  token value field.
- Focused verification passed:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaKaibaSupportTests`
  (2 tests, zero failures). K1 remains incomplete until strict decode,
  cross-process locking, and mutation/CLI/readiness integration are implemented.
- Files changed: `Package.swift`, `Sources/RielaKaibaSupport/KaibaInstanceModels.swift`,
  `Sources/RielaKaibaSupport/KaibaInstanceStore.swift`,
  `Tests/RielaKaibaSupportTests/KaibaInstanceStoreTests.swift`, and this plan.
  No files staged, committed, or pushed.

### 2026-09-05 — Step 6 Revision: Catalog Durability And Resolution Foundation

- Addressed the catalog persistence defect identified during self-review:
  decoding now uses the same ISO-8601 date representation as encoding, so a
  saved readiness result reloads successfully. Catalog validation also
  normalizes permitted server-root endpoints to `/graphql`, rejects remote
  unauthenticated configuration without its explicit opt-in, and uses a fixed
  locale for stable display-name uniqueness.
- Added advisory `flock` coordination for same-user catalog mutations and a
  fail-closed `mutate` API; rejected mutations occur before the atomic write.
  Added the first shared resolver/client/readiness seams: an explicit unknown ID
  never falls back to default, bearer values are read only from the supplied
  environment during client construction, and no token value is modeled or
  persisted.
- Files changed: `Sources/RielaKaibaSupport/KaibaInstanceModels.swift`,
  `Sources/RielaKaibaSupport/KaibaInstanceStore.swift`,
  `Sources/RielaKaibaSupport/KaibaInstanceResolver.swift`,
  `Sources/RielaKaibaSupport/KaibaClientFactory.swift`,
  `Sources/RielaKaibaSupport/KaibaReadinessService.swift`,
  `Tests/RielaKaibaSupportTests/KaibaInstanceStoreTests.swift`,
  `Tests/RielaKaibaSupportTests/KaibaInstanceResolverTests.swift`, and this
  plan.
- Verification passed:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaKaibaSupportTests`
  (4 tests, zero failures) and
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --target RielaKaibaSupport`.
  K1/K2 remain in progress; no files were staged, committed, or pushed.

### 2026-09-05 — Step 6 Revision: Endpoint Policy And Transaction Repair

- Addressed self-review finding
  `codex-design-and-implement-review-loop-session-112-step6-self-review-attempt-3-finding-4`:
  loopback detection now requires an exact IPv4/IPv6 loopback address or
  `localhost`; a remote DNS name beginning with `127.` cannot bypass HTTP or
  unauthenticated remote opt-ins.
- Addressed the catalog write-path portion of finding
  `codex-design-and-implement-review-loop-session-112-step6-self-review-attempt-3-finding-5`:
  both public saves and mutations now use the same advisory lock and synchronize
  the replaced file and directory. Duplicate-key detection remains a K1
  requirement because Foundation JSON projection cannot retain duplicate keys.
- Updated the sentinel test to construct a first-party `KaibaClient` using a
  supplied environment credential and assert the sentinel is absent from both
  client reflection and persisted catalog bytes.
- Files changed: `Sources/RielaKaibaSupport/KaibaInstanceModels.swift`,
  `Sources/RielaKaibaSupport/KaibaInstanceStore.swift`,
  `Tests/RielaKaibaSupportTests/KaibaInstanceStoreTests.swift`, and this plan.
  Verification passed:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaKaibaSupportTests`
  (5 tests, zero failures) and `git diff --check`. No files were staged,
  committed, or pushed.

### 2026-09-05 — Step 6 Revision: Named Instance CLI Foundation

- Added the canonical `riela kaiba instance` route and list/show/add/update/
  remove/test/set-default command dispatch backed by the shared user-wide
  catalog. Command execution resolves the home directory through the existing
  injected CLI environment boundary; bearer values remain environment-only.
- Added isolated-home CLI coverage for empty list, add, JSON output, and a
  credential sentinel absent from command output and persisted catalog bytes.
  K3 remains in progress: output DTO/text contracts, complete option policy,
  scanner-backed remove references, and revision-safe readiness persistence
  require the remaining K1/K2 interfaces.
- Files changed: `Sources/RielaCLI/RielaCommand.swift`,
  `Sources/RielaCLI/RielaClientCommandRouter.swift`,
  `Sources/RielaCLI/RielaCLIApplication.swift`,
  `Sources/RielaCLI/KaibaInstanceCommandRunner.swift`,
  `Tests/RielaCLITests/KaibaInstanceCommandTests.swift`, and this plan.
- Verification passed:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --target RielaCLI`,
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter KaibaInstanceCommandTests`
  (one test, zero failures), and the isolated compiled-binary `list`/`add`/
  `list` JSON journey. No files were staged, committed, or pushed.

### 2026-09-05 — Step 6 Revision: CLI Contract And Mutation Error Repair

- Replaced provisional instance text rendering with a deterministic field order
  and rejected unsupported table output; JSON output remains sorted-key,
  newline-terminated, and token-value-free. Contradictory `update`
  authentication or enablement flags now return a usage error before mutation.
- `test` now compares the catalog's persisted transport configuration with the
  snapshot tested over the network before writing `lastTest`; changed endpoint,
  authentication, enabled state, or policy flags fail with
  `stale_kaiba_instance_test`. Catalog mutation closures now preserve their
  domain/usage error rather than reclassifying it as a store-availability error.
- Expanded the isolated-home test to assert fixed show text and contradictory
  update exit semantics. Scanner-backed removal and complete CLI error DTOs
  remain unimplemented K3 work.
- Files changed: `Sources/RielaCLI/KaibaInstanceCommandRunner.swift`,
  `Sources/RielaKaibaSupport/KaibaInstanceStore.swift`,
  `Tests/RielaCLITests/KaibaInstanceCommandTests.swift`, and this plan.
  Verification passed:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter KaibaInstanceCommandTests`
  (one test, zero failures). No files were staged, committed, or pushed.

### 2026-09-05 — Step 6 Revision: Canonical CLI Syntax And DTO Boundary

- K3 remains **IN_PROGRESS**. Replaced the provisional instance-only selector
  and legacy flags with the accepted positional add name, `NAME_OR_ID`
  selectors, `--api-key-env`/`--allow-unauthenticated`, boolean policy flags,
  and `--enable`/`--disable`. Unknown, duplicate, contradictory, and malformed
  options now fail as fixed `invalid_usage` diagnostics.
- Added sorted-key, newline-terminated success and failure DTO envelopes;
  success carries `status`/`operation` plus safe projected instance fields,
  while errors use the fixed code/message/next-action table. Text rendering now
  uses the accepted list/show field order and mutation verbs. Test status is
  persisted only after the existing transport-revision check and exits nonzero
  for non-ready probes.
- Removal now fails closed with `kaiba_binding_scan_failed` rather than deleting
  a possibly referenced instance before K2's coordinated scanner exists. This
  is an intentional incomplete K2/K3 boundary, not completion of force/remove
  semantics. K1-K10 remain incomplete: the pinned Kaiba revision still lacks a
  committed `KaibaClient`; preflight, node binding, all-add-on migration, App
  UI, integration, and executable UI verification are outstanding.
- Files changed: `Sources/RielaCLI/RielaCommand.swift`,
  `Sources/RielaCLI/KaibaInstanceCommandRunner.swift`,
  `Tests/RielaCLITests/KaibaInstanceCommandTests.swift`, and this plan.
  Verification passed:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'RielaKaibaSupportTests|KaibaInstanceCommandTests|WorkflowAddonExecutionIdentityTests|KaibaLongTermMemoryAddonTests'`
  (27 tests, zero failures),
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --target RielaCLI`,
  isolated-home compiled-binary list/add/show JSON checks, SwiftLint (no
  warnings in changed files), `git diff --check`, and changed-file size checks.
  No files were staged, committed, or pushed.

### 2026-09-05 — Step 6 Revision: Shared Catalog Invariants And Stale Mutation Guard

- K1 remains **IN_PROGRESS**. Moved canonical display-name normalization and
  validation to `RielaKaibaSupport`: trimmed NFC, one through 80 characters,
  no control characters, and a shared folded-name key. Persisted catalog rows
  violating those rules now fail as `invalid_kaiba_instance_store` on load.
- Added `mutateInstance(id:expected:)`, which compares the caller snapshot
  while holding the catalog lock and rejects a changed row rather than allowing
  a stale CLI/App edit to overwrite a concurrent transport or policy change.
  CLI update now uses that guarded operation. CLI endpoint syntax is classified
  before authentication-policy validation, preserving the fixed error order.
- K3 remains **IN_PROGRESS**. The CLI now delegates catalog name invariants and
  snapshot mutation semantics to the shared support boundary; binding scanner
  removal behavior and the remaining command contracts are still K2/K3 work.
- Files changed: `Sources/RielaKaibaSupport/KaibaInstanceModels.swift`,
  `Sources/RielaKaibaSupport/KaibaInstanceStore.swift`,
  `Sources/RielaCLI/KaibaInstanceCommandRunner.swift`,
  `Tests/RielaKaibaSupportTests/KaibaInstanceStoreTests.swift`,
  `Tests/RielaCLITests/KaibaInstanceCommandTests.swift`, and this plan.
  Verification passed:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'RielaKaibaSupportTests|KaibaInstanceCommandTests'`
  (nine tests, zero failures). K2 scanner/remove behavior and K4-K10 remain
  incomplete. No files were staged, committed, or pushed.

### 2026-09-05 — Step 6 Revision: Readiness Lifecycle And Kaiba Usage Errors

- K1 remains **IN_PROGRESS**. Added a shared lifecycle transition that resets
  safe readiness history after effective transport changes or re-enablement and
  records the fixed disabled status when an instance is disabled. POSIX
  case-folding no longer collapses distinct diacritics.
- K3 remains **IN_PROGRESS**. CLI update now applies that shared transition;
  disabled `test` persists its no-transport disabled result. Kaiba route and
  subcommand syntax errors now reach the fixed Kaiba stderr/JSON failure
  envelope rather than generic parser output.
- Files changed: `Sources/RielaKaibaSupport/KaibaInstanceModels.swift`,
  `Sources/RielaCLI/KaibaInstanceCommandRunner.swift`,
  `Sources/RielaCLI/RielaCommand.swift`,
  `Tests/RielaKaibaSupportTests/KaibaInstanceStoreTests.swift`,
  `Tests/RielaCLITests/KaibaInstanceCommandTests.swift`, and this plan.
  Verification passed:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'RielaKaibaSupportTests|KaibaInstanceCommandTests'`
  (12 tests, zero failures),
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --target RielaCLI`,
  and `git diff --check`. K2 scanner/remove behavior and K4-K10 remain
  incomplete. No files were staged, committed, or pushed.

### 2026-09-05 — Step 6 Revision: Canonical Readiness And Credential Results

- K1 remains **IN_PROGRESS**. Shared lifecycle updates now canonicalize an
  endpoint before comparing transport state, so equivalent server-root and
  `/graphql` updates retain valid readiness evidence rather than clearing it.
- K3 remains **IN_PROGRESS**. A missing bearer environment variable now
  persists the guarded `missing_credential` readiness result before returning
  its fixed failure. JSON failures include a safely known selected instance ID
  and display name, never credential values. Focused support and CLI tests
  cover both behaviors.
- Files changed: `Sources/RielaKaibaSupport/KaibaInstanceModels.swift`,
  `Sources/RielaCLI/KaibaInstanceCommandRunner.swift`,
  `Tests/RielaKaibaSupportTests/KaibaInstanceStoreTests.swift`,
  `Tests/RielaCLITests/KaibaInstanceCommandTests.swift`, and this plan.
  Verification passed:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'RielaKaibaSupportTests|KaibaInstanceCommandTests'`
  (12 tests, zero failures). K2 scanner/remove behavior and K4-K10 remain
  incomplete. No files were staged, committed, or pushed.

### 2026-09-05 — Step 6 Revision: Strict Catalog Decode Repair

- Added a raw JSON duplicate-key validator before Foundation schema projection,
  so duplicate root or nested object keys cannot be silently collapsed by
  `JSONSerialization`; a duplicate-root-key regression test fails closed with
  `invalid_kaiba_instance_store`.
- Catalog reads now classify a missing catalog as an empty catalog, a malformed
  or non-regular catalog path as invalid, and `lstat`/read failures as
  `kaiba_instance_store_unavailable`. This preserves the stable invalid versus
  unavailable error boundary without logging catalog content.
- Files changed: `Sources/RielaKaibaSupport/KaibaInstanceStore.swift`,
  `Tests/RielaKaibaSupportTests/KaibaInstanceStoreTests.swift`, and this plan.
  Verification passed:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaKaibaSupportTests`
  (six tests, zero failures). No files were staged, committed, or pushed.

### 2026-09-05 — Plan Self-Review

- Completed: compared the plan to the accepted architecture, CLI contract,
  runtime resolution/idempotency rules, App contract, verification contract,
  and current repository boundaries.
- Plan-only defects corrected: removed an unsupported public CLI `--home-root`
  option; clarified that `RielaKaibaSupport` is an internal target rather than a
  new public library product; protected the accepted one-way target dependency
  graph during binding discovery; made the caller-owned document-preparation
  replacement and its no-Kaiba-service source gate explicit; aligned direct-run
  automatic identity with the accepted non-authored fail-closed rule; and made
  K8 redaction tests, K9 isolated CLI commands, and K10 deliverables explicit.
- Design defects: none identified; no design revision is required.
- Git finalization: no staging, commit, or push authorized or performed.

### 2026-09-05 — Plan Creation

- Completed: translated the Step 3-accepted design into K0-K10 tasks,
  deliverables, dependencies, disjoint parallel scopes, atomic completion gates,
  and exact verification commands.
- Files changed: `impl-plans/active/kaiba-api-instances.md` only.
- Review input addressed: Step 3 accepted persistence, CLI, App, binding,
  readiness, KaibaClient migration, compatibility, redaction, verification,
  architecture, runtime flow, Kaiba references, intentional divergences, and
  the unaffected Cursor boundary with no findings or user-QA decision.
- Verification: `git diff --check` passed;
  `git diff --no-index --check /dev/null impl-plans/active/kaiba-api-instances.md`
  reported no whitespace findings (exit 1 is expected for a new file); heading,
  source-reference, decision, and verification-command searches passed; final
  `git status --short` confirmed only this new plan was added by Step 4.
- Dirty-worktree note: the accepted input's overlapping dirty files remain
  implementation constraints; none were modified by plan creation.
- Git finalization: no staging, commit, or push authorized or performed.

### 2026-09-05 — Step 6 Revision: HTTP Fixture and Compatibility Projection

- Replaced store-backed Kaiba add-on tests with an injected `KaibaHTTPTransporting`
  fixture; every registered note add-on executes through `KaibaClient`, and the
  fixture verifies long-term-memory replay keys and source-record metadata.
- Replaced raw SDK-envelope serialization with fixed workflow projections that
  omit control-plane diagnostics and provider-local file paths.
- Restored `kaiba/document-import` as document ingestion with a source-document
  attachment, bounded local-file-root validation, distinct primary/translation
  keys, and compatibility fields. Binary OCR/translation conversion is still a
  caller-owned gap, not a local-store fallback.
- Verification passed: `swift test --filter RielaKaibaAddonsTests` (16 tests),
  `swift test --filter 'KaibaWorkflowPreflightTests|KaibaSessionPreflightTests|KaibaInstanceCommandTests|KaibaNodeRunPreflightTests'` (8 tests),
  `swift test --filter RielaKaibaSupportTests` (25 tests), `swift build`,
  `swift build --product RielaApp`, and `git diff --check`.
- K6-K10 remain incomplete. No files were staged, committed, or pushed.

### 2026-09-05 — Step 6 Revision: Replay And Document Boundary Hardening

- Added fixed compatibility identifiers for HTTP note, attachment, comment,
  graph, and ingest projections; single-note reads again return comments,
  links, and file attachments through typed KaibaClient operations.
- Reworked the injected HTTP fixture to parse request operations and
  idempotency keys, commit a mutation before deliberately losing its response,
  and prove retry replay for notebook ingestion, primary/translated document
  ingestion, and memory consolidation.
- Hardened document preparation with canonical symlink resolution, allowed-root
  enforcement after resolution, regular-file validation, and an 8 MiB input
  bound. OCR and translation remain caller-provided pages because this package
  has no Riela-owned HTTP-capable conversion provider yet.
- Verification passed: `swift test --filter RielaKaibaAddonsTests` (19 tests)
  and `git diff --check`. K5 remains IN_PROGRESS; K6-K10 and the clean-checkout
  KaibaClient pin remain incomplete. No files were staged, committed, or pushed.

### 2026-09-05 — Step 6 Revision: Explicit Replay Contract

- The HTTP fixture now records a canonical body per idempotency key, fails a
  changed body under a previously committed key, and simulates a committed
  mutation whose first response is lost.
- Notebook and document replay tests now assert every retry outcome, identical
  request bodies for each key, separate notebook/primary/translation keys, and
  an explicit-key changed-body conflict. Tag and notebook-attachment fixtures
  also assert restored top-level compatibility fields.
- K5 remains IN_PROGRESS: the accepted Riela-owned OCR/translation conversion
  is not available, while K6-K10 and clean-checkout KaibaClient publication
  remain incomplete. No files were staged, committed, or pushed.

### 2026-09-05 — Step 6 Revision: Complete Add-on Output Contract Matrix

- Added exact payload-key assertions for all 17 registered note/GraphQL/ingest
  add-ons and both registered long-term-memory add-ons. The injected HTTP
  fixture remains the only Kaiba transport used by these tests.
- The matrix locks the shared workflow envelope and each add-on's established
  compatibility fields, including GraphQL compatibility documents and both
  memory operation payloads.
- Verification passed: `swift test --filter RielaKaibaAddonsTests` (20 tests),
  scoped SwiftLint over the changed add-on tests, and `git diff --check`.
  K5 remains IN_PROGRESS because caller-side OCR/translation, clean-checkout
  KaibaClient publication, and K6-K10 are still incomplete. No files were
  staged, committed, or pushed.

### 2026-09-05 — Step 6 Revision: Exact Projection Structures

- Replaced the generic Kaiba operation projection with operation-specific
  compatibility projections. Unrelated SDK fields no longer appear in create,
  update, tag, attachment, comment, ingest, document-import, or conversation
  output.
- Expanded injected-transport coverage to assert every registered add-on's
  exact payload keys, values, nested object keys, and diagnostic/local-path
  absence. The fixture now recognizes the SDK's `KaibaNoteGraph` operation.
- Verification passed: `swift test --filter RielaKaibaAddonsTests` (20 tests),
  `swift test --filter CommandParsingTests` (25 tests), focused Kaiba
  preflight/support suites (33 tests), scoped SwiftLint, and `git diff --check`.
  K5 remains IN_PROGRESS; the upstream KaibaClient pin, OCR/translation, and
  K6-K10 remain incomplete.

### 2026-09-05 — Step 6 Revision: Nested Compatibility Fixtures

- Expanded every registered note/GraphQL/ingest fixture assertion to validate
  concrete nested values, collection counts, JSON types, and absence of unsafe
  provider fields. Arbitrary GraphQL response data retains its requested shape
  while recursively removing diagnostics, local paths, and credential fields.
- Restored the notebook-ingest source-document projection to its explicit
  notebook attachment shape instead of forwarding unrelated attachment fields.
- Verification passed: `swift test --filter RielaKaibaAddonsTests` (20 tests).
  K5 remains IN_PROGRESS because caller-side OCR/translation, clean-checkout
  KaibaClient publication, and K6-K10 remain incomplete.

### 2026-09-05 — Step 6 Revision: App Isolation, Removal Safety, And File Boundaries

- RielaApp now injects the configured `appHomeDirectory` and the project/home/app
  binding scan roots into its Kaiba controller. The pane performs readiness work
  off the main actor and returns UI state changes to the main actor.
- App-support removal now scans bindings and fails closed when references exist;
  callers must explicitly request force removal. The focused App-support test
  passes after this change.
- Split workflow model contracts, backend normalization, package integrity
  models, and mutable-registry activation/consolidation tests into
  responsibility-based files. `WorkflowModel.swift`,
  `WorkflowPackageManifest.swift`, and `WorkflowMutableRegistryTests.swift`
  are below the 1,000-line gate.
- Remaining release blockers: the published Kaiba pin does not export
  `KaibaClient`; two unrelated existing test files still exceed the line gate;
  caller-provided OCR/translation and the full native management/binding UI are
  not complete. No editable Kaiba dependency remains before handoff.

### 2026-09-05 — Step 6 Revision: Final Source-Size Boundaries

- Split GraphQL workflow-registry provider fixtures and Git command-runner
  fixtures into focused test-support files. All non-generated Swift source and
  test files now satisfy the under-1,000-line repository gate.
- Restored the moved mutable-registry activation test's explicit
  `RielaWorkflowRegistry` testable import and corrected introduced lint.
- Focused source-split verification used the temporary Kaiba editable checkout;
  it must be removed before handoff because the published pin remains blocked.

### 2026-09-05 — Step 6 Clarification: Document Preparation Boundary

- Reconciled K5 and README wording with the accepted divergence: conversion,
  OCR, and translation are caller-owned preparation inputs, never an in-process
  fallback or server-local feature. The HTTP add-on accepts prepared pages or
  UTF-8 source text and fails closed for unsupported binary input.

### 2026-09-05 — Step 6 Revision: Native Safe Instance Management

- Added native Kaiba add/edit controls for endpoint, authentication mode,
  environment-variable reference, enablement, and the explicit HTTP safety
  opt-ins. The App never accepts or renders bearer-token values.
- Added enable/disable, set-default, and scan-first removal flows. Removal
  presents affected binding count and makes an explicit `Remove Anyway` choice;
  scan failures fail closed without presenting a destructive action.
- Added App-support coverage for lifecycle/default policy and runtime Kaiba-pane
  accessibility labels/redaction. Verification passed:
  `swift test --filter 'RielaAppKaibaInstanceControllerTests|RielaAppKaibaPaneTests'`
  (3 tests) and `swift build --product RielaApp` using the temporarily
  authorized editable Kaiba checkout. Per-node binding, workflow-effective
  readiness, and visual verification remain pending; the editable checkout
  must be removed before handoff.
- The empty-state Kaiba pane now exposes the same native `Add Kaiba Instance`
  action, so first-run setup does not require a CLI detour.
- Row management actions use compact icon-only controls with tooltips and
  accessibility labels, preserving narrow-pane space without losing action
  discoverability.

### 2026-09-05 — Step 6 Revision: Per-Node Kaiba Binding Editor

- Added a Kaiba Nodes section to each workflow-instance detail surface. It
  discovers registered `kaiba/*` nodes from the selected workflow and exposes
  default reset, enabled named choices, disabled/missing unavailable states,
  and fixed recovery guidance without rendering any secret value.
- Binding changes persist only `nodePatches.<nodeId>.kaibaInstanceId`, retain
  unrelated node-patch fields, prune an empty reset patch when no authored
  binding exists, force a refresh through the existing daemon preference path,
  and restart an active instance through the established configuration-change
  transaction.
- Added AppKit runtime coverage for the node selector and named-selection
  persistence callback. Workflow/catalog loading now runs in a detached task
  with selection-revision suppression before touching the AppKit surface;
  reset persistence receives the already-loaded authored-binding fact and does
  not re-read workflow files on the main actor. The asynchronous test fails on
  a missing selector rather than skipping it.
  Workflow-effective credential readiness, Start gating, stale-probe
  suppression for readiness probes, and current-executable screenshots remain
  pending.

### 2026-09-05 — Step 6 Revision: Default-Reset Persistence Coverage

- Added an App-level persistence regression that proves a default reset removes
  an otherwise-empty node patch and that a reset masking an authored workflow
  binding persists `kaibaInstanceId: null`. The test verifies both in-memory
  state and the profile store after its refresh path.
- Verification passed with the temporary editable Kaiba checkout:
  `swift test --filter 'RielaAppBehaviorRegressionTests|RielaAppKaibaPaneTests|DaemonWorkflowNodePatchTests'`
  (29 tests). Workflow-effective credential readiness, typed recovery actions,
  stale readiness-probe suppression, Start gating, clean-checkout KaibaClient
  publication, and current-executable visual verification remain pending.

### 2026-09-05 — Step 6 Revision: Workflow-Effective Start Readiness

- Added a typed, redacted App readiness result for Kaiba workflow nodes. It
  resolves effective node bindings after patches, builds the immutable Kaiba
  execution snapshot with the selected workflow's effective environment, and
  preflights readiness and long-term-memory capability before start.
- The instance detail disables Start while the probe is current, restores it
  only for ready/non-Kaiba workflows, and gives accessibility users the same
  bounded recovery instruction. Selection revisions and a captured preference
  comparison suppress stale probe completions; the start path independently
  repeats the gate before it persists `active: true`.
- Added a regression for a default binding whose bearer environment variable is
  absent. It verifies the typed credential-recovery result, fails closed, and
  confirms no secret environment-variable name is rendered in the diagnostic.
  Focused verification passed with the temporary editable Kaiba checkout:
  `swift test --filter 'RielaAppBehaviorRegressionTests|RielaAppKaibaPaneTests|DaemonWorkflowNodePatchTests|DaemonWorkflowSupportTests'`
  (71 tests). Clean-checkout KaibaClient publication, full test coverage, and
  current-executable visual verification remain release gates.

### 2026-09-05 — Step 6 Revision: Start-Path Completion And Support Boundary

- Moved the typed Kaiba readiness and recovery model into `RielaAppSupport` so
  AppKit consumes a shared, testable support boundary. Added a support-target
  regression proving a process-only credential is ignored when the workflow's
  effective environment does not provide it.
- Routed imported immediate starts, launch-time autostart, explicit restart,
  rename restart, and configuration-change restart through the same
  workflow-effective preflight. Blocked automatic starts are deactivated to
  avoid repeating an invalid configuration at the next launch.
- K6/K7 now reflect completed readiness/recovery and Start-gating work. Clean
  KaibaClient publication, full suites, package digest availability, and
  current-executable screenshot evidence remain release gates.

### 2026-09-05 — Step 6 Revision: Revision-Bound Start Approval

- Bound every App runtime start path to the exact workflow candidate,
  preference, and Kaiba catalog snapshot that completed preflight. Imported
  immediate starts, launch autostart, manual start/restart, rename restart, and
  configuration-change restart re-resolve the current state before handing a
  runtime its configuration; a changed snapshot fails closed with a retry
  message.
- Invalid, unreadable, or unavailable workflow definitions now block rather
  than being treated as a non-Kaiba workflow. Added direct support tests for
  the AppKit-independent binding-row model, patch/default/disabled/missing
  resolution, long-term-memory request classification, and fixed redacted
  recovery copy.
- Focused App and support verification passed with the temporary editable
  Kaiba checkout. Clean KaibaClient publication, full suites, catalog-scanner
  equivalence, digest availability, and current-executable screenshot evidence
  remain release gates.

### 2026-09-05 — Step 6 Revision: Final Approval And Binding-State Boundary

- The App now reloads the catalog off the main actor and re-resolves the daemon
  preference and workflow candidate only after that final await; any snapshot
  mismatch blocks the start. AppSupport owns the immutable three-part approval
  comparison and direct regressions cover preference, candidate, and catalog
  changes.
- AppSupport binding rows now contain typed selector choices and availability.
  AppKit renders those choices without deriving enabled, disabled, or missing
  states from raw `KaibaInstance` values. An unreadable workflow definition is
  directly regression-tested as a fail-closed readiness result.
- The App target, rather than the AppSupport boundary, owns daemon-state
  re-resolution because it owns profile/source resolution. Clean KaibaClient
  publication, full suites, digest availability, and current-executable
  screenshot evidence remain release gates. No files were staged, committed,
  or pushed.

### 2026-09-05 — Step 6 Revision: Race And Redaction Evidence

- Added an App-target catalog-loader seam solely for deterministic tests. The
  new regression mutates the workflow source during the final catalog load and
  proves `approvedDaemonWorkflowInstance` rejects the stale approval before a
  runtime can start.
- Added an AppSupport removal-reference equivalence regression against the
  shared scanner for identical roots. K6 now records this completed check.
- Added named cross-surface bearer-sentinel regressions for persisted and
  reflected catalog state, CLI output, add-on output, and AppSupport state.
  The remaining K8 error/log/screenshot matrix is still explicitly open.
- Focused editable-checkout test groups passed: approval/binding (17 tests) and
  scanner/redaction (7 tests). Clean KaibaClient publication, full suites,
  digest availability, and current-executable screenshot evidence remain
  release gates. No files were staged, committed, or pushed.

### 2026-09-05 — Step 6 Revision: UI Stale-State And Evidence Reconciliation

- Reconciled K0-K7 task boxes against the implemented source and focused
  editable-checkout evidence. K6 now records deterministic stale-selection
  suppression; K7 records constrained-width icon-only controls and AppKit
  layout/selection coverage. Open boxes continue to identify incomplete error,
  log, screenshot, journey, digest, and clean-release work rather than serving
  as a second status system.
- `DaemonWorkflowWindowController+KaibaPane.swift` now creates the Add and
  per-instance controls as icon-only AppKit buttons with empty titles,
  accessibility labels, and tooltips. `RielaAppKaibaPaneTests` verifies the
  controls at a 360-point width and proves a completed stale readiness result
  cannot replace the newly selected instance's Start state.
- `KaibaCompatibilityAndRedactionTests` now injects a transport error whose
  text contains endpoint and bearer sentinels; the public GraphQL error remains
  the fixed redacted diagnostic. The focused build plus selected App, support,
  redaction, and CLI suites passed 89 tests.
- Re-ran SwiftLint with Xcode and `--no-cache`; it reports only pre-existing
  warnings outside changed files. File-size, inventory, forbidden-symbol, and
  diff checks passed. The direct current executable opened window 3773 under
  `tmp/kaiba-ui-review-rerun/`, but `screencapture` again reported `could not
  create image from window`; screenshot inspection remains open.
- Clean KaibaClient publication, clean full build/test execution, package-digest
  availability, full K8 error/log matrix, and screenshot evidence remain
  release gates. No files were staged, committed, or pushed.

### 2026-09-05 — Step 6 Revision: Profile-Stale Readiness Regression

- Added `RielaAppKaibaPaneTests.testStaleKaibaReadinessResultDoesNotOverrideProfileChange`.
  It holds a blocked readiness result for the default profile, changes to a
  distinct profile and ready workflow, then releases the stale result and
  proves the current Start state stays enabled. This complements the existing
  selection-stale and final-approval-snapshot regressions.
- Passed with the temporary editable Kaiba checkout:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaAppKaibaPaneTests`
  (6 tests). K8's complete failure/redaction matrix, K9's isolated user journey,
  clean dependency publication, and screenshot evidence remain open. No files
  were staged, committed, or pushed.

### 2026-09-05 — Step 6 Revision: Closed App Status And Isolated Repair Journey

- Replaced the App's raw-string Kaiba status entry point with
  `RielaAppKaibaStatus`, a closed fixed-copy enum. Server, endpoint, transport,
  and credential diagnostics cannot enter Kaiba status labels, alerts,
  accessibility values, or history through this path. AppKit coverage asserts
  the displayed recovery copy.
- Extended `KaibaCompatibilityAndRedactionTests` with sentinel-bearing GraphQL
  server-error and SDK endpoint-rejection cases. Both retain the fixed
  Riela-owned provider diagnostic. K8 keeps log and screenshot review open.
- Added `RielaAppKaibaInstanceJourneyTests`, an isolated CLI/App catalog journey
  covering empty list, local/remote add, update, default selection, binding,
  blocked and forced removal, dangling-binding failure, repair, snapshot
  resolution, and App-support reference scanning. Representative HTTP business
  operations remain an explicit K9 fixture gate.
- Passed with the temporary editable Kaiba checkout:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --skip-build --filter 'RielaAppKaibaInstanceJourneyTests|RielaAppKaibaPaneTests|KaibaCompatibilityAndRedactionTests'`
  (11 tests). Rebuilt and launched the direct
  `.build/arm64-apple-macosx/debug/RielaApp` under
  `tmp/kaiba-ui-review-status-retry/`; no on-screen RielaApp window ID was
  returned after the bounded launch delay, so no screenshot exists to inspect.
  `swift package unedit kaiba` removed the editable dependency afterward; the
  clean Xcode-toolchain `swift build` remains blocked because pinned revision
  `b436b91d39a5eaee8243a43096dd13f1e8ad819e` does not export `KaibaClient`.
  No files were staged, committed, or pushed.

### 2026-09-05 — Step 6 Revision: Deterministic HTTP Operation Journey

- Added `KaibaDeterministicHTTPJourneyTests` and extended the shared
  `KaibaHTTPFixture` to model the SDK readiness response. One injected-transport
  journey now proves readiness, typed note read, arbitrary GraphQL, notebook
  ingest, long-term-memory notebook discovery, and memory recall use only the
  fixture HTTP transport and return accepted fixture values.
- Passed with the temporary editable Kaiba checkout:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaKaibaAddonsTests`
  (24 tests), and
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaAppSupportTests`
  (227 tests). `swift build --product RielaApp` passed with that same checkout.
- The direct current executable opened CGWindow ID `3916` under
  `tmp/kaiba-ui-review-final/`, but window-ID capture failed with `could not
  create image from window`; a full-screen capture was black when inspected.
  Screenshot acceptance remains blocked by the interactive capture environment.
  No files were staged, committed, or pushed.

### 2026-09-05 — Step 6 Revision: CLI Suite Recheck

- Added `KaibaMockScenarioAddonTests` to retain the test-only boundary: a mock
  response for `kaiba/memory-consolidate` is resolved by the scenario resolver
  before production Kaiba preflight. It passed with the temporary editable
  Kaiba checkout.
- The complete
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaCLITests`
  completed 873 tests with one failure in
  `RielaExampleParityTests.testMockScenarioExamplesRunThroughSwiftCLI`:
  legacy mock-example execution reached a `kaiba/*` node without a scenario
  response or validated HTTP instance and failed closed. This is an example
  fixture migration gap, not a reason to restore local/in-process fallback;
  it remains a K10 release gate while explicitly dirty example work is
  preserved. Clean dependency verification remains separately blocked by the
  published Kaiba pin.

### 2026-09-05 — Step 6 Revision: Deterministic Mock-Example Migration

- Replaced `GraphRAGExampleFixture` local note-root seeding and direct
  production `kaiba/*` invocation with deterministic scenario-only variables.
  `note-agent` and `note-link-extract` now provide explicit Kaiba search/read/
  graph responses. The existing dirty `note-rag-retrieval-fusion` and
  `workflow-knowledge-base` scenarios now also cover every reachable Kaiba
  node; their parity fixtures no longer supply `noteRoot`. Mock runs never need
  a validated HTTP snapshot, a local store, or a local fallback.
- Added inert-local-config assertions for `noteRoot`, `configPath`, and
  `databasePath`: they cannot select a transport, reach the HTTP request, or
  enter the projected output. Added catalog validation coverage proving remote
  HTTP and remote unauthenticated connections each require their own explicit
  opt-in.
- Passed with the temporary editable Kaiba checkout:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --skip-build --filter RielaExampleParityTests/testMockScenarioExamplesRunThroughSwiftCLI`
  (1 test, 108 seconds). This repairs the previously failing mock-example
  journey without reintroducing local or in-process Kaiba behavior.
- K8 remains IN_PROGRESS for the explicit legacy diagnostic, TLS/redirect,
  full fail-closed matrix, log sentinel, and screenshot sentinel gates. Clean
  published-dependency build/test, package-digest availability, and current
  executable screenshot inspection remain externally blocked. No files were
  staged, committed, or pushed.
- Rebuilt and re-ran the focused parity gate after the final fixture cleanup:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaExampleParityTests/testMockScenarioExamplesRunThroughSwiftCLI`
  passed (1 test, 107 seconds). The broad `RielaCLITests` rerun progressed past
  the repaired example but terminated at the unrelated
  `WorkflowCommandTests.testAutoImproveCancellationDoesNotCreateIncidentOrRerun`
  with `NSFileHandleOperationException` in `Sources/RielaAdapters/LocalProcess.swift:717`.
  Re-running that exact test passed (1 test, 2.118 seconds), so it remains a
  non-Kaiba full-suite flake rather than an accepted clean-suite result.
- Xcode-environment SwiftLint reports only existing warnings outside the latest
  files. File-size, add-on inventory, forbidden-symbol, and diff checks pass.
  `swift package unedit kaiba` removed the temporary checkout; clean
  Xcode-toolchain `swift build` remains blocked because published revision
  `b436b91d39a5eaee8243a43096dd13f1e8ad819e` has no `KaibaClient` product.

### 2026-09-05 — Step 6 Revision: Legacy Connection Assertion Boundary

- Moved legacy-field policy into `KaibaLegacyInputCompatibility` so local
  store/config fields and `KAIBA_NOTE_ROOT`/`RIELA_NOTE_ROOT` are inert and
  emit only `legacy_kaiba_local_config_ignored`. Legacy endpoint, credential,
  and remote-policy fields now exactly assert the already-resolved named
  instance; a contradiction fails before CLI/App readiness or node transport
  with the fixed `legacy_kaiba_connection_mismatch` diagnostic. Matching
  assertions emit only `legacy_kaiba_connection_config_matched`.
- Added runtime, CLI preflight, and App-readiness regressions proving the
  mismatch path blocks before reaching an endpoint. Focused Kaiba endpoint,
  CLI preflight, and App readiness tests were run with the temporary editable
  Kaiba checkout.
- App readiness now projects a legacy connection mismatch to the fixed typed
  recovery action, `Bind the intended named instance and remove legacy fields.`,
  rather than an instance-readiness probe. The endpoint regression matrix now
  separately proves mismatch rejection for endpoint, bearer environment-variable
  reference, unauthenticated mode, remote HTTP policy, remote unauthenticated
  policy, and malformed values; each case makes zero transport requests.
- K8 remains IN_PROGRESS: TLS and redirect refusal evidence, the broader
  fail-closed matrix, log/screenshot sentinel audit, clean published-dependency
  suite, package digest, and current-executable screenshot gate remain open.

### 2026-09-05 — Final Internal Verification And External Release Gates

- Re-ran the focused Riela boundaries against the explicitly temporary editable
  sibling Kaiba checkout: `RielaKaibaSupportTests` passed 27 tests,
  `RielaKaibaAddonsTests` passed 29, the Kaiba CLI/preflight selection passed
  11, and the `RielaAppKaiba` selection passed 18. The combined K8 redaction,
  compatibility, endpoint, preflight, and App readiness selection passed 19.
  `swift build --product RielaApp` also passed.
- Re-ran the sibling Kaiba schema implementation directly:
  `swift test --filter 'KaibaSchemaTests|KaibaCLIKitTests'` passed 47 tests.
  Coverage includes regex seed matching, field-qualified matches, query and
  mutation roots, cycles, forward type closure, stable text/JSON, empty
  selection, invalid regex, endpoint/auth policy, and credential redaction.
- Ran the complete sibling Kaiba suite after making its symbol-graph API tests
  select the same Xcode toolchain and macOS SDK as SwiftPM: 808 XCTest tests and
  123 Swift Testing tests passed with zero failures. A focused API-test rerun
  also passed after the final lint-only UTF-8 conversion adjustment. SwiftLint
  reports only three pre-existing warnings, every Swift file remains below
  1,000 lines, and `git diff --check` passes.
- Verified the real SDK redirect boundary with
  `swift test --filter KaibaClientHTTPTransportTests` (3 tests). The fixture
  received only the initial `/graphql` request; the redirect was refused and no
  bearer or response-body sentinel escaped. Source audit confirms the ephemeral
  URLSession uses the platform TLS verifier and defines no authentication-
  challenge override capable of disabling certificate validation.
- Ran the complete Xcode-toolchain test gate successfully: `swift test` passed
  1,939 XCTest tests plus 14 Swift Testing tests with zero failures in 638
  seconds. The previously observed LocalProcess/NSFileHandle flake did not
  recur. SwiftLint completed with only recorded pre-existing warnings; add-on
  inventory equality, forbidden-local-symbol, sub-1,000-line, CLI help,
  `git diff --check`, and unstaged-worktree gates passed.
- Audited the Kaiba-owned Riela sources for logging calls. The support, add-on,
  CLI Kaiba, AppSupport Kaiba, and App Kaiba files do not publish free-form
  endpoint, bearer, response-body, or provider diagnostics; all user-visible
  recovery paths remain closed typed copy.
- Ran `swift package unedit kaiba` and proved `Packages/kaiba` is absent.
  A clean published-dependency build then failed only because pinned revision
  `b436b91d39a5eaee8243a43096dd13f1e8ad819e` does not yet export the
  `KaibaClient` product. Publishing/pinning the sibling work remains an external
  release gate and was not authorized in this work package.
- Current-executable AppKit tests and `RielaApp` build pass, but every attempted
  CGWindow/full-screen capture was black because this session lacks usable
  macOS Screen Recording access. Screenshot sentinel inspection therefore
  remains an explicit external/manual gate and is not claimed complete.
- No tracked root `riela-package.json` exists (`rg --files -g
  'riela-package.json' -g '!tmp/**'` is empty), so there is no repository package
  manifest whose digest can be refreshed. No files were staged, committed, or
  pushed.

## Risks And Controls

- **Dirty overlap**: `Package.swift`, `Package.resolved`, Kaiba add-on files, CLI
  example tests, the implementation workflow skill, and an example directory
  already contain user work. Control: K0 byte/diff baseline, single-owner write
  scopes, integration rather than replacement, and final baseline comparison.
- **Partial cutover**: named configuration could coexist with hidden local
  access. Control: one atomic release gate, inventory equality, forbidden-symbol
  scan, and injected-transport coverage for every add-on.
- **Credential leakage**: a token or unsafe endpoint path could escape through a
  secondary surface. Control: no value-bearing model, fixed diagnostics,
  root-or-`/graphql` persistence, SDK redaction, and cross-surface sentinels.
- **Silent rerouting**: stale/disabled explicit IDs could fall back. Control:
  stable-ID-only bindings, immutable snapshots, fallback only when absent, and
  unknown-ID failure after forced removal.
- **Race/lost update**: CLI, App, tests, and binding edits can overlap. Control:
  one catalog coordination lock, transactional reload/write, scan failure on
  incomplete evidence, and stale-probe revision guards.
- **Duplicate mutations after lost response**: retries can repeat server writes.
  Control: oldest-unaccepted runtime operation identity, deterministic explicit
  and derived keys, no SDK automatic retries, and multi-retry lost-response
  tests for every ingest/memory path.
- **SDK shape gap**: current payload compatibility may require data the accepted
  SDK does not expose. Control: return to design/adversarial review; never add a
  local fallback or leak raw transport envelopes.
- **UI evidence staleness**: an old `.app` bundle can misrepresent current code.
  Control: launch the direct architecture-specific debug executable and record
  window IDs/screenshots.
- **Large-file growth**: already-near-limit source/test files can cross 1,000
  lines. Control: responsibility-based new files, per-task size checks, and a
  blocking final inventory.
