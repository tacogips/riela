# Issue 94 — minimal installed inheritance repair

Status: completed. Date: 2026-09-21.
workflowMode: `issue-resolution`; issueReference: https://github.com/tacogips/riela/issues/94.
Authority: `design-docs/specs/design-workflow-json.md#swift-inheritance-resolution-issue-94`, SHA-256 `339ca2cf1ae8737142288b3e99db9bf2cbbf609e0d243e9652f88314f886890c`.
Step 3 decision: `accepted`, incoming `comm-001784`, reviewed communication `comm-001783`, workflow `codex-design-and-implement-review-loop-session-142`. Findings/feedback: none. No Step 5 feedback supplied. codexAgentReferences: `[]`; no intentional reference-behavior divergence.

## Sole dispatch assignment

```json
{
  "planId": "issue-94-inheritance-minimal",
  "planPath": "impl-plans/active/issue-94-inheritance-minimal.md",
  "dependsOn": [],
  "writePaths": [
    "Sources/RielaCore/WorkflowInheritanceDeclaration.swift",
    "Sources/RielaCore/WorkflowInheritanceTransformation.swift",
    "Sources/RielaWorkflowRegistry/WorkflowRegistryBundleLoader.swift",
    "Sources/RielaWorkflowRegistry/WorkflowRegistryBundleLoader+Inheritance.swift",
    "Sources/RielaCLI/WorkflowResolution.swift",
    "Tests/RielaCoreTests/WorkflowInheritanceValidationTests.swift",
    "Tests/RielaCLITests/WorkflowInheritanceResolutionTests.swift",
    "impl-plans/progress/issue-94-inheritance-minimal.md"
  ],
  "sharedPaths": [
    "Sources/RielaCore/WorkflowRawValidation.swift",
    "Sources/RielaCore/WorkflowInstanceModel.swift",
    "Sources/RielaCore/WorkflowInstanceResolver.swift",
    "Sources/RielaWorkflowRegistry/WorkflowRegistryCatalog.swift",
    "Sources/RielaWorkflowRegistry/WorkflowRegistryBundleLoader+SharedNodeRefs.swift",
    "Sources/RielaCLI/WorkflowValidateInspectCommands.swift",
    "Sources/RielaCLI/WorkflowRunCommand.swift",
    "Sources/RielaCLI/WorkflowCalleeResolution.swift",
    "Sources/RielaCLI/ProductionNodeAdapter.swift",
    "Tests/RielaCLITests/WorkflowCommandTestHelpers.swift",
    "README.md",
    "design-docs/specs/design-workflow-json.md",
    ".codex/skills/riela-impl-workflow/SKILL.md",
    "impl-plans/active/issue-94-inheritance-minimal.md",
    "impl-plans/README.md",
    "impl-plans/PROGRESS.json",
    "impl-plans/progress/plans-index.json",
    "Package.swift",
    "Package.resolved"
  ]
}
```

One owner, one native implementation item, no independent parallel tasks. New helper files above are bounded implementation locations, not required public abstractions; omit unused helpers. `sharedPaths` are read-only during implementation. A focused failing blocker test must justify any extra consumer/catalog/callee edit; record the failure and exact added ownership before serial repair. Do not preauthorize a resolver redesign. The coordinator derives `trackedPaths` from actual writePaths and records any reviewed expansion before dispatch.

Superseded history, preserved byte-for-byte and **never dispatched**: `impl-plans/active/issue-94-inheritance-declaration.md`, `impl-plans/active/issue-94-inheritance-registry.md`, `impl-plans/active/issue-94-inheritance-cli.md`, `impl-plans/active/issue-94-inheritance-regression.md`, and `impl-plans/active/issue-94-inheritance-finalization.md`. Their combined baseline is 238 lines / 37,001 bytes. Only this replacement belongs in implementationItems; do not discover assignments by globbing historical active files. Serial finalization may archive those drafts as superseded, retaining their bytes and status distinction from completed implementation.

## Tasks, dependency waves, and acceptance

| Task | Depends on | Deliverable and acceptance |
| --- | --- | --- |
| T1 | none | Sparse declaration and transformation helper with focused core tests; publish callable contract in own progress log. |
| T2 | T1 | Shared loader and existing user resolver integration; base resources loaded before derived validation. |
| T3 | T2 | Installed sparse CLI regression, safety cases, ordinary control, and current installed-package smoke. |
| T4 | T3 | Serial reconciliation, independent reviews, broad verification, documentation/progress, completion and Git handoff. |

- [x] **T1 — declaration and precedence.** Recognize `extends` before ordinary complete decoding. Accept only safe derived `workflowId`, optional non-empty description, object `extends` with safe base ID, optional replacements/convenience/explicit patches. Reject null, malformed types, unknown inheritance keys, unsupported overlays and empty replacement sources; permit empty replacement values. Report `workflow.extends` field paths. Reuse existing patch field/value, unknown-node and model-freeze checks; keep ordinary validation strict and Core free of CLI/filesystem discovery. Transform authored string values including hydrated prompts and workflow targets, never JSON field names or physical resource paths. Order replacements by descending UTF-8 byte length, then ascending UTF-8 bytes, sequentially; align transformed node/payload IDs and reject collisions. Restore derived identity/optional description. Convenience patches target originally file-backed agent nodes only, excluding nodeRef/add-on/command/container; preserve only necessary original-node eligibility across levels. Merge explicit patches by transformed node ID and field over convenience patches. One core suite covers overlapping specific/generic and equal-length replacements, inherited omitted fields, exclusions, collisions, invalid patches/model freeze and malformed declarations; avoid duplicate exhaustive suites.
- [x] **T2 — load and resolve.** Extend `WorkflowRegistryBundleLoader.loadBundle` with only the needed base-resolution capability and active canonical-path/workflow-ID ancestry. `FileSystemWorkflowBundleResolver` supplies existing user-scope installed lookup, using metadata-only inventory if ID lookup requires it (test package name differs from authored workflow ID). Retain selection, activation, containment, package validation and coordinated reads; no project fallback, new ambiguity policy or full-catalog recursive validation. Detect cycles before recursion/lock reentry and pop completed ancestors. Recursively load/hydrate/validate the selected base, transform in memory, validate each complete derived graph/payload set, return existing `ResolvedWorkflowBundle` with derived source/scope/package identity. Keep base prompt and command/container resource paths usable without reading synthesized replacement filenames or rewriting either source. Selected invalid base retains its original file/field diagnostic; missing-base errors include derived/base IDs, searched user roots and install/scope guidance; cycles report the chain. Preserve ordinary loads. Keep caller instance then run patches applied exactly once after inheritance, validated and excluded from base/callee loading through existing consumer ordering.
- [x] **T3 — focused CLI evidence.** Add `WorkflowInheritanceResolutionTests` with isolated user home injection via existing `CLIRuntimeEnvironment`, valid installed package fixtures under root `tmp/issue-94-implementation/fixtures/<unique-id>/`, and no mutation of actual installs or global HOME. One sparse derived workflow inherits a one-step agent graph, file-backed prompt, convenience backend/model and explicit override; assert validate/inspect/run agree on derived ID, inherited steps, effective payloads, package identity and exact mock output. Add caller instance/run precedence assertion with base unchanged. Cover missing/invalid base, direct/indirect cycles, independent repeated base load and final-invalid transformation in focused cases; core cases own schema/transform details. Assert before/after source hashes; use existing ordinary CLI test as control. If an installed callee fails, first retain a focused failing regression, then make only the proven repair; any changed live callee path needs injected-adapter real dispatch verification, since CLI mock dispatch is simulated. Run the actual installed Claude package smoke below; inspect Cursor's explicit `step6-implement` patch using the same resolver test path if the shared precedence case does not represent it.
- [x] **T4 — serial completion.** After native worker/review termination, compare accepted post-hashes and immutable intents to the combined tree, repair drift serially, obtain independent combined-tree review and rerun affected gates. Require implementation, test-integrity and adversarial reviews with zero unresolved high/mid findings. Run the broad commands below; review README, accepted design and `.codex/skills/riela-impl-workflow/SKILL.md`, update only inaccurate affected usage/status documentation and log no-change decisions. Serial owner alone updates shared indexes/plan checkboxes, generates any justified lockfile, handles broad formatting and archives plans globally. No dependency change, unrelated large-file split or broad formatting is planned. If workflow/prompt/script/skill assets actually change, refresh owning `riela-package.json` digests and validate that package. Final workflow commit/push gates must record exact allowlist and matching hashes; no 0.1.39 release, signing or publication.

## Edit, progress, and checkpoint contract

Before native fanout, Step 5 must accept this plan, then the serial workflow checkpoint commits the accepted design, this plan and any coordinator dispatch record; record commit/hash/allowlist evidence. Do not commit unreviewed plans in Step 4. Preserve unrelated user changes. No worktrees, private implementation branches or concurrent Git operations.

For **each edit**, freshly read the current file, record SHA-256 pre-hash (or absent) and a uniquely named immutable intent snapshot under `tmp/issue-94-implementation/issue-94-inheritance-minimal/intents/`, with task, dependency hashes, semantic change and tests. Recheck immediately before applying; on drift reread and create a new intent, never restore stale whole-file bytes. Record post-hash/diff/semantic assertions and recheck at handoff. Retain evidence references/digests in the worker's own `impl-plans/progress/issue-94-inheritance-minimal.md`; no edits to other workers' logs. That durable log records task state, checkpoint, paths, hashes, complete command logs, terminal exits, nonzero selected-test counts, findings and review decisions. Use `in_progress`, then `implemented_pending_review`, then `accepted` only with review evidence. The native join checks retained behavior as well as hashes, followed by serial repair and independent combined review even with one assignment. Failed work remains pending.

## Verification commands and exact smoke

Future implementation gates, not Step 4 results. Run from `/Users/taco/gits/tacogips/riela`, foreground only; serialize shared Swift build-directory use. Capture full stdout/stderr, command, start/end and final exit in `tmp/issue-94-implementation/verification/`; retain/poll any yielded process handle until exit. Never pass an unfinished/truncated log. Use `.codex/skills/swift-coding-agent/SKILL.md`; build is the Swift typecheck gate. No UI/web changes mean no browser/typecheck suite is needed. Scratch fixtures/wrappers are removed after evidence capture; review logs remain through handoff.

```sh
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'WorkflowInheritanceValidationTests|WorkflowInheritanceResolutionTests'
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter WorkflowCommandTests.testValidateInspectAndDeterministicRunWorkerFixture
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'RielaCoreTests|RielaCLITests'
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint --quiet --no-cache
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --show-bin-path
git diff --check
```

Record the build-reported executable path and SHA-256; verify `.build/debug/riela` resolves to that executable, otherwise substitute its absolute path in the following commands and record them. For the isolated CLI test, require `valid == true`, inherited `entryStepId == main-worker`, `stepIds == [main-worker]`, and run `workflowId == issue-94-derived`, `status == completed`, `nodeExecutions == 1`, `transitions == 0`, `rootOutput == {status: ready, marker: issue-94-inheritance}`. Assert payload details via the resolved bundle when inspection summary omits them.

The actual installed package smoke uses its installed base's existing planning-only scenario. This is a mock route within an issue-resolution verification task, not a change of work-package mode. Before running, audit that every reachable agent, command and add-on node has a scenario record, particularly Git commit/push; `ProductionNodeAdapter.swift` has real command/add-on fallbacks on uncovered scenarios. Require complete coverage, no real agent/Git execution, and retain scenario/package hashes plus pre/post Git HEAD, index and tracked-file hashes. If installed versions differ, prepare only the necessary scenario adjustment under root `tmp/` and record the exact replacement path/command; do not change installed workflow bytes or relax terminal assertions. Use a fresh session-store directory on each rerun.

```sh
.build/debug/riela workflow validate claude-code-design-and-implement-review-loop --scope user --output json
.build/debug/riela workflow inspect claude-code-design-and-implement-review-loop --scope user --output json
.build/debug/riela workflow run claude-code-design-and-implement-review-loop --scope user --mock-scenario /Users/taco/.riela/packages/codex-design-and-implement-review-loop/workflows/codex-design-and-implement-review-loop/mock-scenario-planning-only.json --variables '{"workflowInput":{"executionMode":"design-plan-only","requestedOutcome":"Deterministic issue-94 inheritance smoke"}}' --session-store /Users/taco/gits/tacogips/riela/tmp/issue-94-implementation/smoke/sessions-1 --output json
```

All three commands must exit 0. Assert validation `valid == true`; inspection inherited entry `riela-manager` and steps include `workflow-output`; run `status == completed`, `workflowId == claude-code-design-and-implement-review-loop`, nonzero executions, terminal `workflow-output`, `rootOutput.status == accepted`, `rootOutput.workflowMode == design-plan-only`, and scenario's matching mock `commitHash == fedcba9876543210fedcba9876543210fedcba98`. Session evidence must show no `step6-implement` execution, scenario-backed reached providers/add-ons, unchanged installed source bytes and unchanged Git state. Mock commit/push values are simulation assertions only, never real finalization evidence. Missing installed dependencies, absent tools or failing checks remain explicit blocked evidence, not completion.

## Deferred work and completion

Defer exhaustive scope-tier matrices, mutable/detached registry inheritance, `--from-registry` inheritance, generalized callee redesign, ambiguity expansion, provenance abstractions and speculative API/refactoring work. Their cost exceeds this installed user-scope release blocker's needs. Promote only work proven necessary by a focused failing blocker test, recording evidence and minimal scope adjustment; do not import the five old assignments. Current installed variants share transformation semantics; adapter/backend behavior is unchanged.

Completion requires T1–T4 evidence, passing focused and ordinary/broad regression tests, build/typecheck and SwiftLint outcomes, actual installed deterministic smoke, preserved sources, updated documentation/progress, accepted independent and combined reviews, and final verified commit/push with exact files. Blocked required checks or unresolved high/mid findings prevent a completion claim. Step 4 completion means only this actionable smaller plan, preserved accepted design/history, verified DAG/ownership/scope, and author self-check evidence; implementation verification and checkpoint remain downstream.
