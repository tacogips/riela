# Web Workflow Observability and Management Implementation Plan

**Status**: IMPLEMENTED_WITH_VERIFICATION_BLOCKER
**Workflow Mode**: `issue-resolution`
**Branch**: `feat/web-workflow-ui-improvements`
**Issue Reference**:
`docs/briefs/web-workflow-ui-2026-07-29.md`; `comm-000193`;
`codex-design-and-implement-review-loop-session-19`
**Accepted Design Review**: `comm-000204`; `needs_revision: false`;
findings `[]`; feedback `[]`
**Codex-Agent References**: none supplied
**Created**: 2026-07-29
**Latest Reviewed Step 6 Handoffs**: implementation `comm-000262`;
test-integrity `comm-000259`
**Latest Step 6 Self-Review**: `comm-000263`; `needs_revision: true`;
two mid persistence findings and one low documentation finding, addressed by
the current Step 6 revision
**Latest Ordinary Review**: `comm-000260`; `needs_revision: false`;
one accepted low documentation finding
**Latest Adversarial Review**: `comm-000261`; `needs_revision: true`;
two mid production findings and one low documentation finding, superseded by
implementation `comm-000262` and the current `comm-000263` self-review revision
**Last Updated**: 2026-07-30 (Step 6 comm-000263 self-review revision)

---

## Objective

Implement the accepted design as exactly one issue-resolution work package:

- add a persisted, bounded, redacted run-detail REST projection and navigate to
  it from Run logs;
- add visibility-aware, stale-result-safe polling to Instances, Run logs, and
  run detail while preserving manual Refresh;
- validate workflow-variable JSON before save and expose typed node patches;
- add source-scoped discovered-definition inspection and mutable-registry
  list/register/edit/activate/deactivate/delete behavior; and
- preserve the existing security, host-mode, registry transaction,
  compatibility, and no-new-dependency boundaries.

The accepted design is the source of truth. Implementation discoveries may
refine internal type and file placement but must not broaden the feature,
weaken projection redaction or registry authorization, add run control or
streaming, or split this package into independent features.

## References and accepted decisions

- Binding intake brief:
  `docs/briefs/web-workflow-ui-2026-07-29.md`.
- Accepted design:
  `design-docs/specs/design-web-workflow-observability-management.md`.
- Step 3 design review:
  `comm-000204`, accepted with no findings or feedback.
- Workflow execution:
  `codex-design-and-implement-review-loop-session-19`.
- Branch:
  `feat/web-workflow-ui-improvements`.
- Codex-agent references: none supplied.
- Cursor adapter boundary: not applicable because no Codex-reference or
  Cursor-reference input was supplied.
- User-QA reference: none required; the accepted design records no unresolved
  user decision.
- Run detail uses only
  `GET /api/v1/instances/{instance-id}/executions/{session-id}`.
- Discovered definitions use only
  `GET /api/v1/workflows/sources/{source-id}/definition`.
- Mutable registry management reuses the existing GraphQL query and mutation
  names. It does not add a parallel registry REST API.
- Full Playwright execution and browser QA remain operator-owned. This workflow
  authors the required e2e specifications and runs non-browser verification.

## Scope

### Included

- RielaApp persisted-session run-detail loading, bounded display projection,
  fail-closed redaction, truncation metadata, instance/session ownership checks,
  and REST routing.
- Additive instance `nodePatches` projection with typed backend, model, and
  effort fields.
- Exact daemon-source discovered-definition lookup and a bounded read-only
  definition projection.
- A reusable registry service/provider boundary shared by CLI and RielaApp,
  with canonical root pinning, existing coordinated locks, staging,
  validation, publication, activation, and redaction preserved.
- RielaApp local-web GraphQL composition after Host, Origin, CSRF, and JSON
  checks, with a server-owned request-local principal and existing registry
  capability preflight.
- Additive registry GraphQL definition/revision/concurrency contracts,
  definition-input validation, retain-handle expansion, complete-bundle
  staging, and typed conflict feedback.
- Hand-written workflow web clients, profile and selection generation guards,
  shared five-second polling, signal-based run-detail navigation, variable JSON
  validation, node-patch display, discovered-definition inspection, and mutable
  registry UI.
- Focused Swift and Bun tests plus authored Playwright specifications.
- Directly affected user-facing documentation review, verification evidence,
  review corrections, and workflow commit handoff.

### Excluded

- Run, resume, rerun, retry-step, or node-patch mutation from the web.
- WebSocket, SSE, or another streaming transport.
- `consolidateWorkflows` UI or mutation calls.
- Visual workflow building or from-scratch authoring beyond pasted JSON
  registration.
- Package installation, Notes, native-app feature work, a frontend router,
  CORS/authentication redesign, or new frontend dependencies.
- Changes to `.riela/workflows` fixtures.
- Full Playwright execution or browser QA by this workflow.
- Independent feature branches, commits, or work packages;
  `has_feature_fanout` remains false.

## Task breakdown

### T0. Preflight, ownership, and contract baseline

**Status**: COMPLETED
**Write scope**: this plan's progress log and
`tmp/web-workflow-observability-management/` only
**Depends on**: accepted Step 3 review `comm-000204`
**Parallelizable**: no

**Tasks**:

- Confirm the current branch and classify every existing tracked and untracked
  change. Preserve unrelated work and the accepted design document.
- Re-read the brief and accepted design without reopening accepted scope.
- Trace the current session-list REST path, daemon source projection, instance
  projection, Notes GraphQL route composition, registry GraphQL executor,
  mutable registry provider/service, and web view-signal navigation.
- Record the exact current DTOs, mutation payloads, test fixtures, Package.swift
  target boundaries, and focused test names that later tasks will change.
- Freeze the implementation checklist for the accepted REST and GraphQL
  response/input shapes before frontend and backend work diverge.
- Put ad-hoc logs and evidence only under
  `tmp/web-workflow-observability-management/`.

**Deliverables**:

- A progress entry with owned/unowned changes, traced data flows, selected test
  targets, contract checklist, and any implementation-blocking discrepancy.

**Verification**:

```bash
git status --short --branch --untracked-files=all
test -s docs/briefs/web-workflow-ui-2026-07-29.md
test -s design-docs/specs/design-web-workflow-observability-management.md
rg -n "executions|daemonWorkflowSources|nodePatchCount|graphql" Sources/RielaApp
rg -n "WorkflowRegistryGraphQL|WorkflowMutableRegistry|workflowSession" Sources Tests
rg -n "InstancesView|LogsView|WorkflowsView|cli-serve" web/src
```

### T1. Establish shared projection, redaction, and retain-handle foundations

**Status**: COMPLETED
**Write scope**:

- new shared workflow web-projection files under the smallest importable Swift
  target selected in T0
- focused projection tests under the corresponding test target
- `Package.swift` only if target dependency wiring is required

**Depends on**: T0
**Parallelizable**: yes, with T2 after T0 only if T2 does not edit
`Package.swift` or the projection target

**Tasks**:

- Implement distinct schema-aware projectors for run detail, discovered
  definitions, and mutable edit definitions; never directly encode persisted
  runtime objects or raw `workflow.json`.
- Enforce all collection, string, definition, and serialized-response limits
  from the accepted design and emit `totalCount`, collection/string
  `truncated`, and top-level truncation markers as specified.
- Use allowlist projection for backend events and exclude raw assistant,
  thinking, tool arguments/output/metadata, communication payloads, artifacts,
  environment values, command lines, and LLM messages.
- Add fail-closed path and credential redaction with secret-canary coverage.
- Implement authenticated, non-reversible retain handles bound to verified
  principal, exact mutable origin, definition revision, JSON Pointer, and
  persisted-value digest.
- Reject forged, moved, replayed, cross-origin, cross-revision, and
  cross-principal handles before staging; reject retain handles during
  registration.
- Keep submitted and persisted sensitive values out of every response.

**Deliverables**:

- Reusable bounded display/edit projectors and a retain-handle service with
  deterministic tests for limits, redaction, binding, and fail-closed behavior.

**Verification**:

```bash
swift test --filter RielaGraphQLTests
swift test --filter RielaAppSupportTests
```

### T2. Extract a reusable mutable-registry service boundary

**Status**: COMPLETED
**Write scope**:

- `Sources/RielaCLI/WorkflowRegistryService.swift`
- `Sources/RielaCLI/WorkflowRegistryGraphQLProvider.swift`
- the smallest new importable registry-service files/target required by T0
- `Package.swift` if extraction requires target wiring
- focused registry tests under `Tests/RielaCLITests/` and
  `Tests/RielaGraphQLTests/`

**Depends on**: T0
**Parallelizable**: yes, with T1 only when their production write scopes and
`Package.swift` ownership are assigned disjointly

**Tasks**:

- Extract or expose the smallest service/provider boundary that RielaApp can
  import without duplicating CLI registry behavior.
- Preserve the canonical home-owned `~/.riela/temporary-workflows` root,
  root pinning, containment and symlink defenses, coordinated lock order,
  recovery, staging, validation, activation, and publication semantics.
- Make request providers capture the canonical root and fixed user-mutable
  policy; prohibit cwd, profile roots, instance directories, daemon-source
  directories, and browser-supplied paths.
- Restrict web operations to exact user-scope mutable origins and fail closed
  for `AUTO`, `PROJECT`, missing-origin, and immutable targets.
- Add lock-held definition-revision and activation-state comparison seams so
  web concurrency checks happen before staging, removal, or activation writes.
- Preserve current CLI and non-web GraphQL behavior and public compatibility.

**Deliverables**:

- One reusable registry implementation used by CLI and ready for RielaApp
  composition, with no second locking or transaction implementation.

**Verification**:

```bash
swift test --filter WorkflowMutableRegistryTests
swift test --filter GraphQLWorkflowRegistryTests
```

### T3. Extend registry GraphQL contracts and compose authorized RielaApp access

**Status**: COMPLETED
**Write scope**:

- `Sources/RielaGraphQL/GraphQLContracts.swift`
- `Sources/RielaGraphQL/WorkflowRegistryGraphQL.swift`
- `Sources/RielaGraphQL/WorkflowRegistryGraphQLSchema.swift`
- `Sources/RielaGraphQL/WorkflowRegistryGraphQLValidation.swift`
- `Sources/RielaApp/RielaAppWebNoteGraphQL.swift`
- narrowly scoped new RielaApp workflow-GraphQL adapter files
- focused `Tests/RielaGraphQLTests/` and
  `Tests/RielaAppSupportTests/` files

**Depends on**: T1, T2
**Parallelizable**: no; this integrates both shared foundations

**Tasks**:

- Add nullable `definition` alternatives and exact-one validation to register
  and update inputs while preserving legacy bundle-reference clients.
- Add mutable edit `definition`, `definitionRevision`, and nullable
  delete/activation concurrency fields with the accepted compatibility rules.
- Apply request and post-expansion definition size/depth limits.
- For definition update, compare the exact persisted-byte SHA-256 revision
  under coordinated locks, expand retain handles, copy the complete mutable
  bundle to staging, replace only `workflow.json`, validate, and publish.
- Require web delete/activate/deactivate callers to supply the accepted
  revision and activation expectations while retaining legacy behavior for
  non-web providers.
- Return stable `REGISTRY_CONFLICT`, validation, invalid-origin, immutable, and
  unavailable results without nonstandard HTTP status mapping.
- Compose registry documents alongside Notes only after the existing RielaApp
  Host, Origin, CSRF, and JSON gate.
- Create the verified principal in-process per request with exactly
  `readRegistry` and `mutateRegistry`; retain executor capability preflight and
  prevent browser-controlled trust input.
- Prove rejected and partially authorized requests never invoke the provider,
  and mixed-domain documents fail before any root executes when one selected
  domain is unauthorized.

**Deliverables**:

- Backward-compatible registry GraphQL schema/execution and request-local,
  capability-checked RielaApp composition using the shared provider.

**Verification**:

```bash
swift test --filter RielaGraphQLTests
swift test --filter RielaAppSupportTests
```

### T4. Add RielaApp REST projections for run detail, definitions, and patches

**Status**: COMPLETED
**Write scope**:

- `Sources/RielaApp/RielaAppWebAPI.swift`
- `Sources/RielaApp/RielaAppWebRouter.swift`
- narrowly scoped new RielaApp loader/projector files
- `Tests/RielaAppSupportTests/RielaAppWebAPIRouteTests.swift`
- additional focused RielaApp route tests when separation improves clarity

**Depends on**: T1; T3 for final router/security integration
**Parallelizable**: no; it shares RielaApp routing and security composition
with T3

**Tasks**:

- Add the nested instance/session run-detail route and load the authoritative
  persisted snapshot used by the workflow viewer.
- Validate encoded identifiers, selected-instance workflow ownership, and
  session membership before projecting data; use existing REST error envelopes.
- Return session identity/status, bounded step executions, safe event/log and
  diagnostic summaries, communication routing metadata, loop/gate evidence,
  recovery lineage, and all required truncation markers.
- Add typed `nodePatches` to the instance projection while retaining the
  compatible derived `nodePatchCount`.
- Add the exact daemon-source-id discovered-definition route; decode once,
  resolve only within the active profile's `daemonWorkflowSources`, validate
  the internal candidate, and never accept or return a filesystem path.
- Return only the discovered display projection, structural summary, content
  revision, and bounded redacted diagnostics.
- Verify invalid Host, Origin, CSRF, content type, unsafe identifier, stale
  source, profile mismatch, workflow mismatch, and oversize paths fail closed.

**Deliverables**:

- Additive REST contracts for real run detail, inspectable node patches, and
  exact source-scoped discovered definitions.

**Verification**:

```bash
swift test --filter RielaAppSupportTests
swift test --filter RielaViewerTests
```

### T5. Add web contracts, workflow clients, polling, and generation ownership

**Status**: COMPLETED
**Write scope**:

- `web/src/contracts.ts`
- `web/src/api.ts`
- new workflow-domain client files under `web/src/workflows/`
- new shared polling helper files under `web/src/`
- focused adjacent Bun unit tests

**Depends on**: T0 contract checklist
**Parallelizable**: yes, with T1-T2 because the Swift and web write scopes are
disjoint; reconcile against T3-T4 before T6

**Tasks**:

- Add typed contracts and hand-written clients for run detail, discovered
  definitions, mutable registry queries/mutations, node patches, truncation,
  retain handles, diagnostics, and conflict results.
- Reuse same-origin headers, CSRF behavior, JSON handling, and GraphQL error
  parsing without coupling workflow operations to the Notes module.
- Implement one shared five-second polling helper with a single-in-flight
  guard, visibility pause, immediate resume refresh, manual refresh,
  background stale-content retention, status exposure, and disposal.
- Add request-context keys and monotonically increasing generations. Every
  content, loading, and error commit must verify current profile identity,
  profile generation, and surface selection.
- Unit-test hidden/visible transitions, manual refresh, in-flight suppression,
  stale content/error/loading rejection, cleanup, and conflict mapping with
  deterministic clocks and deferred promises.

**Deliverables**:

- Typed clients and a reusable polling/generation layer ready for all three
  polling surfaces and both definition surfaces.

**Verification**:

```bash
cd web && bun test src
cd web && ./node_modules/.bin/tsc --noEmit
```

### T6. Implement Instances, Run logs, and run-detail UI

**Status**: COMPLETED
**Write scope**:

- `web/src/App.tsx`
- `web/src/views/InstancesView.tsx`
- `web/src/views/LogsView.tsx`
- new `web/src/views/RunDetailView.tsx`
- focused adjacent Bun unit tests

**Depends on**: T4, T5
**Parallelizable**: yes, with T7 after T5 because view write scopes are
disjoint; T6 exclusively owns `web/src/App.tsx`

**Tasks**:

- Make App own the profile-context generation and selected
  `{instanceId, sessionId, workflowId}`; clear profile-owned state before
  requests on profile or host-mode change.
- Keep signal-based navigation and force Notes-only behavior in `cli-serve`.
- Make semantic session-row controls open run detail and Back restore the
  retained Run logs instance selection.
- Render run-detail header, step timing/status/backend/attempt/failure,
  bounded event/log evidence, diagnostics, routing metadata, gate/loop
  evidence, recovery lineage, truncation indicators, and explicit
  loading/error/empty states using Primitives.
- Apply shared polling to Instances, Run logs, and run detail; preserve manual
  Refresh and accessible auto-refresh/paused/refreshing status.
- Validate workflow variables on every edit and immediately before submit;
  require a non-null JSON object, associate inline errors with the textarea,
  and disable Save while invalid.
- Render node patches read-only in deterministic node order with an explicit
  empty state.
- Add focused tests for navigation, stale selection/profile responses,
  polling status, variable validation, save blocking, and patch rendering.

**Deliverables**:

- Complete observability and configuration UX for the first three accepted
  workstreams without run-control or streaming behavior.

**Verification**:

```bash
cd web && bun test src
cd web && ./node_modules/.bin/tsc --noEmit
```

### T7. Implement discovered-definition and mutable-registry UI

**Status**: COMPLETED
**Write scope**:

- `web/src/views/WorkflowsView.tsx`
- narrowly scoped workflow editor/inspector components under
  `web/src/workflows/`
- focused adjacent Bun unit tests

**Depends on**: T3, T4, T5
**Parallelizable**: yes, with T6 after T5 because production view scopes are
disjoint

**Tasks**:

- Retain source discovery and add exact-source selection with read-only
  structural definition inspection, validation diagnostics, truncation
  indicators, and loading/error/empty states.
- List mutable user workflows through `workflows(filter: {provenance:
  MUTABLE})` and fetch selected definitions by exact workflow id, user scope,
  and origin id.
- Add pasted-JSON registration and mutable edit modes with guarded object
  validation. Preserve unchanged retain placeholders and let new literals
  intentionally replace sensitive values.
- Add activate/deactivate and exact-workflow delete confirmation; keep
  destructive controls disabled until the exact definition revision and
  activation state are current.
- Map GraphQL `REGISTRY_CONFLICT` and server validation feedback to
  `MutationMessage` with Refresh recovery; refetch list and selection after
  success or conflict recovery.
- Reject stale source/profile/origin/revision completions for content,
  selection, editor text, loading, and errors.
- Never expose immutable edit/delete controls or render/call
  `consolidateWorkflows`.

**Deliverables**:

- Read-only discovered-definition visibility and complete accepted mutable
  registry management with validation, confirmation, concurrency, and
  redaction-safe editing.

**Verification**:

```bash
cd web && bun test src
cd web && ./node_modules/.bin/tsc --noEmit
```

### T8. Complete adversarial Swift regression coverage

**Status**: PARTIAL_VERIFICATION_BLOCKED
**Write scope**:

- focused tests under `Tests/RielaGraphQLTests/`
- focused tests under `Tests/RielaAppSupportTests/`
- focused registry tests only where T2 changed shared CLI behavior

**Depends on**: T1-T4
**Parallelizable**: yes, with T6-T7 only when test files are assigned
exclusively and no production code is edited

**Tasks**:

- Cover all authorization allow/deny cases and prove rejected requests never
  invoke the provider.
- Cover canonical-root pinning, absent/unavailable roots, no-cwd/no-browser-path
  behavior, user-mutable filtering, and exact-origin rejection.
- Cover lock-held revision conflicts before staging, stale delete conflicts,
  stale activation revision/state conflicts, complete-bundle preservation, and
  legacy bundle-input compatibility.
- Cover every run-detail and definition bound/truncation marker and canaries in
  credentials, environment literals, prompts, add-on inputs/configuration,
  command argv, assistant/thinking/tool content, paths, and diagnostics.
- Cover retain-handle preserve/replace behavior and all forged/rebound/replayed
  rejection cases before staging.
- Cover run-detail instance/session ownership, discovered-source exact
  resolution, unsafe identifiers, missing/stale selections, and typed node
  patch projection.

**Deliverables**:

- Deterministic regression evidence for the accepted high-risk security,
  concurrency, publication, and exposure contracts.

**Verification**:

```bash
swift build
swift test --filter RielaGraphQLTests
swift test --filter RielaAppSupportTests
swift test --filter WorkflowMutableRegistryTests
```

### T9. Complete web unit and authored Playwright coverage

**Status**: COMPLETED
**Write scope**:

- focused tests under `web/src/`
- new focused specifications under `web/e2e/`

**Depends on**: T5-T7
**Parallelizable**: no; it validates the integrated frontend contract

**Tasks**:

- Cover run-detail navigation and real-response rendering, empty/error states,
  and Back behavior.
- Cover polling indicators, visibility pause/resume, manual refresh, and stale
  in-flight response rejection for profile, instance, session, source, and
  mutable-origin changes.
- Cover invalid variables JSON, associated inline error, disabled Save,
  revalidation on submit, valid save, and node-patch display.
- Cover discovered-definition inspection, mutable list/edit, retain
  placeholders, validation, conflict Refresh, activation/deactivation, and
  confirmed delete.
- Use `exact: true` role selectors and verify `cli-serve` exposes none of the
  new non-Notes surfaces.
- Author but do not execute the full Playwright suite; record operator-owned
  execution and browser QA as an explicit handoff gap.

**Deliverables**:

- Passing focused Bun coverage and checked-in e2e specifications for all brief
  acceptance flows.

**Verification**:

```bash
cd web && bun test src
cd web && bun run build
rg -n "exact: true" web/e2e
```

### T10. Integrated verification, documentation refresh, and handoff

**Status**: PARTIAL_VERIFICATION_BLOCKED
**Write scope**:

- this plan's progress log
- `README.md` and directly affected user-facing workflow documentation only
  when shipped behavior requires updates
- `tmp/web-workflow-observability-management/` for detailed evidence

**Depends on**: T8, T9
**Parallelizable**: no; final serial gate

**Tasks**:

- Run the complete accepted build and focused test matrix.
- Run the smallest additional filtered Swift suite for any server file changed
  outside the planned GraphQL/App coverage.
- Review `README.md` and `.codex/skills/riela-impl-workflow/SKILL.md`; update
  directly affected user-facing documentation before commit generation.
- Confirm no run-control, streaming, consolidate, router, dependency, Notes,
  native-app, package-UI, or `.riela/workflows` changes entered the diff.
- Record exact commands, pass/fail counts, warnings, wrapper gaps, authored-only
  e2e status, and operator-owned browser QA.
- Run independent implementation review/improvement steps and resolve every
  high or mid finding before final handoff.
- Refresh required package digests if any workflow, prompt, script, or skill
  file is changed.
- Keep scratch files under `tmp/` and exclude them from staging.

**Deliverables**:

- Verified implementation, aligned documentation, complete progress evidence,
  explicit residual risks/gaps, and a clean commit-step handoff.

**Verification**:

```bash
cd web && bun run build
cd web && bun test src
swift build
swift test --filter RielaGraphQLTests
swift test --filter RielaAppSupportTests
git diff --check
git status --short --branch --untracked-files=all
```

## Dependencies

| Dependency | Required by | State |
| --- | --- | --- |
| Accepted design review `comm-000204` | Entire plan | Available |
| Persisted workflow viewer/session loader | T4 | Available; trace in T0 |
| Existing RielaApp REST security and error envelopes | T4 | Available |
| Existing Notes same-origin GraphQL composition pattern | T3, T5 | Available |
| Existing registry GraphQL operation names and capability preflight | T3 | Available |
| Existing mutable-registry root pinning, locks, staging, validation, activation, and publication | T2-T3 | Available; preserve |
| Shared bounded projectors and retain handles | T3-T4 | Produced by T1 |
| Reusable registry service/provider | T3 | Produced by T2 |
| REST and GraphQL server contracts | T6-T7 | Produced by T3-T4 |
| Web clients, polling, and generation guards | T6-T7 | Produced by T5 |
| Integrated implementation | T8-T10 | Produced by T1-T7 |

## Parallelizable tasks

- T1 and T2 may run in parallel after T0 only when `Package.swift` and any
  shared target are assigned to one owner and their remaining write scopes are
  disjoint.
- T5 may run in parallel with T1-T2 after T0 freezes the response/input
  checklist because its web write scope is disjoint from Swift production
  files. Contract reconciliation is required before T6-T7.
- T6 and T7 may run in parallel after T3-T5 because they own separate views;
  T6 exclusively owns `web/src/App.tsx`, and shared clients/components must be
  stabilized in T5 first.
- T8 may run beside T6-T7 only when each test file has one owner and T8 does not
  edit production files.
- T3, T4, T9, and T10 are serial integration gates.
- Parallel execution does not create feature fanout; all tasks remain one work
  package and converge before integrated verification.

## Completion criteria

- [x] One work package is implemented on
      `feat/web-workflow-ui-improvements`; unrelated files and
      `.riela/workflows` fixtures are unchanged.
- [x] A Run logs row opens real persisted run detail with step identity,
      status, timing, safe step-level logs/diagnostics, gate/loop evidence, and
      explicit loading/error/empty/truncation states. Routing evidence is
      attributed by exact step-execution identity, with records lacking a
      visible source execution displayed separately.
- [x] Instances, Run logs, and run detail poll every five seconds only while
      visible, refresh immediately after visibility resumes, preserve manual
      Refresh, suppress overlapping requests, and reject every stale content,
      loading, and error commit. Server polling performs a bounded 101-summary
      read for lists and a direct session-id read for run detail. Legacy
      summary columns are completely migrated before indexed polling becomes
      authoritative; run detail reads message count plus the newest 201
      routing-only records through a session-order index without payload
      decoding or a duplicate snapshot load.
- [x] Workflow-variable JSON is validated during editing and submission;
      invalid/non-object JSON shows an associated inline error and blocks Save.
- [x] Typed node patches are visible read-only and the compatible count remains.
- [x] Every displayed discovered workflow can load an exact source-scoped,
      bounded, redacted, read-only definition without exposing filesystem paths.
- [x] Mutable user workflows can be listed, paste-registered, edited,
      activated/deactivated, and confirmed-deleted through existing GraphQL
      operation names with validation and conflict Refresh feedback.
- [x] Registry web access uses a request-local server-owned principal, existing
      capability preflight, the canonical shared registry service, exact user
      mutable origins, and lock-held concurrency checks.
- [x] Complete mutable bundles survive inline `workflow.json` updates, and
      retain handles preserve unchanged sensitive values without revealing,
      echoing, moving, replaying, or rebinding them.
- [x] Projection limits, truncation markers, path/credential redaction, secret
      canaries, and raw assistant/thinking/tool/communication/environment/
      command/LLM exclusions are covered deterministically.
- [x] `cli-serve` remains Notes-only; no run-control, streaming,
      `consolidateWorkflows`, router, or new frontend dependency is added.
- [ ] Required Bun and Swift commands pass; required Playwright specifications
      use exact role selectors and are checked in, with full execution/browser
      QA explicitly handed to the operator. The feature-focused Swift suites
      pass, deterministic polling/client/profile-state Bun coverage now passes,
      and the test-integrity findings from `comm-000214` are resolved. The
      required full `RielaAppSupportTests` filter remains blocked by the
      unrelated pre-existing
      `DaemonWorkflowNodePatchTests.testRuntimeRestartsWorkflowWhenEventSourceExits`
      fixture mismatch (`nodePatch.worker` against the fixture's sole
      `reply` node), which deterministically fails before this feature's web
      code is reached.
- [x] README and directly affected workflow documentation match shipped
      behavior; required package digests are refreshed when applicable.
- [x] Every high or mid implementation-review finding is resolved, all
      verification gaps are explicit, scratch artifacts remain under `tmp/`,
      and `git diff --check` passes before commit handoff.

## Risks and controls

| Risk | Control |
| --- | --- |
| RielaApp duplicates or weakens registry transactions | Extract one shared provider/service boundary and regression-test CLI compatibility |
| Browser access bypasses registry authorization | Gate HTTP first, create request-local principal in process, retain capability preflight, assert rejected requests never reach provider |
| Mutable edit loses referenced bundle files | Copy the complete current bundle under coordinated locks, replace only `workflow.json`, validate, then publish |
| Stale delete or activation mutates newer state | Compare exact definition revision and activation state under the same coordinated locks before mutation |
| Retain handles disclose or preserve the wrong value | Use non-reversible principal/origin/revision/pointer/digest binding and reject every forged or rebound case before staging |
| Run or definition responses expose secrets | Schema-aware allowlists, fail-closed redaction, fixed bounds, secret canaries, and no raw persisted-object encoding |
| Polling commits old profile or selection state | Context keys plus generation checks on content, loading, and error commits; cancellation is only an optimization |
| Native profile switch leaves a stale browser editor mutation-capable | Poll bootstrap identity, key profile-owned views and drafts, include active profile identity in instance/source/Assistant/Notes responses, require `expectedProfile` on every profile-owned REST mutation, bind RielaApp GraphQL requests to the loading profile and reject mismatches before executor construction, and increment `webRevision` on native switches |
| RielaApp acquires CLI-only build and release dependencies | Keep registry filesystem/service/provider code in the narrow `RielaWorkflowRegistry` target imported independently by RielaApp and RielaCLI; assert RielaApp has no `import RielaCLI` |
| Hidden polling or duplicate requests waste resources | Visibility listener, single-in-flight guard, deterministic lifecycle tests, disposal on unmount, complete one-time legacy summary migration, bounded indexed 101-summary list queries, and direct-session detail queries that count messages and load only the newest 201 routing records without payloads |
| Source identity is shadowed or path-confused | Exact once-decoded daemon source id lookup with no workflow-id or filesystem-path fallback |
| Additive GraphQL changes break existing clients | Nullable fields, exact-one validation only for new definition path, and legacy bundle-client regression tests |
| Scope expands into control or redesign | Diff audit against binding exclusions and final acceptance mapping |
| Browser behavior remains unverified locally | Author exact-selector e2e specifications and record full Playwright/browser QA as operator-owned |

## Progress log expectations

Update this section after every completed or materially blocked task. Each entry
must include date, task ID, status, changed files, exact verification commands
and results, findings or deviations, residual risks, and the next dependency.
Do not mark a task complete with planned-only verification. Put verbose logs
under `tmp/web-workflow-observability-management/`, summarize durable evidence
here, and move this plan to `impl-plans/completed/` only after every completion
criterion is resolved.

| Date | Task | Status | Files / evidence | Verification | Next |
| --- | --- | --- | --- | --- | --- |
| 2026-07-29 | Plan creation | READY | `docs/briefs/web-workflow-ui-2026-07-29.md`; `design-docs/specs/design-web-workflow-observability-management.md`; Step 3 `comm-000204`; this plan | `wc -l` and heading/task `rg` confirmed 711 lines, required sections, and T0-T10; trailing-whitespace `rg` found no matches; status showed only the accepted design and this plan as untracked; the combined wrapper timed out after emitting complete expected output | T0 |
| 2026-07-29 | Step 6 implementation | IMPLEMENTED_WITH_REVIEW_RISKS | Added REST run detail and discovered-definition projections, typed node patches, polling/generation helper, run-detail navigation/UI, JSON validation, definition inspector, mutable-registry GraphQL/UI, unit tests, focused Swift tests, and authored Playwright specifications. Changed files are recorded in the Step 6 handoff. | `cd web && bun test src` passed 32 tests; `cd web && ./node_modules/.bin/tsc --noEmit`, focused ESLint, source audit, and `bun run build` passed; `swift build`, 106 RielaGraphQL tests, 8 RielaApp route tests, and the focused registry-provider test passed; SwiftLint completed with unrelated warnings plus one fixed local warning; full Playwright/browser QA was not run by contract. | Step 7 must review the RielaApp-local registry provider divergence, request-local authorization shape, activation marker compatibility, and retain-handle authentication before acceptance. |
| 2026-07-29 | Step 6 self-review | NEEDS_REVISION | Fixed a stale polling request-token race and cleared deleted mutable selections. Confirmed remaining blocking divergence in `Sources/RielaApp/RielaAppWebRegistryProvider.swift`: it does not share canonical CLI locks, origins, validation/publication, or activation persistence; retain handles are not principal-authenticated. Also found incomplete fail-closed redaction and response-cap enforcement in `Sources/RielaApp/RielaAppWebAPI.swift`. | Post-fix `cd web && bun test src`, `cd web && ./node_modules/.bin/tsc --noEmit`, and focused ESLint passed. Earlier Swift build and focused Swift suites remain green for the reviewed Swift state. | Return to Step 6 implementation; resolve all high/mid findings before Step 7. |
| 2026-07-29 | Step 6 revision | IMPLEMENTED_PENDING_INDEPENDENT_REVIEW | Reused the canonical `FileWorkflowRegistryGraphQLProvider` and `WorkflowRegistryService` from RielaApp by splitting the `riela` product into an importable `RielaCLI` target plus thin `RielaCLIExecutable`; added lock-held exact-byte SHA-256 conflicts, complete-bundle inline updates, canonical activation persistence, HMAC-SHA256 principal/origin/revision/pointer/value-digest retain handles, shared `WorkflowWebProjectionPolicy`, a 1 MiB run-detail cap, README refresh, and adversarial registry/projection tests. | `cd web && bun test src`, TypeScript `tsc --noEmit`, focused ESLint, source audit, and `bun run build` passed; `swift build` and `.build/debug/riela --version` passed; `swift test --filter RielaGraphQLTests` passed 106 tests; `swift test --filter WorkflowMutableRegistryTests` passed 10 tests; the combined RielaApp web route/projection/registry filter passed 15 tests; focused SwiftLint passed without findings; `git diff --check` remains the final handoff gate; full Playwright/browser QA remains operator-owned. | Step 7 independent implementation review. |
| 2026-07-29 | Step 6 second revision | IMPLEMENTED_WITH_VERIFICATION_BLOCKER | Projected persisted session-message routing and step diagnostics; replaced persisted free-form summaries with fail-closed schema-context projection; added response totals, truncation markers, 1 MiB/512 KiB caps, definition-list omission, GraphQL definition/bundle one-of revision enforcement, profile-owned selection/editor resets, and the missing route/GraphQL/Playwright regression cases. | `swift build` passed; the combined `GraphQLWorkflowRegistryTests`, `RielaAppWebAPIRouteTests`, `RielaAppWebProjectionPolicyTests`, and `RielaAppWebRegistryProviderTests` filter passed 46 tests; `swift test --filter RielaGraphQLTests` passed 108 tests; `swift test --filter WorkflowMutableRegistryTests` passed 10 tests; `cd web && bun test src` passed 32 tests and TypeScript typecheck, focused ESLint, source audit, and build passed; SwiftLint and `git diff --check` passed. The required `swift test --filter RielaAppSupportTests` ran 234 tests and failed seven assertions in one unrelated daemon restart test because its patch targets unknown node `worker` while the fixture defines only `reply`; the focused web suites pass. Full Playwright/browser QA remains operator-owned. | Step 7 independent review must assess the explicit unrelated suite blocker; do not mark T8/T10 or the verification criterion complete unless that external fixture is corrected or the blocker is accepted. |
| 2026-07-29 | Step 6 test-integrity revision | IMPLEMENTED_WITH_VERIFICATION_BLOCKER | Resolved `comm-000214` TI-001/TI-002: extracted an injectable polling controller and workflow-registry client; added deterministic polling, stale-generation, retry, cleanup, CSRF/target/revision/conflict/malformed-response, and profile-view transition tests; strengthened registry negative assertions to require exact error codes and unchanged state; added user-scope/origin, stale delete/activation, canonical-root, cross-origin retain, replacement-literal, projection-marker, and definition-canary coverage. Web registration now maps incomplete-bundle validation failures to `INVALID_WORKFLOW`. T8 remains partial only because of the unrelated full-suite fixture blocker; T9 is complete with operator-owned Playwright execution still explicit. | `cd web && bun test src` passed 43 tests with 153 assertions across 9 files; TypeScript typecheck, focused ESLint, source audit, and production build passed. `swift build` passed; `swift test --filter RielaGraphQLTests` passed 108 tests; `swift test --filter WorkflowMutableRegistryTests` passed 10 tests; the combined focused web/registry filter passed 49 tests; and `swift test --filter RielaAppSupportTests --skip 'DaemonWorkflowNodePatchTests.testRuntimeRestartsWorkflowWhenEventSourceExits'` passed 236 tests. Focused SwiftLint and `git diff --check` passed. Full Playwright/browser QA remains operator-owned, and the unskipped RielaAppSupportTests blocker remains unchanged. | Return to independent review with TI-001/TI-002 resolved and the unrelated suite blocker explicit. |
| 2026-07-29 | Step 6 SR-001 revision | IMPLEMENTED_WITH_VERIFICATION_BLOCKER | Resolved `comm-000216` SR-001 by narrowing web registration error translation to authored `WorkflowResolutionError` failures only. Detached candidate validation converts a missing referenced file into a deterministic invalid-workflow diagnostic, while cancellation and unexpected registry I/O continue unchanged to the GraphQL executor's `REGISTRY_IO_FAILURE` boundary. Added registration-specific cancellation and unexpected-error GraphQL coverage; the existing incomplete-bundle provider test remains the missing-reference classification canary. | `swift build` completed successfully; the combined `GraphQLWorkflowRegistryTests`, `RielaAppWebAPIRouteTests`, `RielaAppWebProjectionPolicyTests`, and `RielaAppWebRegistryProviderTests` filter passed 50 tests; `swift test --filter RielaGraphQLTests` passed 109 tests; `swift test --filter WorkflowMutableRegistryTests` passed 10 tests; and the AppSupport filter with the documented unrelated daemon test skipped passed 236 tests. Focused SwiftLint passed without findings. The unskipped AppSupport blocker and operator-owned Playwright/browser QA remain unchanged. | Return to Step 6 self-review with SR-001 resolved; retain the unrelated full-suite blocker and operator-owned browser verification as explicit gaps. |
| 2026-07-29 | Step 6 SR-002 revision | IMPLEMENTED_WITH_VERIFICATION_BLOCKER | Resolved `comm-000218` SR-002 by limiting missing-file translation to `resolver.loadBundle` after detached snapshot creation, population, and the pre-load hook. Added a real registry-hook regression test proving an infrastructure `NSFileReadNoSuchFileError` remains unclassified for the GraphQL executor's `REGISTRY_IO_FAILURE` boundary. | `swift build` passed; `swift test --filter WorkflowMutableRegistryTests` passed 11 tests; the combined focused web/registry filter passed 50 tests; `swift test --filter RielaGraphQLTests` passed 109 tests; and the AppSupport filter with the documented unrelated daemon test skipped passed 236 tests. Focused SwiftLint and `git diff --check` passed. The unskipped AppSupport blocker and operator-owned Playwright/browser QA remain unchanged. | Return to Step 6 self-review with SR-002 resolved and the established external verification gaps explicit. |
| 2026-07-29 | Step 7 review revision | NEEDS_REVISION | Partially addressed `comm-000222`: registry mutation clients now reserve 409 for `REGISTRY_CONFLICT` and preserve `INVALID_WORKFLOW` feedback, with Bun and authored Playwright regressions. The initial persisted-summary revision added credential, path, and opaque-token screening, but `comm-000224` SR-003 correctly found that its denylist and entropy heuristic did not satisfy the accepted fail-closed contract for unknown free-form text. Changed `Sources/RielaCore/WorkflowWebProjectionPolicy.swift`, `Tests/RielaAppSupportTests/RielaAppWebProjectionPolicyTests.swift`, `Tests/RielaAppSupportTests/RielaAppWebAPIRouteTests.swift`, `web/src/workflows/client.ts`, `web/src/workflows/client.test.ts`, and `web/e2e/workflow-management.spec.ts`. | `cd web && bun test src` passed 43 tests with 157 assertions; TypeScript typecheck, focused ESLint, source audit, and production build passed. The focused route/projection filter passed 14 tests, and the requested combined GraphQL/web filter emitted a complete 130-test, zero-failure result before its command wrapper timed out. Focused SwiftLint passed. Full Playwright/browser QA remains operator-owned, and the unrelated unskipped AppSupport blocker remains unchanged. | Return to Step 6 for SR-003; do not claim `comm-000222` fully resolved until context-specific projection and low-entropy canaries pass. |
| 2026-07-29 | Step 6 SR-003 revision | NEEDS_REVISION | Partially addressed `comm-000224` SR-003 by replacing generic persisted-summary screening with caller-declared contexts and fixed synthesized summaries for run detail, definitions, and registry diagnostics. Added policy and run-detail canaries for short, lowercase, numeric, dictionary-style, mixed-case, credential, and path values. `comm-000226` SR-004 subsequently found that the executions-list endpoint still used denylist-based `webSafeSummary`, so this entry must not claim full resolution. | The focused `RielaAppWebProjectionPolicyTests`, `RielaAppWebAPIRouteTests`, and `RielaAppWebRegistryProviderTests` filter passed 21 tests with zero failures, but lacked executions-list canary coverage. The requested combined GraphQL/web filter passed 130 tests with zero failures. | Return to Step 6 for SR-004/SR-005 and keep SR-003 incomplete until the executions-list regression passes. |
| 2026-07-29 | Step 6 SR-004/SR-005 revision | IMPLEMENTED_WITH_VERIFICATION_BLOCKER | Resolved `comm-000226`: executions-list diagnostics now use `persistedSummary(context: .diagnostic)`, unexpected loader failures return fixed text rather than exception details, and the persisted-session route regression checks short, lowercase, numeric, dictionary-style, and mixed-case canaries on both the executions list and run detail. Changed `Sources/RielaApp/RielaAppWebAPI.swift`, `Tests/RielaAppSupportTests/RielaAppWebAPIRouteTests.swift`, and this plan. | The focused executions-list/run-detail route plus projection-policy filter emitted 5 tests with zero failures before its wrapper timeout; the combined GraphQL/web filter passed 130 tests with zero failures. No TypeScript changed; preceding frontend evidence remains applicable. Focused SwiftLint passed without findings, and scoped `git diff --check` passed. The unskipped AppSupport blocker and operator-owned Playwright/browser QA remain unchanged. | Return to Step 6 self-review with SR-003/SR-004/SR-005 resolved and the established external verification gaps explicit. |
| 2026-07-30 | Step 6 `comm-000230` review revision | IMPLEMENTED_WITH_VERIFICATION_BLOCKER | Registry update and conflict recovery now exit edit mode so revision-bound retain handles cannot remain stale; successful registration also clears its editor. Source-directory mutation recovery is separate from registry recovery, preserves failed input, and refreshes workflow sources. Instance selection now resets on profile changes. Added deterministic selection coverage and authored Playwright regressions for repeated edits, conflict-refresh retry, registration cleanup, and source 409 recovery. Changed `web/src/views/WorkflowsView.tsx`, `web/src/views/InstancesView.tsx`, `web/src/views/InstancesView.test.ts`, `web/e2e/dashboard.spec.ts`, `web/e2e/workflow-management.spec.ts`, and this plan. | `cd web && bun test src` passed 45 tests with 160 assertions across 10 files. TypeScript `tsc --noEmit`, focused ESLint for every changed TypeScript file, `bun run scripts/audit-source.ts`, and `bun run build` all completed successfully in a wrapper that timed out after emitting the successful build result. The revision-scoped `git diff --check` passed. Full Playwright/browser execution remains operator-owned. The unrelated unskipped AppSupport blocker is unchanged because no Swift files changed in this revision. | Return to independent Step 7 review with all `comm-000230` findings addressed and the established external verification gaps explicit. |
| 2026-07-30 | Step 6 `comm-000234` review revision | IMPLEMENTED_WITH_VERIFICATION_BLOCKER | Resolved both high findings from `comm-000234`. Mutable registry actions now require the loaded detail to match the exact selected workflow id and origin and disappear while a replacement selection is loading. Instance editors are keyed by instance identity, retain an editor-owned expected revision across polling, and rebase from the exact instance-detail response after conflict recovery. Added deterministic mutable-selection and instance-editor ownership tests plus authored Playwright regressions for delayed mutable selection, A-to-B instance editing, and external revision conflicts. Updated `web/src/api.ts`, `web/src/views/InstancesView.tsx`, `web/src/views/InstancesView.test.ts`, `web/src/views/WorkflowsView.tsx`, `web/src/views/WorkflowsView.test.ts`, `web/e2e/workflow-management.spec.ts`, and this plan. Recorded implementation `comm-000231`, self-review `comm-000232`, test-integrity `comm-000233`, and review `comm-000234`. | `cd web && bun test src` passed 47 tests with 166 assertions across 11 files. `cd web && ./node_modules/.bin/tsc --noEmit --pretty false` and focused ESLint passed. `cd web && bun run scripts/audit-source.ts && bun run build` passed, with the wrapper timing out after complete successful output. Revision-scoped `git diff --check` passed. No Swift production or test files changed in this revision, so the accepted prior Swift evidence remains applicable. Full Playwright/browser execution remains operator-owned, and the unrelated unskipped AppSupport blocker remains unchanged. | Return to Step 6 self-review and test-integrity review with every high/mid `comm-000234` finding addressed. |
| 2026-07-30 | Step 6 `comm-000238` review revision | IMPLEMENTED_WITH_VERIFICATION_BLOCKER | Resolved all `comm-000238` findings. Exact web `workflow(target:)` reads now reject immutable user origins; inline definitions have deterministic depth checks before temporary projection and after retain expansion; discovered-definition state is keyed to the exact profile/source and hides retained content/errors during replacement loading; bounded validation diagnostics render with truncation state. Added immutable-origin, over-depth/no-mutation, exact source-ownership, diagnostics, and delayed source-selection regressions. Updated `Sources/RielaGraphQL/WorkflowRegistryGraphQL.swift`, `Sources/RielaCLI/WorkflowRegistryGraphQLProvider.swift`, `Tests/RielaAppSupportTests/RielaAppWebRegistryProviderTests.swift`, `web/src/views/WorkflowsView.tsx`, `web/src/views/WorkflowsView.test.ts`, `web/e2e/workflow-management.spec.ts`, and this plan. Refreshed authoritative implementation `comm-000235`, test-integrity `comm-000237`, and review `comm-000238` references. | `cd web && bun test src` passed 48 tests with 170 assertions across 11 files. Node-invoked TypeScript `tsc --noEmit --pretty false`, focused ESLint, source audit, and production build passed. Xcode Swift build passed. `swift test --filter RielaAppWebRegistryProviderTests` passed 9 tests and `swift test --filter RielaGraphQLTests` passed 109 tests; both wrappers timed out only after complete zero-failure output. Focused SwiftLint passed after correcting one closure-layout warning. Full Playwright/browser execution remains operator-owned, and the unrelated unskipped AppSupport blocker remains unchanged. | Return to Step 6 self-review and test-integrity review with all `comm-000238` high/mid findings resolved. |
| 2026-07-30 | Step 6 `comm-000243` adversarial-review revision | IMPLEMENTED_WITH_VERIFICATION_BLOCKER | Resolved all three mid findings and both low findings from adversarial review. Web registration and update now preflight the bounded retain-handle edit projection before publication and return non-failing metadata-only mutation projections; exact schema-path classification keeps unknown fields fail-closed even when their names collide with structural keys. Mutable deletion records prior activation state and a durable cleanup marker so activation-cleanup failure restores both the bundle and activation state. Discovered diagnostics render per-item truncation notices with authored Playwright coverage. Updated `Sources/RielaCLI/WorkflowRegistryGraphQLProvider.swift`, `Sources/RielaCLI/WorkflowRegistryService.swift`, `Sources/RielaCLI/WorkflowMutableRegistry.swift`, `Sources/RielaCLI/WorkflowMutableRegistry+CRUD.swift`, `Sources/RielaCLI/WorkflowMutableRegistry+Registration.swift`, `Sources/RielaCLI/WorkflowMutableRegistryModels.swift`, `Tests/RielaAppSupportTests/RielaAppWebRegistryProviderTests.swift`, `Tests/RielaCLITests/WorkflowMutableRegistryTests.swift`, `web/src/views/WorkflowsView.tsx`, `web/e2e/workflow-management.spec.ts`, and this plan. Refreshed implementation `comm-000239`, self-review `comm-000240`, test-integrity `comm-000241`, ordinary review `comm-000242`, and adversarial review `comm-000243` references. | Focused provider/registry execution passed 23 tests with zero failures; `swift test --filter RielaGraphQLTests` emitted 109 tests with zero failures before wrapper timeout; explicit Xcode `swift build` and focused SwiftLint passed. `cd web && bun test src` passed 48 tests with 170 assertions; TypeScript typecheck, focused ESLint, source audit, and production build passed. Scoped `git diff --check` passed. Full Playwright/browser execution remains operator-owned, and the unrelated unskipped AppSupport blocker remains unchanged. | Return to Step 6 self-review and test-integrity review with every `comm-000243` finding addressed and both external verification gaps explicit. |
| 2026-07-30 | Step 6 `comm-000245` SR-006 revision | IMPLEMENTED_WITH_VERIFICATION_BLOCKER | Resolved SR-006 from self-review of implementation `comm-000244`. Mutable deletion now distinguishes the durable activation-cleanup commit point from pre-commit failures. Pre-commit failures still restore the bundle and activation state and throw; post-commit finalization failures verify the exact durable journal, recover cleanup opportunistically, verify the destination remains absent, and return the accepted deletion result instead of inviting an unsafe retry. Added a deterministic post-commit finalization failure hook and regression in `Sources/RielaCLI/WorkflowMutableRegistry+CRUD.swift`, `Sources/RielaCLI/WorkflowMutableRegistryModels.swift`, and `Tests/RielaCLITests/WorkflowMutableRegistryTests.swift`. | The new targeted regression passed 1 test with zero failures. The complete `WorkflowMutableRegistryTests` filter emitted 13 tests with zero failures before wrapper timeout. The targeted rerun rebuilt the affected Swift targets successfully, and focused SwiftLint passed with no findings. No TypeScript changed; the comm-000244 frontend test, typecheck, lint, audit, and build evidence remains applicable. Full Playwright/browser execution remains operator-owned, and the unrelated unskipped AppSupport blocker remains unchanged. | Return to Step 6 self-review with SR-006 resolved and the two established external verification gaps explicit. |
| 2026-07-30 | Step 6 `comm-000250` adversarial-review revision | IMPLEMENTED_WITH_VERIFICATION_BLOCKER | Resolved both mid and both low findings from `comm-000250`. Native profile switches now advance `Sources/RielaApp/EntryPoint.swift:webRevision`; bootstrap profile identity is visibility-aware polled; instance responses carry profile identity; and `Sources/RielaApp/RielaAppWebAPI.swift` rejects a mismatched `expectedProfile` before revision or configuration mutation. `web/src/App.tsx` and `web/src/views/InstancesView.tsx` clear/key profile-owned editor state and refuse mismatched responses. Extracted the registry filesystem, transaction, activation, catalog, service, and GraphQL provider boundary into `Sources/RielaWorkflowRegistry/`, with `Package.swift` making RielaApp and RielaCLI independent consumers and `Sources/RielaApp/RielaAppWebNoteGraphQL.swift` no longer importing RielaCLI. Preserved CLI catalog injection, locking, root-identity hooks, empty-query validation, and description search through `Sources/RielaCLI/WorkflowCatalogCommands.swift` and `Sources/RielaWorkflowRegistry/WorkflowRegistryCatalog.swift`. Added a deterministic one-time committed-delete recovery failure and later-access cleanup regression in `Tests/RielaCLITests/WorkflowMutableRegistryTests.swift`. Refreshed implementation `comm-000246`, test-integrity `comm-000248`, ordinary review `comm-000249`, and adversarial review `comm-000250` references. | `cd web && bun test src && node ./node_modules/typescript/bin/tsc --noEmit --pretty false && ./node_modules/.bin/eslint src/App.tsx src/contracts.ts src/views/InstancesView.tsx src/views/InstancesView.test.ts && bun run build` passed 50 tests with 173 assertions, typecheck, focused lint, and production build. Explicit Xcode `swift build` passed. `swift test --skip-build --filter WorkflowMutableRegistryTests` passed 14 tests; the combined `RielaGraphQLTests`, `RielaAppWebAPIRouteTests`, and `RielaAppWebRegistryProviderTests` filter passed 131 tests; the catalog, temporary-registration, secure-read, and shared-node compatibility matrix passed 43 tests; and `swift test --skip-build --filter RielaAppSupportTests --skip 'DaemonWorkflowNodePatchTests.testRuntimeRestartsWorkflowWhenEventSourceExits'` passed 241 tests. The targeted deferred-cleanup and stale-profile route regressions passed. Full Playwright/browser execution remains operator-owned, and the unrelated unskipped AppSupport blocker remains unchanged. | Return to Step 6 self-review and test-integrity review with every `comm-000250` finding addressed and the established external verification gaps explicit. |
| 2026-07-30 | Step 6 implementation `comm-000251` / self-review `comm-000252` | NEEDS_REVISION | `comm-000251` correctly added native profile observability, stale-profile instance mutation rejection, the narrow `RielaWorkflowRegistry` target, and deferred committed-delete cleanup coverage. Self-review `comm-000252` found that `web/src/views/SettingsView.tsx` and the workflow-source directory form still retained profile-A values while their REST mutations lacked `expectedProfile`, leaving stale Assistant, Notes, and source-directory writes able to target profile B. | Prior `comm-000251` frontend, Swift, registry, compatibility, import-isolation, and diff checks passed, but no regression switched profile ownership for Settings or source-directory mutations. | Return to Step 6; keep `comm-000251` marked `NEEDS_REVISION` until both stale-profile mutation regressions pass. |
| 2026-07-30 | Step 6 `comm-000252` self-review revision | IMPLEMENTED_WITH_VERIFICATION_BLOCKER | Resolved both `comm-000252` mid findings. `Sources/RielaApp/RielaAppWebAPI.swift` now includes profile identity in workflow-source, Assistant, and Notes responses and rejects missing or mismatched `expectedProfile` before revision and persistence checks. `web/src/App.tsx` keys Settings and Workflows by profile; `web/src/views/SettingsView.tsx` and `web/src/views/WorkflowsView.tsx` verify response ownership and send profile-bound mutations; source-directory drafts and mutation state clear on profile transitions. Added deterministic no-side-effect route coverage for stale Assistant, Notes, and source-directory requests, plus a source-draft profile-transition unit regression. Updated `web/src/api.ts`, `web/src/contracts.ts`, `web/src/views/InstancesView.tsx`, `web/src/views/SettingsView.tsx`, `web/src/views/WorkflowsView.tsx`, focused web tests/e2e fixtures, `Tests/RielaAppSupportTests/RielaAppWebAPIRouteTests.swift`, and this plan. | `cd web && bun test src && node ./node_modules/typescript/bin/tsc --noEmit --pretty false && ./node_modules/.bin/eslint src/api.ts src/App.tsx src/contracts.ts src/views/InstancesView.tsx src/views/InstancesView.test.ts src/views/SettingsView.tsx src/views/WorkflowsView.tsx src/views/WorkflowsView.test.ts e2e/dashboard.spec.ts e2e/workflow-management.spec.ts && bun run build` passed 51 tests with 175 assertions, typecheck, focused lint, and production build. Explicit Xcode `swift build` passed, and `swift test --skip-build --filter RielaAppWebAPIRouteTests` passed 11 tests including the stale-profile no-mutation matrix. Full Playwright/browser execution remains operator-owned, and the unrelated unskipped AppSupport blocker remains unchanged. | Return to Step 6 self-review with every `comm-000252` mid finding addressed and external verification gaps explicit. |
| 2026-07-30 | Step 6 implementation `comm-000253` / self-review `comm-000254` | NEEDS_REVISION | `comm-000253` correctly profile-bound every profile-owned REST mutation and keyed Settings and Workflows state. Self-review `comm-000254` found that Notes GraphQL still resolved against the current daemon profile while `NotesView` retained profile-owned state and requests carried no expected profile identity. | The `comm-000253` frontend gate passed 51 tests with 175 assertions plus typecheck, lint, and build; Swift build and 11 route tests passed. Inspection confirmed that Notes GraphQL carried only CSRF/auth headers and had no stale-profile mutation regression. | Return to Step 6; keep `comm-000253` marked `NEEDS_REVISION` until Notes GraphQL rejects the stale profile before executor construction. |
| 2026-07-30 | Step 6 `comm-000254` self-review revision | NEEDS_REVISION | Partially resolved the `comm-000254` mid finding. `web/src/api.ts` binds RielaApp GraphQL headers to the bootstrapped profile, `web/src/App.tsx` keys `NotesView` by profile identity, and `Sources/RielaApp/RielaAppWebRouter.swift` added stale-profile rejection. However, self-review `comm-000256` found that router validation and RielaApp executor snapshot used separate MainActor hops, leaving an interleaving race. | The frontend gate passed 52 tests with 178 assertions, typecheck, focused lint, and production build. Explicit Xcode `swift build` passed, and the rebuilt route suite passed 12 tests, but its profile-switch coverage was sequential rather than interleaved. | Return to Step 6; keep implementation `comm-000255` marked `NEEDS_REVISION` until atomic binding and deterministic interleaving coverage pass. |
| 2026-07-30 | Step 6 `comm-000256` self-review revision | IMPLEMENTED_WITH_VERIFICATION_BLOCKER | Resolved the `comm-000256` mid finding by moving `X-Riela-Profile` comparison and `daemonProfileName` executor snapshot into the same MainActor-isolated `RielaApp.webNoteGraphQLResponse` entry point. The router now performs only transport security before the single app actor call. Added a deterministic router interleaving hook and regression that switches from profile A to B after request ingress but before atomic binding, asserts `profile_conflict`, and proves the same folder identifier is absent from profile B. Updated `Sources/RielaApp/RielaAppWebRouter.swift`, `Sources/RielaApp/RielaAppWebNoteGraphQL.swift`, `Tests/RielaAppSupportTests/RielaAppWebAPIRouteTests.swift`, and this plan. | The rebuilt `swift test --filter RielaAppWebAPIRouteTests` suite passed 13 tests with zero failures, including `testGraphQLProfileBindingIsAtomicAcrossRouterInterleaving`; its wrapper timed out only after emitting complete success and build output. Explicit Xcode `swift build` completed successfully. Focused SwiftLint passed with no findings through the direct packaged binary, and scoped `git diff --check` plus plan trailing-whitespace validation passed. No TypeScript changed, so the `comm-000255` 52-test/typecheck/lint/build evidence remains applicable. | Return to Step 6 self-review with the `comm-000256` mid finding resolved and the established external verification gaps explicit. |
| 2026-07-30 | Step 6 `comm-000261` adversarial-review revision | IMPLEMENTED_WITH_VERIFICATION_BLOCKER | Resolved both mid findings and the low documentation finding from adversarial review `comm-000261`. Added bounded SQLite summary and diagnostic queries in `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+WebSummaries.swift`; `Sources/RielaViewer/WorkflowViewer.swift` now lists at most 101 summaries and directly loads a selected session while verifying its workflow identity; `Sources/RielaApp/RielaAppWebAPI.swift` uses those bounded paths for five-second polling. `web/src/views/RunDetailView.tsx` now attributes routing evidence only by exact `sourceStepExecutionId` and renders records without a visible source execution separately. Added a 125-session persistence regression in `Tests/RielaCoreTests/SessionObservabilityTests.swift`, bounded-loader and foreign-session coverage in `Tests/RielaViewerTests/WorkflowViewerTests.swift`, and multi-attempt routing coverage in `web/src/views/RunDetailView.test.ts`. Refreshed implementation `comm-000257`, self-review `comm-000258`, test-integrity `comm-000259`, ordinary review `comm-000260`, and adversarial review `comm-000261` references. | `cd web && bun test src && node ./node_modules/typescript/bin/tsc --noEmit --pretty false && ./node_modules/.bin/eslint src/views/RunDetailView.tsx src/views/RunDetailView.test.ts && bun run build` passed 53 tests with 181 assertions, typecheck, focused lint, and production build. `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build` passed. `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'SessionObservabilityTests|WorkflowViewerTests|RielaAppWebAPIRouteTests'` rebuilt the affected targets and passed 38 tests with zero failures, including the bounded 125-session persistence and loader regressions, foreign-session rejection, and 13 web route tests. Focused SwiftLint and `git diff --check -- Package.swift README.md Sources Tests web impl-plans design-docs` passed. Full Playwright/browser execution remains operator-owned, and the unrelated unskipped AppSupport blocker remains unchanged. | Return to Step 6 self-review, test-integrity review, ordinary review, and adversarial review with every `comm-000261` finding addressed and the established external verification gaps explicit. |
| 2026-07-30 | Step 6 `comm-000263` self-review revision | IMPLEMENTED_WITH_VERIFICATION_BLOCKER | Resolved both mid findings and the low documentation finding from self-review `comm-000263`. `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+WebSummaries.swift` now prepares legacy/partial summary columns completely before using indexed polling and directly loads selected-session metadata, diagnostics, loop evidence, message count, and only the newest 201 routing records. `Sources/RielaCore/SQLiteWorkflowMessageLog.swift` adds the session/order index used by the bounded query. `Sources/RielaViewer/WorkflowViewer.swift` carries message totals and loop evidence from that single detail query, while `Sources/RielaApp/RielaAppWebAPI.swift` no longer reloads the full snapshot. Added a 525-row pre-migration regression whose selected workflow lies beyond the former 500-row batch and a 350-message integration regression proving only 201 routing records are materialized without payloads. Extracted `WorkflowViewerSessionSummary` to `Sources/RielaViewer/WorkflowViewerSessionSummary.swift` to keep changed Swift sources below the repository size threshold. Refreshed implementation `comm-000262` and self-review `comm-000263` references. | Explicit Xcode `swift build` passed. The first combined focused run passed all existing route/viewer/core tests but exposed a non-fractional timestamp in the new legacy fixture; after correcting the fixture, its targeted rerun passed. The final combined `SessionObservabilityTests`, `WorkflowViewerTests`, and `RielaAppWebAPIRouteTests` run passed 40 tests with zero failures. Focused SwiftLint reported no findings, and `git diff --check -- Package.swift README.md Sources Tests web impl-plans design-docs` passed. No TypeScript changed, so the `comm-000262` 53-test/typecheck/ESLint/build evidence remains applicable. Full Playwright/browser execution remains operator-owned, and the unrelated unskipped AppSupport blocker remains unchanged. | Return to Step 6 self-review and the remaining independent reviews with every `comm-000263` finding addressed and the established external verification gaps explicit. |
| 2026-07-30 | Operator takeover after `maxStepsExceeded(80)` during the final adversarial re-review | COMPLETED | Operator-owned verification executed and three browser-only defects fixed: (1) `web/src/api.ts` stored bare `fetch` as the default transport, throwing `Illegal invocation` on every request in real Chromium (unit tests inject a mock transport and cannot catch this); (2) `web/src/workflows/client.ts` had the same unbound `fetch` default for the registry GraphQL client; (3) `web/src/views/LogsView.tsx` wrapped the instance `<select>` inside its `<label>`, polluting the accessible name with option text so `getByLabel('Instance', { exact: true })` never matched, and `web/src/views/InstancesView.tsx` embedded the workflow-variables hint inside the label — both restructured to sibling label/`aria-describedby` markup. | `swift build -c release` passed. Focused Swift suites passed with zero failures: web observability/projection 55, mutable+GraphQL registry 43, full RielaGraphQLTests 109, catalog/registration compatibility 43, RielaAppSupportTests 243 (skipping the known unrelated daemon fixture flake). `cd web && bun test src` passed 53 tests with 181 assertions; `tsc --noEmit` and `bun run build` passed; the complete Playwright suite passed 45 tests in Chromium against the repo's google-chrome. Import isolation holds: `rg 'import RielaCLI' Sources/RielaApp` returns no matches. | Plan complete; commit and pull request handled by the operator. |
