# Work Runtime P1: Capability placement and host-aware authoring

**Status**: Step 4 revised; Step 5 review pending; implementation not certified.
**Workflow mode**: issue-resolution
**Issue reference**: workflow-input:Complete the Work Runtime P1 dependency DAG (number/url: null)
**Design reference**: `design-docs/specs/design-work-runtime-consolidation.md`, §17.1–17.6 and the sections identified below.
**Review source**: `comm-000004`, `step3-design-review-attempt-1-exec-4`, `accepted`; findings/feedback empty; no Step 5 feedback supplied.
**Codex-agent references**: `workflowExecutionId:codex-design-and-implement-review-loop-session-1`, `issueCommunicationId:comm-000002`, `intakeExecutionId:step1-issue-intake-attempt-1-exec-2`, `communicationId:comm-000004`, `designStepId:step2-design-doc-update`, `stepId:step3-design-review`, `stepId:step4-impl-plan-create`, `designAuthorModel:gpt-6-astra`, `planAuthorModel:gpt-6-astra`, `gateModel:gpt-5.6-sol`, `implementationModel:gpt-5.6-terra`; downstream executions record actual IDs.
**Updated**: 2026-09-22

```json
{
  "planId": "p1-capabilities",
  "planPath": "impl-plans/active/work-runtime-p1-capabilities.md",
  "dependsOn": [
    "p1-reservation"
  ],
  "writePaths": [
    "Sources/RielaCore/BackendCapability.swift",
    "Sources/RielaCore/WorkflowBackendPolicy.swift",
    "Sources/RielaCore/WorkflowRequirements.swift",
    "Sources/RielaCore/WorkflowModel.swift",
    "Sources/RielaCore/WorkflowNodeValidation.swift",
    "Sources/RielaCore/WorkflowValidationHelpers.swift",
    "Sources/RielaCore/DistributedWorkerModels.swift",
    "Sources/RielaAdapters/BackendCapabilityProbe.swift",
    "Sources/RielaAdapters/AgentGatewayNodeAdapter.swift",
    "Sources/RielaWork/BackendCapabilityPlacement.swift",
    "Sources/RielaWork/WorkStore+Hosts.swift",
    "Sources/RielaWork/WorkStore+Schema.swift",
    "Sources/RielaCLI/DoctorCommand.swift",
    "Sources/RielaCLI/DistributedWorkerCommand.swift",
    "Sources/RielaCLI/WorkflowValidateInspectCommands.swift",
    "Sources/RielaCLI/RielaArgumentParser+WorkflowAndMemory.swift",
    "Sources/RielaCLI/HostCapabilityResolver.swift",
    "Sources/RielaServer/DistributedWorkerProtocol.swift",
    "Sources/RielaServer/DistributedWorkerHTTPRouter.swift",
    "Sources/RielaServer/DistributedWorkerHTTPClient.swift",
    "Tests/RielaWorkTests/BackendCapabilityPlacementTests.swift",
    "Tests/RielaCLITests/DoctorBackendCapabilityTests.swift",
    "Tests/RielaCLITests/WorkflowHostCapabilityTests.swift",
    "Tests/RielaCLITests/DistributedWorkerConfigurationTests.swift",
    "Tests/RielaCoreTests/WorkflowBackendPolicyTests.swift",
    "Tests/RielaAdaptersTests/BackendCapabilityProbeTests.swift",
    "impl-plans/progress/p1-capabilities.md",
    "Sources/RielaAppSupport/DaemonWorkflowSupport.swift",
    "Sources/RielaAppSupport/RielaAppDaemonWorkflowStore.swift",
    "Tests/RielaAppSupportTests/HostCapabilityConfigurationTests.swift"
  ],
  "sharedPaths": [
    "Sources/RielaCLI/RielaArgumentParser+WorkflowAndMemory.swift",
    "Sources/RielaCLI/WorkflowValidateInspectCommands.swift",
    "Sources/RielaWork/WorkStore+Schema.swift"
  ],
  "progressLog": "impl-plans/progress/p1-capabilities.md",
  "taskIds": [
    "P1-4",
    "P1-5"
  ],
  "verificationCommands": [
    "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --scratch-path tmp/work-runtime-p1/build/p1-capabilities",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-capabilities --filter 'BackendCapabilityPlacementTests|DoctorBackendCapabilityTests|WorkflowHostCapabilityTests|DistributedWorkerConfigurationTests|WorkflowBackendPolicyTests|BackendCapabilityProbeTests|HostCapabilityConfigurationTests'",
    "git diff --check",
    "xargs -0 env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < tmp/work-runtime-p1/p1-capabilities/changed-swift-files.nul",
    "DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint --quiet --no-cache"
  ],
  "dependencyMode": "native-accepted-predecessor-DAG",
  "evidenceDirectory": "tmp/work-runtime-p1/p1-capabilities/"
}
```

The execution, overwrite protection, evidence, and completion contract in
`impl-plans/active/work-runtime-p1-dispatcher-guard-director.md` applies to this plan.
No worker edits another worker’s progress log or marks a shared plan complete.


## Intent, context, non-goals and invariants

User intent is honest capability diagnostics and deterministic legal placement
shared by dispatch and authoring. Generic runner capability diagnostics are not
the missing host/backend implementation. Consume accepted reservation placement
values/transaction seam; this wave owns schema while lifecycle owns decisions.
Non-goals: new planner, task serve, GraphQL host/task APIs, GUI controls, new
credential system, login/inference probes, new probing framework or migration
of legacy supervision. Add only accepted §5a/§17.4 behavior.

| Exact files (new names are intended destinations) | Smallest intended change / acceptance |
| --- | --- |
| `Sources/RielaCore/BackendCapability.swift`, `WorkflowBackendPolicy.swift`, `WorkflowRequirements.swift` | Neutral snapshot/policy/entry-reachable requirement values and shared projection; provenance retained through calls/cycles. |
| `Sources/RielaCore/WorkflowModel.swift`, `WorkflowNodeValidation.swift`, `WorkflowValidationHelpers.swift` | Decode/validate policy/model/pin constraints at existing boundaries; preserve ordinary structural validation. |
| `Sources/RielaCore/DistributedWorkerModels.swift` | Carry declared/observed host values in existing registration models. |
| `Sources/RielaAdapters/BackendCapabilityProbe.swift`, `AgentGatewayNodeAdapter.swift` | Bounded injectable version/auth/config probes for the seven supported backends; concrete backend logic stays in adapters; no inference/login/secrets in diagnostics. |
| `Sources/RielaWork/BackendCapabilityPlacement.swift`, `WorkStore+Hosts.swift`, `WorkStore+Schema.swift` | One merged fresh snapshot, deterministic per-node placement, work_hosts persistence; use reservation's atomic placement seam. |
| `Sources/RielaCLI/HostCapabilityResolver.swift`, `DoctorCommand.swift`, `DistributedWorkerCommand.swift` | Compose snapshot refresh, doctor text/JSON and worker.json declarations; fresh read-only mode for validation/dry-run. |
| `Sources/RielaCLI/WorkflowValidateInspectCommands.swift`, `RielaArgumentParser+WorkflowAndMemory.swift` | Shared usage projection, --host/--strict-host and warning/failure semantics; no persisted refresh. |
| `Sources/RielaServer/DistributedWorkerProtocol.swift`, `DistributedWorkerHTTPRouter.swift`, `DistributedWorkerHTTPClient.swift` | Round-trip capability payload through existing worker registration without inventing liveness/capacity. |
| `Sources/RielaAppSupport/DaemonWorkflowSupport.swift`, `RielaAppDaemonWorkflowStore.swift` | Backends declarations in existing profile config; read-only decoder never quarantines corrupt files. No UI changes. |
| Seven test files in writePaths | Deterministic probe/merge, placement, policy, doctor/validation, worker/profile round-trip and read-only regression cases. |
| `impl-plans/progress/p1-capabilities.md` | Record snapshot/resolver/probe/placement signatures and planner-input shape/hash for dispatch. |

Invariants: Core never imports Work; explicit pin never falls back; explicit
enable can remain usable/unverified even after failed auth, but cannot waive
executable/env requirements or invent capacity; disabled wins; equality is
stale; failed refresh never reuses stale success; selected entry/called targets
supply requirements; validation/dry-run never write or quarantine input state.

## Intended changes and acceptance (§5a, §17.4)

- [ ] **P1-4a** Add neutral capability/source/freshness, backend policy and
  reachable requirement values at the existing Core model boundary; task
  placement/store code remains in Work, CLI composes it, and concrete version,
  authentication and SDK configuration probes stay in Adapters. No reverse
  Core-to-Work dependency or new generic probing framework. Cover all seven
  existing supported backends. Probe only bounded version/auth/config state,
  never login, mutate credentials, or perform model inference; unsupported
  auth is unknown. Record bounded redacted failures and environment names/
  presence only. Injectable clock/process probes make tests deterministic.
- [ ] **P1-4b** Store `work_hosts` snapshots and add `backends` declarations to
  the existing local profile config (`RielaAppDaemonWorkflowState` in
  Sources/RielaAppSupport/DaemonWorkflowSupport.swift and its
  RielaAppDaemonWorkflowStore) and worker.json/registration path, carrying
  capabilities through current server registration transport. Preserve profile configuration round trips; do not use the store
  loader's corrupt-file quarantine during validation/dry-run. Add read-only
  decoding that reports incompatible/corrupt config without moving or writing
  files. No new GraphQL configuration or UI control is required in P1. Declared disable wins; explicit enable with failed/absent probe
  remains usable/unverified, including failed auth, which stays visible.
  Otherwise observations govern. Declared models override observed lists.
  Declarations never create worker liveness/capacity or waive executable/env
  requirements. Doctor text and JSON expose availability/auth/models/version/
  source/freshness/failures and refresh local snapshots.
- [ ] **P1-4c** Reject pin+policy, empty/duplicate allowed, preferred outside
  allowed, unknown backends, invalid model keys and ambiguous models. A pin
  never falls back. Choose preferred then remaining allowed in authored order;
  enforce known nonempty model lists; missing lists make explicit models
  unverified. Project from chosen start/resume/rerun/recovery entry across every
  possible transition and called entry, cycles once. Reused prefixes and
  unreachable nodes add no requirements; unresolved executable targets fail
  resolution. Deduplicate stably while retaining node/step provenance.
- [ ] **P1-4d** Respect explicit host/step assignments and worker groups; local
  first for unassigned work, then live capacity-bearing workers by ID. Require
  all assigned nodes to fit on a candidate; never evade an explicit assignment.
  Resolve one merged snapshot with finite freshness/probe bounds. Equality is
  stale; dispatch refreshes before reservation and cannot reuse stale success
  after failed refresh. Record per-node host/backend/source/time/freshness;
  no complete placement yields wait(.capacity) without an attempt. Return
  placement evidence to the reservation owner, never separately write it
  after reservation. Expose read-only/in-memory probe mode for validation and
  dry-run, with no cache or database initialization side effects.
- [ ] **P1-5** Share projection with workflow usage, workflow validate --host
  and --strict-host. Strict requires host; structural errors always fail;
  missing/auth/stale/unverified host gaps warn by default and fail strict.
  Group validation requires complete legal placement. Validation never persists
  host refreshes. Supply the intended host snapshot as input context for authored planner
  workflow nodes; generated plans use the same resolver. Integration passes
  this context through dispatcher workflow variables; do not build a new planner.
  Serial finalization updates the directly affected authoring guidance.

Deliverables: backend/placement models, bounded adapter probes, declaration and
registration transport, host persistence, doctor and validation/usage output,
and the named suites. Tests cover all merge combinations including explicit
failed-auth enable, stale equality/failed refresh, model/policy validation,
called workflows/cycles/recovery prefixes, worker groups/liveness/capacity,
environment/add-on failures, per-node choices, read-only validation, and stable
JSON/text output. Real local doctor output is diagnostic evidence; deterministic
injected probes establish semantics without requiring every backend installed.

May run beside lifecycle after reservation is accepted. This worker alone owns
the schema in this wave; lifecycle owns decision storage in its separate file.
Any common unlisted file is a serial integration edit, never a second writer.

## Verification and completion

Run these commands in the foreground and record final exit status and complete
log paths in the plan-owned progress log. Named new suites below are required
deliverables, not claims that they already exist. Zero selected tests is a
failed gate; record the discovered test names and positive executed counts.

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --scratch-path tmp/work-runtime-p1/build/p1-capabilities
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-capabilities --filter 'BackendCapabilityPlacementTests|DoctorBackendCapabilityTests|WorkflowHostCapabilityTests|DistributedWorkerConfigurationTests|WorkflowBackendPolicyTests|BackendCapabilityProbeTests|HostCapabilityConfigurationTests'
git diff --check
```

Also run the changed-file strict SwiftLint gate defined in the root plan for
this plan's actual Swift write set, including new untracked files. Retain P0
assertions affected by these changes. Each unchecked task below requires its
specified acceptance assertions, passing build/typecheck, focused tests and
lint, complete evidence, and independent review with no unresolved high/mid
finding. Passing this plan alone does not close P1. Report blocked commands
explicitly; never substitute source-text assertions for behavioral tests.

## Evidence-producing command contract

Run each metadata verificationCommands entry in the foreground from repository
root, one command per immutable log under the evidenceDirectory above; retain
handles and poll through exit. Build establishes compile/typecheck. Focused
filters must exercise every named suite with positive executed counts and the
acceptance cases in this plan; missing/zero-test suites, timeout or incomplete
logs block acceptance. Diff checks establish patch hygiene, not behavior.
Strict lint uses the NUL manifest of surviving touched AND new Swift files from
intent/change evidence. Capture repository lint before edits and after the final
plan tree; compare diagnostics and fail new attributable issues while recording
unrelated baseline findings. Do not run xargs on an empty manifest; record why
no Swift file changed. Finalization lints the union of all accepted write sets.

Record exact command, start/end, finalExitStatus, completeLogPath, per-suite
testCount (null for non-tests), source hashes and review decision in
`verification-evidence.json` in this plan's evidenceDirectory and its progressLog.
Use numbered attempt subdirectories for reruns; retain logs through handoff.
All common per-edit fresh-read/pre/post SHA-256, immutable intent, drift-stop,
join/changeTracking and serial repair rules in the dispatcher contract apply.
Only this plan's implementation owner appends to its progressLog; it may not
mark another plan or shared index complete. Documentation refresh and final
checkbox/index reconciliation belong to p1-finalize after independent acceptance.

Current §17.6 inventory found no capability implementation. The files and
suites above are deliverables, not inherited passing evidence. Consume the
accepted reservation schema generation and placement-evidence seam, then hand
its updated schema hash and resolver signatures to dispatch; do not overwrite
retained request uniqueness or cancellation provenance constraints.
