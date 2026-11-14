# P1 capabilities progress

Issue: `comm-000002: Complete the Work Runtime P1 dependency DAG`
Plan: `p1-capabilities`
Step: `step6-implement` (`nested-v1-1a10633d2b01b2a93350befcffd33f8be00a53a542fd326e6bbc0bd32313f5f6`)

## Attempt 1 — 2026-09-23

Dependency admission was confirmed from authoritative runtime data: `p1-reservation` is present in `acceptedPlanIds`. The current tree had no P1 capability implementation. This attempt added the Core-owned neutral `BackendCapability` snapshot model and `WorkflowBackendPolicy` model/validator, exposed policy on `AgentNodePayload` with backward-compatible optional decoding, and connected the established agent validator. `WorkflowBackendPolicyTests` covers policy ambiguity, stable preference ordering, known-model rejection, strict freshness equality, and legacy payload decoding.

This is not completion of P1-4/P1-5: adapter probes, host persistence/placement, profile/worker transport, CLI doctor/host validation, and their required suites remain unimplemented. No completion checkbox was changed.

### Verification

| Command | Exit | Complete log | Result |
| --- | ---: | --- | --- |
| `CLANG_MODULE_CACHE_PATH=$PWD/tmp/work-runtime-p1/p1-capabilities/attempt-1/clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=$PWD/tmp/work-runtime-p1/p1-capabilities/attempt-1/clang-module-cache /usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --disable-sandbox --skip-update --scratch-path tmp/work-runtime-p1/build/p1-capabilities --filter 'WorkflowBackendPolicyTests'` | 1 | `tmp/work-runtime-p1/p1-capabilities/attempt-1/logs/workflow-backend-policy-tests.log` | Blocked before compilation: network sandbox could not resolve `github.com` to fetch `agent-gateway`. |
| `find Sources/RielaCore/BackendCapability.swift Sources/RielaCore/WorkflowBackendPolicy.swift Sources/RielaCore/WorkflowModel.swift Sources/RielaCore/WorkflowNodeValidation.swift Tests/RielaCoreTests/WorkflowBackendPolicyTests.swift -print0 | xargs -0 env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:\$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache` | 0 | `tmp/work-runtime-p1/p1-capabilities/attempt-1/logs/touched-swiftlint.log` | Passed. |
| `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --scratch-path tmp/work-runtime-p1/build/p1-capabilities` | 1 | `tmp/work-runtime-p1/p1-capabilities/attempt-1/logs/build.log` | Blocked before compilation by denied default Clang module-cache path. |
| `/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-capabilities --filter 'BackendCapabilityPlacementTests|DoctorBackendCapabilityTests|WorkflowHostCapabilityTests|DistributedWorkerConfigurationTests|WorkflowBackendPolicyTests|BackendCapabilityProbeTests|HostCapabilityConfigurationTests'` | 1 | `tmp/work-runtime-p1/p1-capabilities/attempt-1/logs/required-focused-tests.log` | Blocked before discovery by denied default Clang module-cache path; no selected-test count is available. |
| `git diff --check` | 0 | `tmp/work-runtime-p1/p1-capabilities/attempt-1/logs/diff-check.log` | Passed. |

### Handoff risks

- Required focused suite filter remains incomplete and has no positive selected-test count.
- All remaining P1-4/P1-5 integration surfaces must be implemented before test-integrity or adversarial acceptance.
- Reservation and sandbox changes were preserved and not modified.

## Attempt 2 — comm-000030 policy repair

Addressed the two policy findings: `WorkflowBackendPolicy` now matches §5a's `allowed`, ordered `preferred`, and `modelByBackend` JSON contract; validation no longer force-unwraps an empty allowed list. Added direct Codable and malformed empty-policy coverage. Strict touched-file SwiftLint passed: `tmp/work-runtime-p1/p1-capabilities/attempt-2-touched-swiftlint.log` (exit 0).

The P1-4/P1-5 high finding remains unresolved: required placement, probe, transport, persistence, CLI/profile surfaces and named suites are still absent. Do not repeat integrity acceptance until those deliverables and positive counts exist.

## Attempt 3 — comm-000036 deterministic test repair

Corrected the policy-order expected value and malformed-fixture diagnostic count (seven). Strict touched-file SwiftLint and `git diff --check` passed (exit 0): `tmp/work-runtime-p1/p1-capabilities/attempt-3-touched-swiftlint.log`, `tmp/work-runtime-p1/p1-capabilities/attempt-3-diff-check.log`. The policy test remained blocked before compilation because the sandbox cannot resolve `github.com`: `tmp/work-runtime-p1/p1-capabilities/attempt-3-workflow-backend-policy-tests.log` (exit 1). P1-4/P1-5 remains incomplete.

## Attempt 4 — Step 6 implementation self-check (2026-09-23)

Dependency admission remains satisfied by the authoritative runtime payload:
`p1-reservation` is present in `acceptedPlanIds`. I re-read the committed
capabilities plan and accepted design, then inventoried the moving shared tree.
The retained Core-only implementation is unchanged in scope: neutral
`BackendCapability`, `WorkflowBackendPolicy`, optional
`AgentNodePayload.backendPolicy`, validator diagnostics, and five focused
policy tests. The required P1-4/P1-5 probes, reachable-requirement projection,
host persistence/placement, profile and worker transport, doctor and
`workflow validate --host/--strict-host` projection, and named suites are
still absent. No checkbox is complete.

The exact required scratch-path build failed before a source-level capability
test because the sandbox cannot write the default Clang module cache. The
required current-tree fallback used a plan-local writable module cache and
compiled the capability Core files, but failed in concurrent lifecycle work:
`WorkStore+Decisions.swift` accesses private `WorkStore.decodeRows`. This is
outside this plan's write ownership, so no repair was made. `git diff --check`
passed on the shared tree. The required focused test and lint gates remain
incomplete because a stable compiling combined tree is not available; no
positive required-suite count was produced in this attempt.

### Attempt 4 verification

| Command | Exit | Complete log | Result |
| --- | ---: | --- | --- |
| `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --scratch-path tmp/work-runtime-p1/build/p1-capabilities` | 1 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6/attempt-1/build.log` | Blocked before compilation: default Clang module-cache path is not writable. |
| `CLANG_MODULE_CACHE_PATH=$PWD/tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6/attempt-1/clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=$PWD/tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6/attempt-1/clang-module-cache /usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --disable-sandbox --skip-update` | 1 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6/attempt-1/build-fallback.log` | Capability Core files compiled; shared lifecycle compilation then failed because `WorkStore+Decisions.swift` calls private `decodeRows`. |
| `git diff --check` | 0 | terminal output, Step 6 current tree | Passed on the current shared tree. |
| `CLANG_MODULE_CACHE_PATH=$PWD/tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6/attempt-1/clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=$PWD/tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6/attempt-1/clang-module-cache /usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --disable-sandbox --skip-update --filter 'BackendCapabilityPlacementTests|DoctorBackendCapabilityTests|WorkflowHostCapabilityTests|DistributedWorkerConfigurationTests|WorkflowBackendPolicyTests|BackendCapabilityProbeTests|HostCapabilityConfigurationTests'` | 1 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6/attempt-1/focused-tests-fallback.log` | Cancelled because concurrent shared-tree work modified `Sources/RielaWork/WorkGuard.swift` during compilation; no complete positive selected-test count. |
| `find Sources/RielaCore/BackendCapability.swift Sources/RielaCore/WorkflowBackendPolicy.swift Sources/RielaCore/WorkflowModel.swift Sources/RielaCore/WorkflowNodeValidation.swift Tests/RielaCoreTests/WorkflowBackendPolicyTests.swift -print0 | xargs -0 env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache` | 0 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6/attempt-1/touched-swiftlint-2.log` | Passed for retained Core capability files. |

### Attempt 4 handoff risks

- Do not accept P1-4/P1-5: named capability suites remain absent and no required focused filter has a positive complete test count.
- Serial reconciliation must repair the unrelated `WorkStore.decodeRows` access failure before a stable combined-tree verification run.
- Preserve concurrent sandbox, reservation, and lifecycle edits; this attempt changed only this progress record and Step 6 evidence.

## Attempt 5 — Step 6 Core policy reconciliation (2026-09-23)

The retained Core slice had a material inconsistency with §5a: an agent node
using `backendPolicy` instead of an `executionBackend` was still rejected when
it declared a provider. `validateAgentNodePayload` now accepts that authored
selection while retaining the existing no-selection failure. A regression
constructs a valid provider with a policy-only selection. No completion
checkbox changed: P1-4/P1-5 still lack all required adapter probes, reachable
requirements, declaration merge, host persistence and placement, profile and
worker transport, CLI projections, and named suite coverage.

### Attempt 5 verification

| Command | Exit | Complete log | Result |
| --- | ---: | --- | --- |
| `CLANG_MODULE_CACHE_PATH=$PWD/tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-attempt-1/clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=$PWD/tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-attempt-1/clang-module-cache /usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --disable-sandbox --skip-update --filter 'WorkflowBackendPolicyTests'` | 0 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-attempt-1/logs/workflow-backend-policy-tests-retry.log` | Passed: 5 selected tests, 0 failures. |
| Required focused filter from the plan, with the same cache variables | 1 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-attempt-1/logs/required-focused-tests-fallback.log` | Blocked before test discovery by concurrent lifecycle source error: `WorkStore+Decisions.swift` calls `decisionEvidenceId` as a function. |
| Strict touched-file SwiftLint | 0 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-attempt-1/logs/touched-swiftlint-retry.log` | Passed. |
| Full SwiftLint | 0 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-attempt-1/logs/full-swiftlint.log` | Passed with pre-existing warnings. |

## Attempt 6 — Step 6 current-tree verification (2026-09-23)

Dependency admission remains satisfied by the authoritative runtime payload:
`p1-reservation` is in `acceptedPlanIds`. Fresh source inventory confirms that
the retained implementation is only the Core policy slice: `BackendCapability`,
`WorkflowBackendPolicy`, optional `AgentNodePayload.backendPolicy`, node policy
diagnostics, and `WorkflowBackendPolicyTests`. P1-4/P1-5 remain incomplete:
reachable requirements, bounded adapter probes, declaration merge, host
persistence/placement, profile and worker transport, doctor and host-aware
validate/usage projections, and the required named suites are absent.

The self-check also found two integration gaps to be addressed by the remaining
owned implementation: ordinary `DefaultWorkflowValidator` does not project
agent-policy diagnostics, and policy-only nodes cannot execute until placement
materializes their selected backend. No checkbox was changed and no concurrent
worker source change was modified.

### Attempt 6 verification

| Command | Exit | Complete log | Result |
| --- | ---: | --- | --- |
| `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --scratch-path tmp/work-runtime-p1/build/p1-capabilities` | 1 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6/attempt-2/logs/build-retry.log` | Blocked before compilation: default Clang module-cache path is not writable. |
| `/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-capabilities --filter 'BackendCapabilityPlacementTests|DoctorBackendCapabilityTests|WorkflowHostCapabilityTests|DistributedWorkerConfigurationTests|WorkflowBackendPolicyTests|BackendCapabilityProbeTests|HostCapabilityConfigurationTests'` | 1 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6/attempt-2/logs/focused-tests.log` | Blocked before discovery by the same default module-cache permission failure; no selected-test count. |
| `CLANG_MODULE_CACHE_PATH=$PWD/tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6/attempt-2/clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=$PWD/tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6/attempt-2/clang-module-cache /usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --disable-sandbox --skip-update --filter 'BackendCapabilityPlacementTests|DoctorBackendCapabilityTests|WorkflowHostCapabilityTests|DistributedWorkerConfigurationTests|WorkflowBackendPolicyTests|BackendCapabilityProbeTests|HostCapabilityConfigurationTests'` | 0 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6/attempt-2/logs/focused-tests-fallback.log` | Passed: 9 selected tests, 0 failures (4 existing `DistributedWorkerConfigurationTests`, 5 `WorkflowBackendPolicyTests`). The other five named required suites are absent, so this is not acceptance evidence for P1-4/P1-5. |
| `git diff --check` | 0 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6/attempt-2/logs/diff-check.log` | Passed on the moving shared tree. |
| `xargs -0 env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < tmp/work-runtime-p1/p1-capabilities/changed-swift-files.nul` | 0 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6/attempt-2/logs/touched-swiftlint.log` | Passed for the retained capability Swift files. |
| `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint --quiet --no-cache` | 0 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6/attempt-2/logs/full-swiftlint.log` | Passed with existing warnings outside this plan. |

## Attempt 7 — P1-4/P1-5 implementation (2026-09-23)

Implemented the remaining capability slice without changing the accepted plan's
completion checkbox. Core now owns neutral backend declarations, snapshots,
policy validation, reachable/called-workflow requirement projection and the
planner input shape. Adapters provide bounded injected probes for all seven
backends. Work owns deterministic local/worker placement and `work_hosts`
persistence. Existing profile and worker registration transport carry declared
and observed capabilities. CLI doctor and workflow inspect/usage expose the
projection, while `workflow validate --host/--strict-host` resolves local,
worker ID and worker-group snapshots without persisting refresh state. Group
validation requires one candidate to satisfy the whole workflow. Placement
does not waive required environment names or add-on executables.

Dispatch remains the integration owner for materializing the selected
backend/host in a runner input and adding
`WorkflowPlanningCapabilityContext.workflowVariables()` to planner variables;
the P1-4/P1-5 slice exposes the typed placement evidence and context but does
not duplicate P1-6 dispatch.

### Attempt 7 verification

| Command | Exit | Complete log | Result |
| --- | ---: | --- | --- |
| `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build` | 0 | `tmp/work-runtime-p1/p1-capabilities/manual/logs/build-final.log` | Current combined tree compiled; parent also confirmed an independent scratch build exited 0. |
| `swift test --filter 'WorkflowBackendPolicyTests|BackendCapabilityProbeTests|BackendCapabilityPlacementTests|DoctorBackendCapabilityTests|WorkflowHostCapabilityTests|HostCapabilityConfigurationTests|DistributedWorkerConfigurationTests|DistributedWorkerHTTPTests'` | 0 | `tmp/work-runtime-p1/p1-capabilities/manual/logs/focused-tests-final.log` | Passed: 33 selected tests, 0 failures. Includes probe/merge, persistence, environment/add-on fail-closed placement, local/worker/group selection, read-only versus persisted refresh, profile decoding, CLI doctor/host validation and worker transport. |
| Strict touched-file SwiftLint | 0 | `tmp/work-runtime-p1/p1-capabilities/manual/logs/touched-swiftlint-final.log` | Passed with no findings. |
| `git diff --check` | 0 | `tmp/work-runtime-p1/p1-capabilities/manual/logs/diff-check-final.log` | Passed on the shared tree. |

## Attempt 13 — Step 6 runtime reconciliation (2026-09-23)

The authoritative runtime admission remains satisfied: `p1-reservation` is in
`acceptedPlanIds`. Re-read the accepted P1 capabilities plan and §17.4 design
contract against the moving shared tree. No capability source change was needed:
the retained implementation covers neutral snapshots/policy/reachable
requirements, bounded probes, durable host snapshots, declaration merge,
placement, profile/worker transport, doctor output, and read-only host
validation. P1-6 selected-host materialization and planner-variable injection
remain downstream dispatch work and are not a P1-4/P1-5 gap. Completion
checkboxes remain untouched for serial finalization.

### Attempt 13 verification

| Command | Exit | Complete log | Result |
| --- | ---: | --- | --- |
| `swift build --scratch-path tmp/work-runtime-p1/build/p1-capabilities` | 1 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-implement/logs/build-required.log` | Blocked before compilation by the non-writable default Clang module cache. |
| `CLANG_MODULE_CACHE_PATH=… SWIFTPM_MODULECACHE_OVERRIDE=… swift build --disable-sandbox --skip-update --scratch-path tmp/work-runtime-p1/build/p1-capabilities` | 1 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-implement/logs/build-fallback.log` | Isolated scratch attempted a network fetch and DNS could not resolve `github.com`; existing `.build/checkouts/agent-gateway` was then used. |
| `CLANG_MODULE_CACHE_PATH=… SWIFTPM_MODULECACHE_OVERRIDE=… swift test --disable-sandbox --skip-update --filter 'BackendCapabilityPlacementTests|DoctorBackendCapabilityTests|WorkflowHostCapabilityTests|DistributedWorkerConfigurationTests|WorkflowBackendPolicyTests|BackendCapabilityProbeTests|HostCapabilityConfigurationTests'` | 0 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-implement/logs/focused-tests-current-build.log` | Passed current resolved tree: 35 selected tests, 0 failures. The command compiles the current build before testing. |
| Changed-Swift strict SwiftLint | 0 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-implement/logs/changed-swiftlint.log` | Passed with no findings. |
| Repository SwiftLint | 0 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-implement/logs/repository-swiftlint.log` | Passed with existing warnings outside this plan. |
| `git diff --check` | 0 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-implement/logs/diff-check.log` | Passed. |

### Step 6 final self-check (2026-09-23)

Repaired three plan-owned capability defects: unresolved add-on executable
requirements now fail resolution, finite host capacity is consumed even when a
candidate is presented as local for group validation, and doctor text includes
version, models, failures and actual freshness. Focused suites passed 35 tests
with no failures. Evidence: `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-final/`.

P1-5 remains incomplete: `workflow usage` still lacks the required
`--host`/`--strict-host` shared projection. P1-6 remains downstream-owned for
dispatch materialization and planner-variable injection.

## Attempt 11 — Step 6 placement invariant repair (2026-09-23)

Author self-check found and repaired three material P1-4d placement defects.
Disabled declarations no longer become usable merely because their source is
`declared`; a declaration must still be available. Every probe-reported
environment requirement must be present. Finite worker capacity is consumed
within one deterministic resolution, so multiple explicit assignments cannot
overcommit a worker. The new placement regressions cover each case.

The plan-owned capability contract is implemented and all named focused suites
ran with positive counts. Planner-context injection and selected
host/backend runner materialization are explicitly allocated to downstream
P1-6a/P1-6d and are not P1-4/P1-5 gaps. Do not change plan checkboxes or the
shared index before serial finalization and independent review.

### Attempt 11 verification

| Command | Exit | Complete log | Result |
| --- | ---: | --- | --- |
| `swift build --disable-sandbox --skip-update` with plan-local module caches | 0 | `tmp/work-runtime-p1/p1-capabilities/step6-attempt-2/build-fallback-final.log` | Passed current shared tree build. |
| `swift test --disable-sandbox --skip-update --filter 'BackendCapabilityPlacementTests|DoctorBackendCapabilityTests|WorkflowHostCapabilityTests|DistributedWorkerConfigurationTests|WorkflowBackendPolicyTests|BackendCapabilityProbeTests|HostCapabilityConfigurationTests'` with plan-local module caches | 0 | `tmp/work-runtime-p1/p1-capabilities/step6-attempt-2/focused-tests.log` | Passed: 33 selected tests, 0 failures. |
| Changed-Swift strict SwiftLint | 0 | `tmp/work-runtime-p1/p1-capabilities/step6-attempt-2/changed-swiftlint.log` | Passed. |
| Repository SwiftLint | 0 | `tmp/work-runtime-p1/p1-capabilities/step6-attempt-2/full-swiftlint.log` | Passed. |
| `git diff --check` | 0 | `tmp/work-runtime-p1/p1-capabilities/step6-attempt-2/diff-check.log` | Passed. |

## Post-review add-on executable requirement projection (2026-09-23)

Closed the remaining capability-owned projection gap. Core accepts a neutral
per-node `WorkflowNodeHostRequirement`; it does not import package or add-on
modules. The CLI's existing resolved-bundle/package-manifest seam translates a
referenced local-command add-on's resolved entrypoint into that neutral
executable requirement for both the root workflow and reachable callees.
Declarative, container-internal and native-bundle entrypoints are not
misclassified as host executables.

Add-on-only nodes now participate in host placement without inventing an agent
backend. Missing executables fail with an actionable diagnostic, while a fresh
host advertising the executable yields backend-neutral placement evidence.
For local strict-host validation, the resolved package root, add-on source path
and entrypoint now populate that advertisement from the installed executable's
actual execute permission. Remote snapshots remain fail-closed: their current
host-global shape cannot safely advertise workspace-specific add-ons before
P1-6 selects and materializes the target workspace.

Planner `hostCapabilityContext` injection and selected host/backend runner
materialization remain downstream P1-6a/P1-6d dependencies, not incomplete
P1-4/P1-5 capability work.

### Add-on projection verification

| Command | Exit | Complete log | Result |
| --- | ---: | --- | --- |
| `swift test --filter 'WorkflowBackendPolicyTests|BackendCapabilityPlacementTests|WorkflowHostCapabilityTests'` | 0 | `tmp/work-runtime-p1/p1-capabilities/manual/logs/addon-requirements-tests.log` | Passed: 21 selected tests, 0 failures. New cases cover neutral Core projection, backend-neutral placement and manifest-to-strict-host validation. |
| `swift test --filter 'WorkflowHostCapabilityTests|DoctorBackendCapabilityTests|WorkflowBackendPolicyTests|BackendCapabilityPlacementTests'` | 0 | `tmp/work-runtime-p1/p1-capabilities/manual/logs/addon-production-path-tests.log` | Passed: 24 selected tests, 0 failures. The added production-path regression proves an installed executable local-command add-on passes strict-host validation while the missing case remains fail-closed. |
| `swift test --filter 'WorkflowBackendPolicyTests|BackendCapabilityProbeTests|BackendCapabilityPlacementTests|DoctorBackendCapabilityTests|WorkflowHostCapabilityTests|HostCapabilityConfigurationTests|DistributedWorkerConfigurationTests|DistributedWorkerHTTPTests'` | 0 | `tmp/work-runtime-p1/p1-capabilities/manual/logs/focused-tests-final.log` | Passed: 43 selected tests, 0 failures across the complete capability-focused suite, including installed local add-on executable discovery. |
| Strict touched-file SwiftLint | 0 | `tmp/work-runtime-p1/p1-capabilities/manual/logs/touched-swiftlint-final.log` | Passed with no findings. |
| `git diff --check` | 0 | `tmp/work-runtime-p1/p1-capabilities/manual/logs/diff-check-final.log` | Passed on the shared tree. |

## Attempt 10 — Step 6 final handoff (2026-09-23)

Supersedes the out-of-order Attempt 9 placement above. The add-on executable
requirement source is now complete as recorded in the post-review section.
Planner-context injection remains mandatory downstream P1-6a/P1-6d work; it is
not incomplete P1-4/P1-5 capability scope.

## Attempt 12 — Step 6 current-tree reconciliation (2026-09-23)

Re-read the accepted capability plan and current retained implementation. The
P1-4/P1-5 surfaces are present: neutral policy and reachable requirements,
bounded probes, declaration merge and durable host snapshots, deterministic
placement, profile/worker transport, doctor output, and read-only host
validation. This attempt makes no source change and does not claim downstream
P1-6 planner-context or dispatch materialization work.

### Current verification

| Command | Exit | Complete log | Result |
| --- | ---: | --- | --- |
| `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --scratch-path tmp/work-runtime-p1/build/p1-capabilities` | 1 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-current/logs/build-rerun.log` | Blocked before compilation because the default Clang module cache is not writable. |
| `CLANG_MODULE_CACHE_PATH=… SWIFTPM_MODULECACHE_OVERRIDE=… swift build --disable-sandbox --skip-update` | 0 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-current/logs/build-fallback.log` | Passed on the current shared tree. |
| `CLANG_MODULE_CACHE_PATH=… SWIFTPM_MODULECACHE_OVERRIDE=… swift test --disable-sandbox --skip-update --filter 'BackendCapabilityPlacementTests|DoctorBackendCapabilityTests|WorkflowHostCapabilityTests|DistributedWorkerConfigurationTests|WorkflowBackendPolicyTests|BackendCapabilityProbeTests|HostCapabilityConfigurationTests'` | 0 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-current/logs/focused-tests-fallback.log` | Passed: 33 selected tests, 0 failures. |
| Strict changed-file SwiftLint | 0 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-current/logs/changed-swiftlint.log` | Passed with no findings. |
| Repository SwiftLint | 0 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-current/logs/repository-swiftlint.log` | Passed with pre-existing warnings outside this plan. |
| `git diff --check` | 0 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-current/logs/diff-check.log` | Passed. |

## Attempt 9 — Step 6 capability reconciliation (2026-09-23)

Repaired three bounded capability-path defects found by the material source
audit. Placement now rejects an explicit model against a known empty model
list; provider-backed policies reject unsupported allowed backends; and host
validation plus workflow usage construct a cycle-safe, deterministic reachable
callee map through the existing scope resolver. The host regression proves a
reachable child backend is projected rather than becoming an unknown-workflow
host diagnostic.

The assigned implementation remains incomplete for serial integration: current
workflow node/add-on references have no executable-requirement field to project
into `WorkflowBackendRequirement.addonExecutable`, and dispatch owns injection
of `WorkflowPlanningCapabilityContext` into planner variables. These are not
silently waived; P1 acceptance remains pending the dispatch/finalization join.

### Attempt 9 verification

| Command | Exit | Complete log | Result |
| --- | ---: | --- | --- |
| `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --scratch-path tmp/work-runtime-p1/build/p1-capabilities` | 1 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-attempt-1/logs/build-required.log` | Blocked before compilation: sandbox default Clang module cache is not writable. |
| `CLANG_MODULE_CACHE_PATH=$PWD/tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-attempt-1/clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=$PWD/tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-attempt-1/clang-module-cache /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --disable-sandbox --skip-update` | 0 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-attempt-1/logs/build-fallback.log` | Passed current shared tree build. |
| `CLANG_MODULE_CACHE_PATH=$PWD/tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-attempt-1/clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=$PWD/tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-attempt-1/clang-module-cache /usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --disable-sandbox --skip-update --filter 'BackendCapabilityPlacementTests|DoctorBackendCapabilityTests|WorkflowHostCapabilityTests|DistributedWorkerConfigurationTests|WorkflowBackendPolicyTests|BackendCapabilityProbeTests|HostCapabilityConfigurationTests'` | 0 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-attempt-1/logs/focused-tests-final.log` | Passed: 28 selected tests, 0 failures. |
| `git diff --check` | 0 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-attempt-1/logs/diff-check-final.log` | Passed. |
| `find Sources/RielaCore/WorkflowNodeValidation.swift Sources/RielaWork/BackendCapabilityPlacement.swift Sources/RielaCLI/WorkflowValidateInspectCommands.swift Tests/RielaCoreTests/WorkflowBackendPolicyTests.swift Tests/RielaWorkTests/BackendCapabilityPlacementTests.swift Tests/RielaCLITests/WorkflowHostCapabilityTests.swift -print0 | xargs -0 … swiftlint lint --strict --quiet --no-cache` | 0 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-attempt-1/logs/touched-swiftlint-final.log` | Passed. |
| `… swiftlint --quiet --no-cache` | 0 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-attempt-1/logs/full-swiftlint-final.log` | Passed with existing warnings outside this plan. |

## Attempt 8 — material capability-path review repair (2026-09-23)

Closed two production-path gaps found by review. Authenticated worker register
and heartbeat operations now publish the registration's capability, group,
capacity and liveness snapshot through the existing controller host into
`work_hosts`. CLI serve and the app controller use their canonical profile
runtime-records root. Host resolution reads only positive-capacity snapshots
refreshed within the controller's 30-second liveness window, so worker ID and
group validation cannot use an abandoned registration.

Reachable requirement projection now includes
`AgentNodePayload.apiKeyEnvironment`. Probe evidence separately records whether
the backend executable exists, and placement rejects a known-missing
executable or a probe credential set with no present alternative. An explicit
backend enable remains usable when evidence is unknown, but cannot override
these known failures or authored environment/add-on requirements.

P1-6a/P1-6d still own the downstream materialization of the selected
host/backend into runner input and injection of
`WorkflowPlanningCapabilityContext.workflowVariables()` into planner workflow
variables. Those steps remain mandatory for dispatch acceptance; this slice
does not duplicate them.

### Attempt 8 verification

| Command | Exit | Complete log | Result |
| --- | ---: | --- | --- |
| `swift test --filter 'WorkflowBackendPolicyTests|BackendCapabilityProbeTests|BackendCapabilityPlacementTests|DoctorBackendCapabilityTests|WorkflowHostCapabilityTests|HostCapabilityConfigurationTests|DistributedWorkerConfigurationTests|DistributedWorkerHTTPTests'` | 0 | `tmp/work-runtime-p1/p1-capabilities/manual/logs/focused-tests-final.log` | Passed: 36 selected tests, 0 failures. New coverage proves registration-to-work_hosts publication, fresh worker/group lookup with stale rejection, API-key projection, and explicit-enable failure on known probe requirements. |
| Strict touched-file SwiftLint | 0 | `tmp/work-runtime-p1/p1-capabilities/manual/logs/touched-swiftlint-final.log` | Passed with no findings. |
| `git diff --check` | 0 | `tmp/work-runtime-p1/p1-capabilities/manual/logs/diff-check-final.log` | Passed on the shared tree. |

## Attempt 14 — inspect/usage host projection completion (2026-09-23)

Closed the remaining P1-5 capability-owned gap. `workflow inspect` and its
exact `workflow usage` alias now retain `--host`/`--strict-host`, including the
same strict-without-host parser rejection as validate. Inspect injects the
read-only host resolver and shares validate's root-plus-reachable-callee
requirement projection and placement diagnostic path. Without a host it keeps
descriptive usage output; a host gap is a warning by default, while strict host
turns host gaps into errors. Existing structural errors always fail regardless
of strict-host mode without hiding the inspection summary. Projection errors
are structural and surface as errors at
`workflow.requirements`/`workflow.host` instead of collapsing to an empty
requirement array.

Coverage proves local and registered-worker/group resolution, root and called
workflow provenance, unavailable and stale backends, missing authored
environment, missing add-on executable, projection failure visibility,
strict failure, and inspect/usage option and output equivalence. The current
capability-owned scope of P1-4a through P1-4d and P1-5 is implemented. The plan
checkbox remains unchanged for serial acceptance. Selected-host runner
materialization and planner-variable injection remain explicitly owned by
P1-6a/P1-6d and are downstream dependencies, not capability incompleteness.

### Attempt 14 verification

Both behavioral commands used the current resolved checkout with repo-local
module caches, `--disable-sandbox`, and `--skip-update`; neither attempted DNS
or dependency fetch. Each complete log records `FINAL_EXIT_STATUS=0`.

| Command | Exit | Complete log | Result |
| --- | ---: | --- | --- |
| `DEVELOPER_DIR=… CLANG_MODULE_CACHE_PATH=$PWD/tmp/work-runtime-p1/module-cache/p1-capabilities-final SWIFTPM_MODULECACHE_OVERRIDE=… /usr/bin/arch -arm64 …/swift build --disable-sandbox --skip-update` | 0 | `tmp/work-runtime-p1/p1-capabilities/final-usage-inspect/build-final.log` | ARM64 current-tree build passed. |
| Same ARM64/cache environment with `swift test --disable-sandbox --skip-update --filter 'BackendCapabilityPlacementTests\|DoctorBackendCapabilityTests\|WorkflowHostCapabilityTests\|DistributedWorkerConfigurationTests\|WorkflowBackendPolicyTests\|BackendCapabilityProbeTests\|HostCapabilityConfigurationTests'` | 0 | `tmp/work-runtime-p1/p1-capabilities/final-usage-inspect/focused-tests-final.log` | Passed **41 selected tests, 0 failures**: placement 8, probes 1, worker configuration 5, doctor 2, profile configuration 2, policy/projection 10, host validate/inspect/usage 13. |
| Strict SwiftLint on the four retained inspect/usage Swift files | 0 | `tmp/work-runtime-p1/p1-capabilities/final-usage-inspect/swiftlint-final.log` | Passed with no findings; no file exceeds 1,000 lines. |
| `git diff --check` | 0 | `tmp/work-runtime-p1/p1-capabilities/final-usage-inspect/diff-check-final.log` | Passed. |

Final source hashes are in
`tmp/work-runtime-p1/p1-capabilities/final-usage-inspect/source-sha256.txt`.
Self-review found no unresolved high or medium capability issue in this bounded
change. No commit or shared-index/plan-checkbox change was made.

### Independent-review structural failure repair

The final review found one severity-routing defect in the first Attempt 14
implementation. Inspect/usage now fail on every structural `.error` regardless
of `--strict-host`; reachable-map, requirement, and add-on projection failures
are always structural errors with visible summaries. Only host availability,
authentication, freshness, verification, and placement gaps retain default
warning versus strict error behavior. The regression covers exact inspect and
usage aliases both without a host and with `--host`, and preserves the root and
reachable-callee requirement projection in the failure summary.

The final logs and hashes above were regenerated after this repair. ARM64 build
passed, the seven named suites passed **41/41**, strict touched-file SwiftLint
passed, and `git diff --check` passed; every log records
`FINAL_EXIT_STATUS=0`.

## Attempt 15 — Step 6 foreground verification (2026-09-23)

This implementation node re-read the accepted P1 capability contract and
current progress, confirmed `p1-reservation` admission from its authoritative
runtime `acceptedPlanIds`, and ran fresh foreground verification on the shared
tree. The exact scratch-path build and focused test commands were blocked
before compilation because the sandbox cannot write the default Clang module
cache. The required retry used the already resolved checkout, a plan-local
writable module cache, `--disable-sandbox`, and `--skip-update`; it did not
fetch dependencies. The fallback ARM64 build passed and the seven named suites
executed **41 tests with 0 failures**. No source behavior, checkboxes, shared
index, or another plan's progress was changed by this node.

| Command | Exit | Complete log | Result |
| --- | ---: | --- | --- |
| `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --scratch-path tmp/work-runtime-p1/build/p1-capabilities` | 1 | `tmp/work-runtime-p1/p1-capabilities/attempt-2/logs/build-scratch.log` | Blocked before compilation: default `/Users/taco/.cache/clang/ModuleCache` is not writable in the sandbox. |
| `CLANG_MODULE_CACHE_PATH=$PWD/tmp/work-runtime-p1/p1-capabilities/attempt-2/clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=$PWD/tmp/work-runtime-p1/p1-capabilities/attempt-2/clang-module-cache swift build --disable-sandbox --skip-update` | 0 | `tmp/work-runtime-p1/p1-capabilities/attempt-2/logs/build-fallback.log` | Passed current-tree ARM64 build. |
| `swift test --scratch-path tmp/work-runtime-p1/build/p1-capabilities --filter 'BackendCapabilityPlacementTests|DoctorBackendCapabilityTests|WorkflowHostCapabilityTests|DistributedWorkerConfigurationTests|WorkflowBackendPolicyTests|BackendCapabilityProbeTests|HostCapabilityConfigurationTests'` | 1 | `tmp/work-runtime-p1/p1-capabilities/attempt-2/logs/focused-test-scratch.log` | Blocked before compilation by the same default module-cache permission error. |
| `CLANG_MODULE_CACHE_PATH=$PWD/tmp/work-runtime-p1/p1-capabilities/attempt-2/clang-module-cache SWIFTPM_MODULECACHE_OVERRIDE=$PWD/tmp/work-runtime-p1/p1-capabilities/attempt-2/clang-module-cache swift test --disable-sandbox --skip-update --filter 'BackendCapabilityPlacementTests|DoctorBackendCapabilityTests|WorkflowHostCapabilityTests|DistributedWorkerConfigurationTests|WorkflowBackendPolicyTests|BackendCapabilityProbeTests|HostCapabilityConfigurationTests'` | 0 | `tmp/work-runtime-p1/p1-capabilities/attempt-2/logs/focused-test-fallback.log` | Passed: **41 selected tests, 0 failures**. |
| `git diff --check` | 0 | terminal evidence | Passed before the progress-only update; the final repeat is retained in Attempt 15 verification evidence. |

### Independent-review host-resolution classification repair

Requirement projection and host lookup now have separate failure boundaries.
Reachable-map, requirement, and add-on projection failures still propagate as
structural errors. Once requirements exist, a `HostCapabilityResolving` lookup
failure becomes a host diagnostic while retaining the derived requirements in
the inspection summary: warning/success by default, error/failure under
`--strict-host`. The regression uses a representative `unsupportedHost` error
and proves exact inspect/usage parity in both modes. Final build, 41 selected
tests, lint, diff check, and source hashes were regenerated after this repair.

Attempt 15 lint and hygiene evidence: the exact changed-file strict SwiftLint
invocation is logged at
`tmp/work-runtime-p1/p1-capabilities/attempt-2/logs/changed-swiftlint.log` and
exited 2 because this repository configuration scanned unrelated baseline
warnings as strict errors (none are in the capability file set). The required
repository SwiftLint command exited 0 with those same warnings at
`tmp/work-runtime-p1/p1-capabilities/attempt-2/logs/repository-swiftlint.log`.
The final `git diff --check` exited 0 at
`tmp/work-runtime-p1/p1-capabilities/attempt-2/logs/diff-check-final.log`.

## Attempt 16 — targeted SwiftLint contract repair (2026-09-23)

The prior strict-lint failure was an invocation defect rather than a source
finding. The repository `.swiftlint.yml` has a top-level `included` list, so
passing explicit paths to SwiftLint still scanned all of `Package.swift`,
`Sources`, and `Tests`; every reported strict error was outside the
`p1-capabilities` ownership set. A temporary config under `tmp/` retained the
same repository rules and exclusions while omitting only `included`, and the
strict lint was rerun over every existing Swift path in the accepted
`p1-capabilities` manifest item (source and tests).

| Command | Exit | Complete log | Result |
| --- | ---: | --- | --- |
| `swiftlint lint --strict --quiet --no-cache --config tmp/work-runtime-p1/p1-capabilities/attempt-3/targeted-swiftlint.yml <all existing p1-capabilities manifest Swift paths>` | 0 | `tmp/work-runtime-p1/p1-capabilities/attempt-3/logs/targeted-swiftlint.log` | Passed with no findings; the log records `FINAL_EXIT_STATUS=0`. |

Together with the current-tree ARM64 build, **41 selected tests with 0
failures**, repository SwiftLint exit 0, and `git diff --check` exit 0 already
recorded above, this closes the only Attempt 15 verification gap. No product
source or test behavior changed in this operator verification step.

## Step 6 current-tree verification — nested fanout `step6-implement` (2026-09-23)

- Workflow mode: `issue-resolution`; issue reference: `comm-000002`; fanout branch: `p1-capabilities`; Codex-agent workflow execution: `nested-v1-60cd20aeabc2ef5ce80c19f447d0e7d184ae7dde50a268ee11cb6383b3d3cead`; source branch remains `feat/remaining-impl-plans` at checkpoint `fe4da6cdda88c4bbaeafcb5dbce49bce5dd302af`.
- Dependency readiness was admitted by runtime `acceptedPlanIds` containing `p1-reservation`. Existing capability source/test work was retained and reconciled; this run made no product-source or test edits. Historical attempts remain preserved.
- Current shared-tree fingerprints: diff SHA-256 `7af53b29c8ae09b1c91b3187114e3978772f135e43d3c14d9bb96b43a57a2ab2`; status SHA-256 `0c7ad66cb4e371f5d9aac9cdf98ba3244ae9f4150fd2a8444f86aa2ee8eabf32`. (The exact values are in the adjacent fingerprint files.)
- Foreground verification passed: ARM64 build exit 0; required seven-suite ARM64 filter executed 41 tests with 0 failures; strict SwiftLint over the NUL-delimited currently changed Swift paths exit 0; `git diff --check` exit 0. Complete logs under `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-final/logs/` (`build.log`, `focused-tests.log`, `changed-swiftlint.log`, `diff-check.log`); manifest: `changed-swift-files.nul`.
- P1-4/P1-5 capability-owned implementation is present in the retained tree. Dispatch-time materialization of selected runner host/backend and planner capability variables remains P1-6 ownership and is not pulled into this plan. No shared completion checkbox or other plan progress was changed.
- The literal isolated scratch-path build and selected-test commands were also run for this node; both exited 1 before compilation/discovery because the sandbox denied `/Users/taco/.cache/clang/ModuleCache`. Complete logs: `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-final/logs/build-exact.log` and `tests-exact.log`. The already-resolved current tree was then verified with plan-local writable module-cache overrides and `--disable-sandbox --skip-update` as recorded above; this fallback passed. Final progress-tree `git diff --check` exited 0 in `diff-check.log`.

## Step 6 test-integrity repair — `comm-000145` (2026-09-23)

- Workflow mode: `issue-resolution`; issue reference: `comm-000002`; fanout plan: `p1-capabilities`; Codex-agent execution: `nested-v1-60cd20aeabc2ef5ce80c19f447d0e7d184ae7dde50a268ee11cb6383b3d3cead`. Review decision `needs_revision`; addressed the mid finding in `Sources/RielaWork/BackendCapabilityPlacement.swift` that treated Gemini's alternative credentials as simultaneous requirements.
- `BackendCapability` now carries optional `requiredEnvironmentAlternatives` metadata, preserving decoding of prior snapshots. SDK probe observations retain per-name presence for diagnostics and declare the credential alternatives as one group. Declaration merging preserves the group. Placement accepts a group when at least one observed credential is present, while still enforcing all non-alternative probe requirements and rejecting a known failed alternative group. Explicit unprobed enablement remains usable as unverified when no probe presence map exists.
- Added `WorkflowHostCapabilityTests.testGeminiPlacementAcceptsEitherProbedCredentialName`: runs the actual Gemini probe with only `GEMINI_API_KEY`, confirms `GOOGLE_API_KEY` remains absent in diagnostics, and verifies the resulting snapshot places `.officialGeminiSDK`.
- Foreground ARM64 build passed (exit 0); the required seven-suite filter passed **42 tests, 0 failures**; strict SwiftLint over the nonempty changed-Swift NUL manifest passed (exit 0); `git diff --check` passed (exit 0). Full logs: `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-review-repair-1/logs/build.log`, `focused-tests.log`, `changed-swiftlint.log`, and `diff-check.log`; manifest: `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-review-repair-1/changed-swift-files.nul`.
- Review feedback was implemented and tested; independent test-integrity re-review remains pending. P1-6 host/backend delivery and planner-variable injection remain downstream `p1-dispatch` ownership.

## Step 6 adversarial capacity repair — `comm-000149` (2026-09-23)

- Workflow mode: `issue-resolution`; issue `comm-000002`; fanout plan `p1-capabilities`; Codex-agent execution `nested-v1-60cd20aeabc2ef5ce80c19f447d0e7d184ae7dde50a268ee11cb6383b3d3cead`. Review decision `needs_revision`; repaired the mid finding that counted each reachable node against concurrent worker-job capacity.
- Placement now reserves one capacity admission per host used by the workflow. Subsequent requirements in that workflow can use the already admitted host while still needing that host to satisfy backend, model, environment, add-on, assignment, liveness, and freshness requirements. Different hosts still require their own available capacity slot.
- Replaced the two tests that treated each node as a separate capacity consumer with `BackendCapabilityPlacementTests.testSequentialWorkflowNodesShareOneWorkerCapacityAdmission`. Its two sequential node requirements pin different backends, assign both to the same capacity-1 worker, and assert complete placement on that worker for both nodes.
- Foreground ARM64 build passed (exit 0); the required seven-suite ARM64 filter passed **41 tests, 0 failures**; strict SwiftLint for the exact two changed Swift paths passed (exit 0); `git diff --check` passed (exit 0). Complete logs: `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-review-repair-2/logs/build.log`, `focused-tests.log`, `changed-swiftlint.log`, and `diff-check.log`; manifest: `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-review-repair-2/changed-swift-files.nul`.
- The capacity finding is addressed with regression coverage; independent adversarial re-review remains pending. The prior Gemini credential repair from `comm-000145` remains intact.

## Step 6 adversarial worker-snapshot repair — `comm-000153` (2026-09-23)

- Workflow mode: `issue-resolution`; issue `comm-000002`; fanout plan `p1-capabilities`; Codex-agent execution `nested-v1-60cd20aeabc2ef5ce80c19f447d0e7d184ae7dde50a268ee11cb6383b3d3cead`. Review decision `needs_revision`; repaired the mid finding that remote worker registration omitted general environment-presence and allowed local-command executable facts.
- Worker registration now transports bounded boolean maps for environment-name presence and add-on executable availability. The CLI derives facts from filtered workspace execution environments, excludes the transport token and values, and checks the actual executable file for allowed installed local-command add-ons. The HTTP router persists the facts into fresh host snapshots while retaining backend credential environment merging.
- Added `DistributedWorkerConfigurationTests.testRegistrationMetadataUsesFilteredEnvironmentAndInstalledAllowedAddon` and extended `DistributedWorkerHTTPTests.testRegistrationPublishesCapabilitiesToWorkHostStore` to assert registration → durable snapshot → placement for required custom environment and add-on facts. The latter also checks backend credential merging.
- The earlier Gemini alternative-credential repair (`comm-000145`) and capacity-1 sequential two-node repair (`comm-000149`) remain present. ARM64 build exited 0; the required seven-suite filter executed 42 tests with 0 failures; the registration-to-placement regression executed 1 test with 0 failures; strict changed-file SwiftLint and `git diff --check` exited 0.
- Complete foreground logs and exact commands are recorded under `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-review-repair-3/logs/`; changed Swift NUL manifest: `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-review-repair-3/changed-swift-files.nul`.
- The worker-snapshot finding is addressed with transport and placement regressions. Independent adversarial re-review and final combined-tree review remain pending. P1-6 runner materialization and planner-variable injection remain downstream-owned.

## Step 6 integrity repair — `comm-000156` (2026-09-23)

- Workflow mode: `issue-resolution`; issue `comm-000002`; fanout plan `p1-capabilities`; Codex-agent execution `nested-v1-60cd20aeabc2ef5ce80c19f447d0e7d184ae7dde50a268ee11cb6383b3d3cead`. Review decision `needs_revision`; addressed workspace-scope and observation-freshness findings.
- Because the placement snapshot and requirement model do not identify a worker workspace, registration now fails closed across configured workspaces: environment and allowed local-command executable facts are advertised as available only if every configured workspace can provide them. A two-workspace regression confirms facts available in only one workspace become unavailable to placement.
- Worker registration records `capabilitiesObservedAt`; subsequent claim/lease traffic may refresh host liveness `refreshedAt` but preserves that observation time. Placement requires host environment/add-on facts to have a non-future observation strictly younger than `maximumAge`; equality is stale. Older snapshots without this timestamp fail closed for these facts.
- The injected-clock registration/claim regression verifies liveness refresh does not renew capability age and a snapshot at the freshness boundary cannot place environment/add-on requirements. The seven focused suites passed 42/42; the registration/freshness HTTP regression passed 1/1; ARM64 build, strict changed-file SwiftLint and `git diff --check` exited 0.
- Complete logs and exact commands: `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-review-repair-4/logs/`; changed Swift manifest: `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-review-repair-4/changed-swift-files.nul`.
- Both findings have implementation and regression coverage. Independent test-integrity re-review remains pending; P1-6 runner materialization/planner-variable injection remain downstream-owned.

## Step 6 adversarial environment-authority repair — `comm-000160` (2026-09-23)

- Workflow mode: `issue-resolution`; issue `comm-000002`; fanout plan `p1-capabilities`; Codex-agent execution `nested-v1-60cd20aeabc2ef5ce80c19f447d0e7d184ae7dde50a268ee11cb6383b3d3cead`. Review decision `needs_revision`; repaired the mid finding where probe-reported inherited credentials could override a workspace-filtered false environment fact.
- `DistributedWorkerHTTPRouter.publishCapabilities` now preserves `registration.environment` as the host environment map. Placement also requires backend probe-reported credential names to be present in that workspace-safe map; probe facts cannot turn a key excluded by workspace configuration into an available execution environment variable.
- Extended `DistributedWorkerHTTPTests.testRegistrationPublishesCapabilitiesToWorkHostStore`: register `CODEX_TOKEN=false` while the backend probe reports it true; verify the durable snapshot retains false, allowed `CUSTOM_ENV` and add-on placement still succeeds, and Codex placement fails even without an explicit workflow environment list. Workspace aggregation coverage remains in `DistributedWorkerConfigurationTests`.
- ARM64 build exited 0; the seven focused suites passed 42/42; the registration-to-placement test passed 1/1; changed-file strict SwiftLint and `git diff --check` exited 0. Final complete logs and changed Swift manifest: `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-review-repair-5/retry-1/`.
- This repair supersedes the comm-000153 progress note's earlier probe-environment merge behavior. Independent adversarial re-review and final combined-tree review remain pending; P1-6 runner materialization/planner-variable injection remain downstream-owned.

## Step 6 adversarial freshness repair — `comm-000164` (2026-09-23)

- Workflow mode: `issue-resolution`; issue `comm-000002`; fanout plan `p1-capabilities`; Codex-agent execution `nested-v1-60cd20aeabc2ef5ce80c19f447d0e7d184ae7dde50a268ee11cb6383b3d3cead`. Review decision `needs_revision`; addressing both mid findings about backend environment snapshot freshness and future-dated probe observations.
- Placement now requires fresh host capability facts whenever a backend probe's required environment or alternative credential names are checked against `host.environment`. `BackendCapability.isFresh` now accepts only nonnegative age strictly below `maximumAge`, rejecting future timestamps and the existing expiry boundary.
- Added `BackendCapabilityPlacementTests.testBackendEnvironmentEvidenceRequiresFreshHostFacts` for explicitly enabled backend-only requirements at exact host-facts expiry, and `testFutureBackendObservationIsNotFreshOrPlaceable` for the end-to-end placement path.
- Verification passed: ARM64 `swift build --disable-sandbox --skip-update` exited 0; the required seven-suite `swift test --disable-sandbox --skip-update --filter 'BackendCapabilityPlacementTests|DoctorBackendCapabilityTests|WorkflowHostCapabilityTests|DistributedWorkerConfigurationTests|WorkflowBackendPolicyTests|BackendCapabilityProbeTests|HostCapabilityConfigurationTests'` passed 44 tests with 0 failures; strict changed-file SwiftLint used the nonempty `changed-swift-files.nul` manifest and exited 0; `git diff --check` exited 0. Complete logs: `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-review-repair-6/retry-2/logs/`. Source SHA-256: `BackendCapability.swift` `1c050d5702a117117dcc31ce44783b6ef116a9b1f5c4ce2342c7be317fea51e6`; `BackendCapabilityPlacement.swift` `ea804ddd953d21f8c9126fc7bc1a4b6f693ed88f4b32561bb07e578f011bfcf1`; `BackendCapabilityPlacementTests.swift` `c8dc796377fef88b486bdd9659169326b7a33d0a6b4e20a5788cbf2feb385fa9`.
- Previous workspace-authority repair `comm-000160` and earlier credential, capacity, worker snapshot, and workspace freshness repairs remain present. Independent re-review and final combined-tree review remain pending; P1-6 runner materialization and planner-variable injection remain downstream-owned.

## Step 6 current repair — `nested-v1-5d1e3b490c612b57a89b871256e8ec799db188ac2777b0c1a0462576ed0b0d1e` (2026-09-23)

- Workflow mode `issue-resolution`; issue `comm-000002`; plan `p1-capabilities`. Runtime-owned `acceptedPlanIds` includes the sole predecessor `p1-reservation`. The accepted §17.4 design and committed plan remain aligned. Read-only Codex-agent review found five material edge cases; one implementation owner made the edits. Per-edit snapshots, SHA-256, and intent are under `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-current/intent-{1,2,3,4}/`.
- Placement excludes worker IDs that collide with local or another worker before capacity indexing and candidate selection; explicit assignments to ambiguous IDs fail closed. The worker host resolver rejects future-dated liveness. Regressions cover both.
- Default workflow validation now resolves entry-reachable requirements without `--host`; thrown structural requirement errors fail even in non-strict mode. CLI callee discovery follows only reachable transitions, including called entry steps and cycles. Catalogued built-in and package declarative add-ons resolve as host-neutral; unknown add-ons and local-command add-ons missing an entrypoint still fail resolution. Regressions cover unresolved, built-in, declarative, and unreachable-callee cases.
- Capability-owned P1-4/P1-5 criteria are implemented in the retained tree, including earlier review repairs; 47 selected tests passed with zero failures. P1-6 dispatch-time runner materialization and planner-variable injection are downstream `p1-dispatch` ownership. No shared completion checkbox or other plan's progress was changed.

### Current foreground verification

| Command | Exit | Complete log | Result |
| --- | ---: | --- | --- |
| `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --scratch-path tmp/work-runtime-p1/build/p1-capabilities` | 1 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-current/logs/build-exact.log` | Before compilation: sandbox denied default Clang module cache. |
| `/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-capabilities --filter 'BackendCapabilityPlacementTests|DoctorBackendCapabilityTests|WorkflowHostCapabilityTests|DistributedWorkerConfigurationTests|WorkflowBackendPolicyTests|BackendCapabilityProbeTests|HostCapabilityConfigurationTests'` | 1 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-current/logs/tests-exact.log` | Before test discovery: same denied module cache. |
| `CLANG_MODULE_CACHE_PATH=$PWD/tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-current/clang-cache SWIFTPM_MODULECACHE_OVERRIDE=$PWD/tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-current/clang-cache /usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --disable-sandbox --skip-update` | 0 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-current/logs/build-final.log` | Final source compiled. |
| `CLANG_MODULE_CACHE_PATH=$PWD/tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-current/clang-cache SWIFTPM_MODULECACHE_OVERRIDE=$PWD/tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-current/clang-cache /usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --disable-sandbox --skip-update --filter 'BackendCapabilityPlacementTests|DoctorBackendCapabilityTests|WorkflowHostCapabilityTests|DistributedWorkerConfigurationTests|WorkflowBackendPolicyTests|BackendCapabilityProbeTests|HostCapabilityConfigurationTests'` | 0 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-current/logs/tests-final-candidate.log` | 47 tests, 0 failures. |
| `xargs -0 env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-current/changed-swift-files.nul` | 0 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-current/logs/changed-swiftlint.log` | Five exact edited Swift paths, no diagnostics. |
| `git diff --check` | 0 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-current/logs/diff-check.log` | Passed. |
| `CLANG_MODULE_CACHE_PATH=$PWD/tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-current/clang-cache SWIFTPM_MODULECACHE_OVERRIDE=$PWD/tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-current/clang-cache /usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --disable-sandbox --skip-update --filter 'WorkflowValidate|WorkflowInspect|WorkflowUsage'` | 1 | `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-current/logs/workflow-validation-regression.log` | Optional broader filter: 2 tests, 4 assertion failures in legacy workflow-command fixtures. One exits usage before command validation; the other inspect fixture's runtime capability diagnostics return failure. These fixtures are outside this plan's write paths and need serial reconciliation; the required seven-suite capability filter passed. |

Current changed-source SHA-256 values are in `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-current/post-sha256.txt`; the nonempty NUL manifest is beside it. The literal scratch-path commands did not establish behavioral evidence; the current-tree fallback did. Independent test-integrity and adversarial gates remain pending.


## Step 6 current repair — `nested-v1-f5c9dbc684208996afbd7d39cf88a82ab7b92afee78c48d7143f245b0f3207d9` (2026-09-23)

- Workflow mode `issue-resolution`; issue `comm-000002`; branch `feat/remaining-impl-plans`; plan `p1-capabilities`. Runtime `acceptedPlanIds` includes required `p1-reservation`. Accepted §17.4 design and committed plan remain aligned. Two read-only Codex agents audited separate Core/placement and host/probe surfaces; this Step 6 owner integrated edits. Per-edit fresh content, SHA-256, and intended hunks are in `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-current-2/intent-{1,2,3,4,5,6,7}/`.
- Host validation now evaluates a complete group/worker topology and honors authored step targets; reachable discovery includes resume and fanout join paths. Core requirement projection retains package and environment-only names. Local host diagnostics select the active RielaApp profile, and stored worker snapshots open strictly read-only. New group, active-profile, and environment-only regressions passed. A proposed capacity search was removed after its test showed the accepted one-admission-per-host behavior already allowed the workflow; the placement source and test hashes returned exactly to their pre-turn values.
- Required exact scratch-path build and focused test commands exited 1 before compilation/discovery because the sandbox denied the default Clang module cache. Current-tree fallback with plan-local writable module cache, `--disable-sandbox --skip-update` passed: final ARM64 build exit 0; required seven-suite filter 50 tests, 0 failures; strict changed-file SwiftLint over six NUL-delimited Swift paths exit 0; `git diff --check` exit 0. Complete logs are under `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-current-2/logs/`; exact command strings, final statuses, and source hashes are in adjacent `verification-evidence.json`.
- An optional broader `WorkflowValidate|WorkflowInspect|WorkflowUsage` filter still fails two legacy workflow-command fixtures (4 assertions) before host assessment. Reproduced one inspect failure as `CLIUsageError: mutable registry file is linked, missing, or inaccessible` during bundle resolution; this is shared-tree sandbox/registry behavior outside this plan's write paths and belongs to serial reconciliation. No success is claimed for that optional filter. P1-6 runner materialization and planner-variable injection remain downstream `p1-dispatch` ownership. Independent test-integrity/adversarial and combined-tree reviews remain pending; no shared completion checkbox was changed.

- Final focused assertions also verify that an explicit assignment to an incapable group member fails strict validation, and that a read-only registered-worker host lookup preserves main database bytes and sidecar presence. The exact full-byte comparison of an existing SQLite `-shm` file changed during a strict read-only WAL connection; that stronger dry-run guarantee is owned by P1-6/serial reconciliation, not this capability-validation seam. The final seven-suite retry passed 50/50 (`logs/focused-tests-final-4.log`); six-file strict SwiftLint passed (`logs/changed-swiftlint-final-2.log`). Evidence JSON supersedes earlier candidate log names.

## Step 6 adversarial freshness repair — `comm-000152` (2026-09-23)

- Workflow mode `issue-resolution`; issue `comm-000002`; plan `p1-capabilities`; Codex execution `nested-v1-f5c9dbc684208996afbd7d39cf88a82ab7b92afee78c48d7143f245b0f3207d9`. Runtime accepted predecessor `p1-reservation`; accepted design §17.4 and P1-4d own fresh worker placement. Sol review decision `needs_revision` identified a mid finding: startup-only worker observations expired after 300 seconds even as the worker stayed live. Terra Step 6 repair is ready for independent re-review; no review acceptance is claimed.
- The worker client now reprobes at a bounded 240-second interval on claims and lease renewals, attaches names/presence-only facts and their original observation time, and retains that time on probe failure. The authenticated router validates the unchanged worker registration and lease before publishing refreshed facts. It does not re-register or replace an active incarnation. Durable host upsert preserves newer capability facts when an older registration event arrives, while liveness uses the latest caller-supplied refreshed time. This covers saturated workers whose active lanes renew but do not claim.
- `DistributedWorkerConfigurationTests.testLongLivedWorkerRefreshesObservedBackendWithoutLosingLease` exercises the client request preparation, authenticated router, controller, durable snapshot, and pinned placement at 301 seconds with a capacity-1 active lease. It asserts stale placement failure before renewal, fresh placement and same lease/incarnation after renewal, and no re-dating after a failed probe. The required seven-suite filter executed 51 tests, 0 failures.
- Completion criteria for this assigned P1-4/P1-5 seam: bounded fresh observation, strict capability placement, worker lease preservation, selected behavioral tests, build, changed-file strict SwiftLint, and diff hygiene are satisfied in this Step 6 tree. P1-6 dispatch materialization and dry-run WAL equivalence remain downstream ownership. Independent test-integrity/adversarial and final combined-tree reviews remain pending.
- Exact required scratch-path build and test commands exited 1 before compilation/test discovery because the sandbox denies the default Clang module cache. Complete logs: `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-review-repair-comm-000152/logs/build-exact.log` and `tests-exact.log`. Current-tree fallback with plan-local writable module cache and `--disable-sandbox --skip-update` passed: `build-final-2.log` exit 0; `tests-final-3.log` exit 0, 51 tests/0 failures. Strict SwiftLint on the six exact paths in `changed-swift-files.nul` passed in `swiftlint-final-3.log`; `git diff --check` passed in `diff-check-final.log`. All paths are under the same attempt directory. Final source hashes: `source-sha256-final.txt`; per-edit fresh snapshots and intentions: `intent-{1,2,3,4,5,6,7,8,9,10,11}/`.

## Step 6 test-integrity repair — `comm-000155` (2026-09-23)

- Workflow mode `issue-resolution`; issue `comm-000002`; plan `p1-capabilities`; Codex execution `nested-v1-f5c9dbc684208996afbd7d39cf88a82ab7b92afee78c48d7143f245b0f3207d9`. Sol test-integrity decision `needs_revision` found that the 301-second active-lease regression checked status and incarnation but did not assert original lease-token continuity. The accepted P1-4d active-work guarantee makes that assertion material.
- Added `activeJob?.lease?.token == leaseToken` to the existing regression. The original token is captured before simulated time advances and checked after capability refresh through authenticated renewal. No production behavior or other test assertions changed. The assigned completion criterion for preserving active work now has direct token evidence; independent re-review remains pending.
- Exact scratch-path build and seven-suite test commands again exited 1 before compilation/discovery because the default Clang module cache is sandbox-denied. Current-tree fallback with plan-local writable module cache, `--disable-sandbox --skip-update` passed: build exit 0; seven-suite filter **51 tests, 0 failures**; selected-file strict SwiftLint exit 0. Complete foreground logs are in `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-test-integrity-repair-comm-000155/logs/` (`build-exact.log`, `tests-exact.log`, `build-fallback.log`, `tests-fallback.log`, `swiftlint.log`). Source hashes are in adjacent `source-sha256-final.txt`; pre-edit content and intent are in `intent-1/` and `intent-2/`.

## Step 6 adversarial clock-skew repair — `comm-000159` (2026-09-23)

- Workflow mode `issue-resolution`; issue `comm-000002`; plan `p1-capabilities`; Codex execution `nested-v1-f5c9dbc684208996afbd7d39cf88a82ab7b92afee78c48d7143f245b0f3207d9`. Sol adversarial decision `needs_revision` identified a mid finding: a worker clock one second ahead made claims and renewals return 403. This Step 6 repair is ready for independent re-review; no acceptance is claimed.
- The authenticated router shifts a bounded future observation (up to 30 seconds) and its backend observation times onto controller time before durable publication. It also bounds the initial registration snapshot's future backend timestamps. A larger future lead does not interrupt a valid claim or lease renewal, but its refresh is ignored. Old failed-probe timestamps remain old; no stale success is re-dated. Worker registration, incarnation, and lease tokens are unchanged.
- `DistributedWorkerConfigurationTests.testLongLivedWorkerRefreshesObservedBackendWithoutLosingLease` now uses separate worker/controller clocks one second apart. It verifies normalized claim and renewal, stale placement after 301 seconds, failed reprobe renewal still stale, fresh renewal restores placement, and status/incarnation/original token survive. A 31-second future report leaves the active lease usable without promoting its capability observation. Assigned P1-4d freshness and active-work completion criteria have direct behavioral evidence.
- Exact scratch-path build/test attempts exited 1 before compilation/discovery on denied default Clang module cache. Current-tree fallback with plan-local writable module cache and `--disable-sandbox --skip-update` passed: build exit 0; required seven-suite filter **51 tests, 0 failures**; exact changed-file strict SwiftLint exit 0; `git diff --check` exit 0. Complete foreground logs: `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-skew-repair-comm-000159/logs/`; source hashes: adjacent `source-sha256-final.txt`; per-edit intent and pre-edit content: `intent-{1,2,3,4,5,6}/`. Independent branch review and final combined-tree review remain pending.

## Step 6 reachable add-on validation repair — `nested-v1-7ffb798d806f8227f0ceae598e92a721ccb4a838dda2e80a5574b3464f8cb152` (2026-09-23)

- Workflow mode `issue-resolution`; issue `comm-000002`; plan `p1-capabilities`; accepted predecessor `p1-reservation`. The committed P1-4/P1-5 plan remains aligned with design §17.4. Three read-only Codex agents investigated plan, code, and evidence; the Step 6 owner made the only edits. No newer external review feedback followed the repaired `comm-000159` mid finding; independent re-review remains pending.
- Self-check found that local add-on availability scanned unreachable registry nodes. An absent unreachable add-on sharing a reachable add-on's executable name could cause false strict-host failure. `reachableWorkflowMaps` now gathers local executable availability while visiting reachable steps, including called workflows. The existing installed-executable test includes an unreachable same-entrypoint add-on whose executable is absent. This is a P1-5 host-validation correction; dispatch materialization and planner-variable injection remain downstream `p1-dispatch` ownership.
- P1-4/P1-5 implementation and required behavior are complete for this Step 6 handoff. Fresh fallback build passed, seven required suites executed **51 tests, 0 failures**, selected-file strict SwiftLint passed for two edited Swift paths, and `git diff --check` passed. The exact scratch-path build and test commands each exited 1 before compilation/discovery because the default Clang module cache is sandbox-denied; the accepted current-tree fallback used writable plan-local `CLANG_MODULE_CACHE_PATH` and `SWIFTPM_MODULECACHE_OVERRIDE` with `--disable-sandbox --skip-update`. No independent review acceptance or final combined-tree acceptance is claimed.
- Complete foreground logs and exit-status sidecars: `tmp/work-runtime-p1-dag-20260922-8286b20f/p1-capabilities/step6-20260923-7ffb798d/logs/` (`build-exact-final.log` exit 1, `tests-exact-final.log` exit 1, `build-final.log` exit 0, `tests-fallback.log` exit 0, `swiftlint.log` exit 0, `diff-check.log` exit 0). Exact commands and counts: adjacent `verification-evidence.json`. Changed-file NUL manifest: `changed-swift-files.nul`; source hashes: `source-sha256-final.txt`; fresh-read, pre-edit snapshots and intended hunks: `intent-{1,2,3}/`.
