# Issue 94 minimal inheritance implementation progress

Status: `accepted`  
workflowMode: `issue-resolution`  
issueReference: https://github.com/tacogips/riela/issues/94  
checkpointCommit: `f166560eb6e38af45dee9d9dd6622e0f2546838d`

## Implemented

- T1: sparse `extends` declaration parsing precedes complete authored decoding; unsupported overlays, malformed fields, unsafe IDs, empty replacement sources, and invalid patch shapes produce field-oriented diagnostics.
- T1: deterministic replacements run by descending UTF-8 source length then ascending bytes; resource path fields are preserved; derived identity is restored; convenience patches apply only to inherited file-backed agent nodes; explicit patches override them through the existing patch resolver.
- T2: the shared bundle loader accepts bounded inheritance context; the CLI resolver discovers user-scope authored or installed-package bases by workflow ID and recursively reuses existing candidate validation, activation, containment, package, and coordinated-read behavior.
- T2: workflow-ID/canonical-path ancestry rejects cycles; the returned bundle retains derived directory, scope, package manifest, and package directory while using the hydrated base resources.
- T3: focused Core and CLI regressions cover declaration failure, deterministic precedence, collisions, model freeze, sparse user resolution, missing base, direct and indirect cycles, repeated independent base loads, and ordinary workflow behavior.
- T3: an isolated user-scope package regression exercises the real CLI validate, inspect, and mock-run paths, verifies derived identity and inherited execution, applies a caller patch during validation, and proves installed package bytes are unchanged.
- T3: the installed Claude package validated, inspected, and completed the planning-only mock with derived identity, inherited 23-step graph, 15 scenario-backed executions, terminal `workflow-output`, accepted design-plan-only output, and mock commit `fedcba9876543210fedcba9876543210fedcba98`. Installed aggregate hash, Git HEAD, and tracked diff hash were unchanged.

## Changed paths

- `Sources/RielaCore/WorkflowInheritanceDeclaration.swift`
- `Sources/RielaCore/WorkflowInheritanceTransformation.swift`
- `Sources/RielaWorkflowRegistry/WorkflowRegistryBundleLoader.swift`
- `Sources/RielaWorkflowRegistry/WorkflowRegistryBundleLoader+Inheritance.swift`
- `Sources/RielaCLI/WorkflowResolution.swift`
- `Tests/RielaCoreTests/WorkflowInheritanceValidationTests.swift`
- `Tests/RielaCLITests/WorkflowInheritanceResolutionTests.swift`
- `impl-plans/progress/issue-94-inheritance-minimal.md`

## Verification evidence

- `tmp/issue-94-implementation/verification/03-swift-build.log`: `swift build`, exit 0.
- `tmp/issue-94-implementation/verification/06-focused-tests.log`: focused inheritance suites, 5 tests, exit 0.
- `tmp/issue-94-implementation/verification/07-installed-validate-inspect.log`: installed validate and inspect, both exit 0.
- `tmp/issue-94-implementation/verification/08-installed-run.log`: installed planning-only mock, exit 0; state and installed bytes unchanged.
- `tmp/issue-94-implementation/verification/09-ordinary-control.log`: ordinary validate/inspect/run control, 1 test, exit 0.
- `tmp/issue-94-implementation/verification/10-lint-diff.log`: SwiftLint exit 0 with repository pre-existing warnings plus one subsequently corrected new line-length warning; `git diff --check` exit 0.
- `tmp/issue-94-final-verification/focused-tests.log`: final Core and CLI inheritance suites, 8 tests, exit 0, including the isolated installed-package validate/inspect/run regression.
- `tmp/issue-94-final-verification/baseline-package-app-test.log`: checkpoint `f166560e` independently reproduces the broad-suite package-app failure with the same three assertions and unexpected existing ChatGPT app candidate; this failure predates the implementation.
- Step 7 review identified a provider/backend validation gap after inheritance transformation. The serial repair now combines provider diagnostics with graph diagnostics, retains warnings, rejects errors, and adds an invalid `providerProxy`/backend regression.
- A second Step 7 review identified a base identity collision: a directory name could mask a matching installed package while declaring a different `workflowId`. Direct discovery and the resolved base now require exact identity; focused coverage exercises both rejection and package fallback. `tmp/issue-94-final-verification/post-review-repair.log` records a passing build, 10 focused tests, `git diff --check`, and final exit status 0.
- Direct Riela review session `issue-94-final-review-session-1` accepted the combined tree with zero high/mid findings. Its only low finding, actionable missing-base CLI guidance, was repaired with focused assertions. The stable tree subsequently passed `swift build`, all 10 focused tests, targeted SwiftLint with no issue, and `git diff --check` on merged main `c819db8b`.
- Historical corrective evidence: `01-swift-build.log`, `02-swift-build.log`, `04-focused-tests.log`, and `05-focused-tests.log` are retained failed attempts with terminal status or explicit wrapper failure detail.

## Serial gate disposition

- Broad `swift test --filter 'RielaCoreTests|RielaCLITests'` executed 1,655 tests; its only failures were the three assertions in `testPackageAppEnvironmentEnablementRunAndMonitoringScenario`, reproduced unchanged from checkpoint `f166560e` and therefore classified as unrelated baseline state.
- Independent test-integrity and implementation findings were reconciled; direct Riela combined-tree review accepted with zero unresolved high/mid findings.
- README, accepted design, and the workflow skill remain accurate for this internal loader correction; no usage documentation change is required.
- Another authorized workflow advanced main from checkpoint `f166560e` to merge commit `c819db8b` during final verification. Issue-94 changes remained intact as working-tree edits and were rebuilt and retested against that merged tree; no unrelated edits were overwritten.
- Release, signing, notarization, publication, final commit, and push remain outside this implementation record and are handled by the parent release goal.

## Review state

Implementation author self-check and independent Riela review found no unresolved high- or mid-severity issue in the assigned hunks. Status is `accepted` for release preparation.

## Immutable intent evidence

- `tmp/issue-94-implementation/issue-94-inheritance-minimal/intents/001-t1-core.txt`
- `tmp/issue-94-implementation/issue-94-inheritance-minimal/intents/002-t1-transform-key-fix.txt`
- `tmp/issue-94-implementation/issue-94-inheritance-minimal/intents/003-t2-loader-resolver.txt`
- `tmp/issue-94-implementation/issue-94-inheritance-minimal/intents/004-t2-build-import.txt`
- `tmp/issue-94-implementation/issue-94-inheritance-minimal/intents/005-t2-forward-loader-context.txt`
- `tmp/issue-94-implementation/issue-94-inheritance-minimal/intents/006-t3-focused-tests.txt`
- `tmp/issue-94-implementation/issue-94-inheritance-minimal/intents/007-t3-test-type-fix.txt`
- `tmp/issue-94-implementation/issue-94-inheritance-minimal/intents/008-t3-fixture-fixes.txt`
- `tmp/issue-94-implementation/issue-94-inheritance-minimal/intents/009-t3-lint-and-progress.txt`
- `tmp/issue-94-implementation/issue-94-inheritance-minimal/intents/010-t3-lint-wrap-retry.txt`
- `tmp/issue-94-implementation/issue-94-inheritance-minimal/intents/011-step7-provider-validation-repair.txt`
- `tmp/issue-94-implementation/issue-94-inheritance-minimal/intents/012-step7-base-identity-repair.txt`
- `tmp/issue-94-implementation/issue-94-inheritance-minimal/intents/013-final-missing-base-diagnostic.txt`

## Final implementation hashes

- `613b438c53efe739e43b995772622489f27701f5352c596953e841d43341f3e3`  `Sources/RielaCore/WorkflowInheritanceDeclaration.swift`
- `57f0b06295ed453a9d3995bbf01dfed1a35a4fe61f45d8f079df8451171bc03b`  `Sources/RielaCore/WorkflowInheritanceTransformation.swift`
- `ec410c40a29e8c23faf32c7f3430ee73a4be90d1c36882b2f9b15e03d27622d4`  `Sources/RielaWorkflowRegistry/WorkflowRegistryBundleLoader.swift`
- `eec1f2f8f8a71d0cf5d4ed890349999ebfcd7752b4c7325cf3d9a31ae122dffc`  `Sources/RielaWorkflowRegistry/WorkflowRegistryBundleLoader+Inheritance.swift`
- `765471aa41561211aedaf5b0bc4c672f440575350cecec331a2ba027c6ff7d30`  `Sources/RielaCLI/WorkflowResolution.swift`
- `bcc60e0c533cd648186c82d3f92eefe45a90049373e445fa9eed4d4987eca854`  `Tests/RielaCoreTests/WorkflowInheritanceValidationTests.swift`
- `35305e9e54fe92cc4a85bbaa9148c570cd2f8a59680c97c5de68de240025cf74`  `Tests/RielaCLITests/WorkflowInheritanceResolutionTests.swift`

The progress record is excluded from its own hash list because embedding its digest would recursively change that digest.
