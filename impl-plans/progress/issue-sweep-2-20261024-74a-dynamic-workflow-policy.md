# ISW2-74a implementation progress

**Plan:** `ISW2-74a-dynamic-workflow-policy`  
**Issue:** `tacogips/riela#74`  
**Workflow mode:** full issue-resolution; Step 6 implementation  
**Status:** implementation complete; pending downstream review

## Implemented contract

- Added the exact public types `WorkflowDynamicWorkflowTransition`, `WorkflowDynamicWorkflowOnFailure`, `WorkflowDynamicWorkflowLimits`, `WorkflowDynamicWorkflowAllow`, `ResolvedDynamicWorkflowBounds`, and `DynamicWorkflowPolicy` with `ceilings`, `authoredDiagnostics`, `resolve`, and `check`.
- Defaults: 4 iterations, 65,536 definition bytes, 8 nodes, 16 steps, 32 child steps; node types `[agent]`, parent-derived backends/models, and no add-ons. Ceilings: 16 iterations, 262,144 bytes, 32 nodes, 64 steps, 256 child steps.
- The deterministic, total checker reads raw envelope JSON and enforces shape, canonical sorted-key UTF-8 size, count limits, key allowlists, no workflow calls or parent ID reuse, payload presence, and node type/add-on/backend/model grants. All messages use the `dynamic workflow policy:` prefix.
- Add-on names in authored `allow.addons` receive lowercase namespaced `owner/addon` shape validation because RielaCore has no reachable add-on registry; generated node add-ons must still be explicitly allowed.
- Focused tests cover clean definitions, denied keys, workflow-call rejection, missing payloads, allowlists, bounds, malformed shapes, authored boundaries including zero iterations/unknown backend/malformed add-on, defaults, and deterministic diagnostics.

## Completion criteria

- [x] Public names and initializers match the 74a Contract block.
- [x] Defaults and ceilings match the assigned values.
- [x] Raw-envelope policy enforcement is deterministic and remains independent of runner/store wiring.
- [x] All 9 `DynamicWorkflowPolicyTests` pass.
- [x] `swift build` exits 0.
- [x] Strict SwiftLint exits 0 for the exact changed Swift file set.

## Final verification

All logs are complete and plan-local under `tmp/issue-sweep-2-20261024/isw2-74a/`. Every record has integer `exitStatus`, `testsRun`, and `failureCount`.

| Command | exitStatus | testsRun | failureCount | Log |
|---|---:|---:|---:|---|
| `arch -arm64 /bin/zsh -lc 'swift build > tmp/issue-sweep-2-20261024/isw2-74a/build-final.log 2>&1; result=$?; echo exitStatus=$result >> tmp/issue-sweep-2-20261024/isw2-74a/build-final.log; exit $result'` | 0 | 0 | 0 | `tmp/issue-sweep-2-20261024/isw2-74a/build-final.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter DynamicWorkflowPolicyTests > tmp/issue-sweep-2-20261024/isw2-74a/focused-final.log 2>&1; result=$?; echo exitStatus=$result >> tmp/issue-sweep-2-20261024/isw2-74a/focused-final.log; exit $result'` | 0 | 9 | 0 | `tmp/issue-sweep-2-20261024/isw2-74a/focused-final.log` |
| `arch -arm64 /bin/zsh -lc 'xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/issue-sweep-2-20261024/isw2-74a/changed-swift-files.nul > tmp/issue-sweep-2-20261024/isw2-74a/lint.log 2>&1; result=$?; echo exitStatus=$result >> tmp/issue-sweep-2-20261024/isw2-74a/lint.log; exit $result'` | 0 | 0 | 0 | `tmp/issue-sweep-2-20261024/isw2-74a/lint.log` |

## Prior attempts

The preceding progress record reported an earlier focused attempt with `exitStatus=1`, `testsRun=0`, and `failureCount=0`; compilation stopped on sibling-owned `Tests/RielaCLITests/SessionRecoveryHydrationScopeTests.swift`. Its referenced historical log directory is absent from the current tree, so that attempt is retained only as a reported superseded result, not as current verification evidence. The current-source focused run above passes. The sibling file is outside this plan's write paths and was left untouched.

## Edit evidence

- Per-edit intentions and source snapshots are under `tmp/issue-sweep-2-20261024/isw2-74a/snapshots/`.
- Final hashes: `Sources/RielaCore/DynamicWorkflowPolicy.swift` = `d45428348c3cb749a837b69083c146bb58d58285a7e82a1748abf14e1f423e07`; `Tests/RielaCoreTests/DynamicWorkflowPolicyTests.swift` = `8699e1ca43648c6521daa3dd299c10e21e0ade17e00021b880ccc241cc5e0c39`.
