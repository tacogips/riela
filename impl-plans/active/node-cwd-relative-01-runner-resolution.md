# ncr-01-runner-resolution: anchor relative node/command/container workingDirectory to the run workspace root

```json
{
  "planId": "ncr-01-runner-resolution",
  "planPath": "impl-plans/active/node-cwd-relative-01-runner-resolution.md",
  "dependsOn": [],
  "wave": "W1",
  "writePaths": [
    "Sources/RielaCore/DeterministicWorkflowRunner+ExecutionEvents.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner.swift",
    "Sources/RielaCLI/WorkflowPackageParityCommands.swift",
    "Tests/RielaCoreTests/NodeWorkingDirectoryResolutionTests.swift",
    "impl-plans/progress/ncr-01-runner-resolution.md",
    "tmp/node-cwd-relative/ncr-01-runner-resolution/build-scratch",
    "Sources/RielaCore/WorkflowModel.swift",
    "Sources/RielaWorkflowRegistry/WorkflowRegistryBundleLoader.swift",
    "Tests/RielaCLITests/WorkflowBundleWorkingDirectoryLoadTests.swift",
    "examples/node-combinations-showcase/nodes/node-command-worker.json",
    "examples/monja-typescript-sdk/nodes/node-monja-command.json",
    "examples/apple-gateway-packaging-plan/nodes/node-packaging-plan.json",
    "examples/first-four-arithmetic-pipeline/workflows/divide/nodes/node-divide-worker.json"
  ],
  "sharedPaths": [],
  "artifactRoots": [
    "tmp/node-cwd-relative/ncr-01-runner-resolution/build-scratch"
  ]
}
```

## Intent and context

The bug was seen in a live ART `art-remediate` run on 2026-11-11. The agent node
`investigate.json` sets `"workingDirectory": "tmp/art-remediate/active/src"`
and uses the claude-code-agent backend. The run used
`riela workflow run ... --working-dir <root>` and failed with
`agent-gateway error -32602: cwd must be an absolute path`.

`DeterministicWorkflowRunner` passes the relative value through unchanged to:

- `AgentGatewayNodeAdapter` (`Sources/RielaAdapters/AgentGatewayNodeAdapter.swift:125`,
  `input.node.workingDirectory ?? defaultWorkingDirectory`)
- `LocalWorkflowStdioNodeExecutor` (`Sources/RielaAdapters/WorkflowStdioNodeExecutor.swift:121-148`),
  which does `URL(fileURLWithPath:)`, so the path resolves against the process cwd.

`resolvedBackendWorkingDirectory`
(`Sources/RielaCore/DeterministicWorkflowRunner+ExecutionEvents.swift:19`) has
the same flaw for execution records.

Source of truth: `design-docs/specs/design-workflow-json.md`, subsection
"`workingDirectory` resolution" (accepted at Step 3). The workspace root is
`DeterministicWorkflowRunner.fanoutWorkspaceRoot`. These CLI entry points
already set it to the run working dir:

- `Sources/RielaCLI/WorkflowRunCommand.swift:140`
- `Sources/RielaCLI/ScopedParityCommands.swift:481`
- `Sources/RielaCLI/SessionCommands.swift:596,865`

One production entry point does not set it: `riela package run`
(`Sources/RielaCLI/WorkflowPackageParityCommands.swift`, the
`DeterministicWorkflowRunner(...)` around line 454). It needs the
one-argument wiring fix in change 3 below.
`Sources/RielaCLI/WorkflowStagedVerification.swift:133` also has no root, but
it is scenario-only staged verification (`requiresScenarioResponse: true`),
so it stays nil by design. Do not change it. This gap was found by Step 5
review finding NCR-R1.

## Non-goals (do NOT do)

Round 2 of the amendment, further down, supersedes these non-goals where they
conflict. It authorizes the model, loader, loader-test and example paths
listed in the JSON header.

- Do not edit any file under `Sources/RielaAdapters`. Do not edit any
  `Sources/RielaCLI` file other than
  `Sources/RielaCLI/WorkflowPackageParityCommands.swift` (change 3 only).
  Do not edit `Sources/RielaCore/DistributedWorkerNodeExecutor.swift`. The
  adapters are correct once their input is absolute.
- Do not edit `Sources/RielaCLI/WorkflowStagedVerification.swift` or any other
  CLI runner construction site. The others already pass the root.
- Do not reuse `DistributedWorkerWorkspace.resolve` locally. It rejects `..`
  escapes and unmapped absolute paths, which would tighten local policy.
- Add no new escape/`policyBlocked` check and no new validation error.
- Do not resolve symlinks (`resolvingSymlinksInPath`). Use lexical
  `standardizedFileURL` only.
- Do not rewrite steps with `step.placement != nil`. The remote worker
  resolves those against its own workspace.
- Do not fill in nil `command.workingDirectory`, `container.workingDirectory`
  or node `workingDirectory`. The executors already fall back to the node
  value and then to `defaultWorkingDirectory`, which is the CLI working dir.
  Filling in nils changes nothing and makes the diff larger.
- Do not change the `riela/command-result` add-on's own `workingDirectory`
  config (`ProductionNodeAdapter+CommandResult.swift`). It is out of scope.
- Do not edit docs. `design-docs/specs/design-workflow-json.md` already holds
  the authoring rule.

## File-level changes

### 1. `Sources/RielaCore/DeterministicWorkflowRunner+ExecutionEvents.swift`

Add one internal free function next to `resolvedBackendWorkingDirectory`:

```swift
func anchoredWorkingDirectory(_ path: String, workspaceRoot: URL?) -> String
```

- `path` starts with `/` → return `path` unchanged, byte for byte.
- `path` is relative and `workspaceRoot != nil` → return
  `workspaceRoot.appendingPathComponent(path, isDirectory: true).standardizedFileURL.path`.
- `path` is relative and `workspaceRoot == nil` → return `path` unchanged.
  This is decision D6: legacy pass-through.
- Do not trim or otherwise touch the empty string. Treat it like any relative
  value; no special casing is required beyond what Foundation does.

Add an `AgentNodePayload` helper. It can be a `fileprivate`/internal extension
method or a free function in the same file:

```swift
func anchoringLocalWorkingDirectories(_ payload: AgentNodePayload, workspaceRoot: URL?) -> AgentNodePayload
```

It maps these fields through `anchoredWorkingDirectory` when they are
non-nil, and leaves nil fields nil:

- `payload.workingDirectory`
- `payload.command?.workingDirectory`
- `payload.container?.workingDirectory`

Imitate the field-mutation shape of
`Sources/RielaCore/DistributedWorkerNodeExecutor.swift:94-101`
(`if var command = ...`). Do not copy its nil fallback.

Change `resolvedBackendWorkingDirectory`. When `configuredWorkingDirectory` is
non-nil, pass it through `anchoredWorkingDirectory(_, workspaceRoot:)` before
the existing `URL(fileURLWithPath:isDirectory:).standardizedFileURL.path`.
Leave the nil fallback chain (`workspaceRoot?.path ?? cwd`) and the signature
unchanged. Update the doc comment with one sentence: relative values anchor to
the workspace root.

### 2. `Sources/RielaCore/DeterministicWorkflowRunner.swift`

There are exactly two local-dispatch construction sites. Step 3 confirmed
them with
`rg -n 'AdapterExecutionInput\(|WorkflowStdioNodeExecutionInput\(' Sources/RielaCore`.

- About line 705: `let adapterInput = AdapterExecutionInput(node: executionPayload, ...)`.
  Pass `step.placement == nil ? anchoringLocalWorkingDirectories(executionPayload, workspaceRoot: fanoutWorkspaceRoot) : executionPayload`.
  Do not mutate `executionPayload` itself before this point. It also feeds
  `publicationPayload.output` and validation; keep those unchanged.
- About line 851: the `WorkflowStdioNodeExecutionInput(... node: payload ...)`
  inside `executeStdioNodeAndPublish`. Apply the same conditional with
  `payload`.

The `resolvedBackendWorkingDirectory(...)` call sites
(`DeterministicWorkflowRunner.swift:765,839`, `+AdapterPublication.swift:27`,
`+PromptGuard.swift:51`) need no edits. They pick up the new rule through the
helper. Do not touch those other files.

Before editing, re-run the `rg` above. If it shows a third construction site
in RielaCore, stop and record it in the progress log as a blocker. Do not
widen scope silently.

### 3. `Sources/RielaCLI/WorkflowPackageParityCommands.swift` (`riela package run`, NCR-R1)

This is a one-argument change. In the `DeterministicWorkflowRunner(...)` init
around line 454, pass `fanoutWorkspaceRoot: workingDirectoryURL`.
`workingDirectoryURL` is already computed around line 379 from
`parsed.workingDirectory ?? cwd`, with `isDirectory: true`. Follow the
argument label and order of the init declaration in
`Sources/RielaCore/DeterministicWorkflowRunner.swift:190-210`, where
`fanoutWorkspaceRoot` comes after `calleeResolver`, after
`simulatesCrossWorkflowDispatch`, and before `nestedInvocation*`. Imitate
`Sources/RielaCLI/WorkflowRunCommand.swift:131-140`.

Pitfalls:

- Swift requires default-argument parameters to stay in declaration order.
  Put the new argument after `simulatesCrossWorkflowDispatch:`.
- Do not add a new URL. Reuse `workingDirectoryURL`.
- This change also lets fanout `changeTracking` run under `package run`.
  Before, it threw `policyBlocked "fanout changeTracking requires a host-bound fanoutWorkspaceRoot"`.
  This matches `workflow run` and is intended. Do not add a guard against it.
- Change nothing else in this file.

Before the edit, run
`rg -n 'DeterministicWorkflowRunner\(' Sources | grep -v 'Sources/RielaCore/DeterministicWorkflowRunner.swift'`.
It should show 6 sites. After the edit, every site except
`WorkflowStagedVerification.swift` should pass `fanoutWorkspaceRoot`. Record
this in the progress log.

## Invariants

- Absolute values reach the backend byte-identical to the authored value.
- With `fanoutWorkspaceRoot == nil`, behavior is identical to today.
  Specifically, the existing test
  `DeterministicWorkflowRunnerBackendEventTests.testBackendExecutionsPersistResolvedInheritedAndRelativeWorkingDirectories`
  still passes unmodified: its relative case runs without a workspace root and
  expects a cwd-relative path.
- Steps with `placement` see an unchanged `AdapterExecutionInput.node` /
  `WorkflowStdioNodeExecutionInput.node`.
- The recorded `backendWorkingDirectory` equals the cwd actually dispatched
  for local agent steps, after standardization.

## Tests: new file `Tests/RielaCoreTests/NodeWorkingDirectoryResolutionTests.swift`

Use a temp `workspaceRoot`
(`FileManager.default.temporaryDirectory/riela-node-cwd-<UUID>`). Nothing needs
to exist on disk. Use a private recording `NodeAdapter` actor that captures
`input.node.workingDirectory`, imitating `StepCountingAdapter` in
`Tests/RielaCoreTests/DeterministicWorkflowRunnerBackendEventTests.swift`. For
command/container cases, use the internal `StaticStdioNodeExecutor`
(`Tests/RielaCoreTests/DeterministicWorkflowRunnerTestSupport.swift:152`,
`capturedInputs()`). Build workflows the same way as `backendEventWorkflow()`
and `backendEventPayload(...)` in that file; copy those private helpers
locally. For a command payload, imitate existing command-node payloads in
`Tests/RielaCoreTests/DeterministicWorkflowRunnerMemoryTests.swift` (around
lines 160-215).

Cases (`input -> expected`):

- Agent node `workingDirectory: "sub/dir"`, runner `fanoutWorkspaceRoot: root`
  → the adapter sees `root/sub/dir` (standardized), and
  `session.executions.first?.backendWorkingDirectory == root/sub/dir`.
- Agent node `workingDirectory: "a/../b"` with root → the adapter sees
  `root/b`. This shows `..` is anchored and standardized and not rejected.
- Agent node `workingDirectory: "/abs/path"` with root → the adapter sees
  `/abs/path` exactly.
- Agent node with no `workingDirectory` and root → the adapter sees nil
  (unchanged; the adapter default handles it), and the record is
  `root.standardizedFileURL.path`.
- Command node, node `workingDirectory: "w"` and `command.workingDirectory`
  nil, with root → the captured stdio input has node.workingDirectory
  `root/w` and command.workingDirectory nil. The executor's fallback then
  yields `root/w`.
- Command node `command.workingDirectory: "c"` with root → command
  workingDirectory `root/c`.
- Container node `container.workingDirectory: "k"` with root → `root/k`.
  Skip this case only if constructing a container payload needs fields not
  constructible in RielaCore tests, and log why in the progress file.
- Agent step with `placement: DistributedExecutionPlacement(target: DistributedWorkerTarget(), workspace: "remote")`
  and a private recording `DistributedNodeExecuting` that captures the
  invocation, with node `workingDirectory: "sub/dir"` → the captured
  `.adapter(input).node.workingDirectory == "sub/dir"` (not anchored). See
  `Tests/RielaCoreTests/AgentPromptGuardTests.swift:129` for placement
  construction. If returning a valid `DistributedNodeOutput.adapter(...)` is
  impractical, the recorder may capture and then throw; assert on the
  captured value and expect the run to fail.
- Unit test of `anchoredWorkingDirectory` with `workspaceRoot: nil` and
  `"rel"` → `"rel"`.

## Verification commands

Run everything from the worktree root
`/Users/taco/gits/tacogips/riela-worktrees/node-cwd` inside
`arch -arm64 /bin/zsh -lc '...'`. Write logs under `tmp/node-cwd-relative/`
and record exit statuses in the progress log.

All SwiftPM output goes to the declared artifact root,
`tmp/node-cwd-relative/ncr-01-runner-resolution/build-scratch`.

- Every `swift build` / `swift test` command below MUST include
  `--scratch-path tmp/node-cwd-relative/ncr-01-runner-resolution/build-scratch`,
  written as the literal path. Do not use a shell variable: a variable set
  outside `arch -arm64 /bin/zsh -lc '...'` is not visible inside the wrapper.
- `swift test --skip-build` must use the same scratch path, otherwise it
  finds no products.
- Never run SwiftPM without `--scratch-path`. Without it, SwiftPM writes the
  worktree `.build`, which is undeclared. Never touch the main checkout's
  `.build`.
- Run `swiftlint` with `--no-cache`.

The worktree has no existing `.build`, so the first build is a full cold
build. Expect it to take a long time, and wait for it in the foreground to
its terminal exit.

These commands are byte-identical to the `verification` array of
`impl-plans/active/node-cwd-relative-dispatch.json` (plan
`ncr-01-runner-resolution`).

0. `mkdir -p tmp/node-cwd-relative/ncr-01-runner-resolution/build-scratch`
1. `arch -arm64 /bin/zsh -lc 'swift build --build-tests --scratch-path tmp/node-cwd-relative/ncr-01-runner-resolution/build-scratch 2>&1 | tee tmp/node-cwd-relative/build.log; exit ${pipestatus[1]}'`
   → exit 0.
2. `arch -arm64 /bin/zsh -lc "swift test --skip-build --scratch-path tmp/node-cwd-relative/ncr-01-runner-resolution/build-scratch --filter 'NodeWorkingDirectoryResolutionTests|DeterministicWorkflowRunnerBackendEventTests|AgentPromptGuardTests|PromptOverflowGuardIntegrationTests|SessionObservabilityTests|DeterministicWorkflowRunnerMemoryTests|FanoutArtifactEvidenceRunnerTests|WorkflowModelTests' 2>&1 | tee tmp/node-cwd-relative/test-core.log; exit \${pipestatus[1]}"`
   → exit 0, and every new test is listed as passed.
3. `arch -arm64 /bin/zsh -lc "swift test --skip-build --scratch-path tmp/node-cwd-relative/ncr-01-runner-resolution/build-scratch --filter 'ScopedParityCallStepFanoutTests|WorkflowHostCapabilityTests|WorkflowCommandTests/testPackage|WorkflowBundleWorkingDirectoryLoadTests|WorkflowDefinitionServiceTests|WorkflowDefinitionSourceDriftResolutionTests|RielaExampleParityTests|WorkflowValidateGatewayContextTests|DistributedNodeExecutionTests' 2>&1 | tee tmp/node-cwd-relative/test-cli.log; exit \${pipestatus[1]}"`
   → exit 0. These are CLI suites that run with a workspace root and with
   placement. `WorkflowCommandTests/testPackage` selects the `package run`
   suite in `Tests/RielaCLITests/WorkflowPackageArchiveCommandTests.swift`,
   which is an extension of `WorkflowCommandTests`. An example is
   `testPackagePackValidateInstallAndRunRielaPackageArchive`.
4. `arch -arm64 /bin/zsh -lc 'swiftlint lint --no-cache Sources/RielaCore/DeterministicWorkflowRunner+ExecutionEvents.swift Sources/RielaCore/DeterministicWorkflowRunner.swift Sources/RielaCLI/WorkflowPackageParityCommands.swift Sources/RielaCore/WorkflowModel.swift Sources/RielaWorkflowRegistry/WorkflowRegistryBundleLoader.swift Tests/RielaCoreTests/NodeWorkingDirectoryResolutionTests.swift Tests/RielaCLITests/WorkflowBundleWorkingDirectoryLoadTests.swift 2>&1 | tee tmp/node-cwd-relative/lint.log'`
   → no new violations in the changed lines.
4b. End-to-end gate, run after the build in command 1:
   `arch -arm64 /bin/zsh -lc '/bin/zsh tmp/node-cwd-relative/ncr-01-runner-resolution/continuation-command-check.sh > tmp/node-cwd-relative/ncr-01-runner-resolution/e2e-after.log 2>&1; exit $?'`
   → exit 0. Both the inherited and the explicit relative command cases run
   in `<workspace>/<rel>`. The earlier exit-1 log
   `continuation-command-check.log` is kept unchanged as the baseline.
   - If the fixture script points at a binary path or assertion that no
     longer matches, fix only the fixture under
     `tmp/node-cwd-relative/ncr-01-runner-resolution/`.
   - Never change the explicit case's expected value to the bundle path.
   - The fixture lives inside the artifact root's parent, which is evidence
     space, not a tracked source.
5. `git diff --name-only 3a9c1dad -- Sources/RielaAdapters Sources/RielaCLI Sources/RielaCore/DistributedWorkerNodeExecutor.swift`
   → exactly `Sources/RielaCLI/WorkflowPackageParityCommands.swift`.
   `Sources/RielaCLI/WorkflowResolution.swift` must not appear. Also run
   `git diff --stat` → only the source and example writePaths of this plan
   changed. The scratch root is under gitignored `tmp/` and must not appear.
6. Cleanup, after commands 1–4 have finished and their logs are written:
   `du -sh tmp/node-cwd-relative/ncr-01-runner-resolution/build-scratch; find tmp/node-cwd-relative/ncr-01-runner-resolution/build-scratch | wc -l; rm -rf tmp/node-cwd-relative/ncr-01-runner-resolution/build-scratch; test ! -e .build && echo no-worktree-build`
   → record the size and entry count in the progress log. The command must
   print `no-worktree-build`.

If a pre-existing failure appears in command 2 or 3, do not build a second
baseline scratch (it would be undeclared). Classify the failure from its
failure text, and from whether the failing test touches any changed symbol.
Record the reasoning in the progress log.

## Acceptance / done criteria (mechanically checkable)

- `rg -n 'func anchoredWorkingDirectory' Sources/RielaCore` → 1 hit.
- `rg -n 'anchoringLocalWorkingDirectories' Sources/RielaCore/DeterministicWorkflowRunner.swift` → 2 hits.
- `git diff --name-only 3a9c1dad -- Sources/RielaAdapters Sources/RielaCLI Sources/RielaCore/DistributedWorkerNodeExecutor.swift`
  → exactly `Sources/RielaCLI/WorkflowPackageParityCommands.swift`.
- `rg -n 'fanoutWorkspaceRoot' Sources/RielaCLI/WorkflowPackageParityCommands.swift` → 1 hit.
- `git diff 3a9c1dad -- Sources/RielaCLI/WorkflowPackageParityCommands.swift`
  → one added argument line only.
- Commands 1–3 and 4b exit 0, and lint reports no new violations on changed files.
- `rg -n 'authoredWorkingDirectory' Sources/RielaCore/WorkflowModel.swift` → at
  least 4 hits (property and CodingKeys for each of the two structs).
- `rg -n '"workingDirectory"' <4 example node files>` → no hits.
- The progress log lists each test case and its result, plus log paths and exit codes.

## Amendment 2026-11-11 (Step 5 review NCR-R1)

`riela package run` built its runner without `fanoutWorkspaceRoot`. The fix:

- Added `Sources/RielaCLI/WorkflowPackageParityCommands.swift` to
  `writePaths` (change 3).
- Corrected the claim that all CLI entry points set the root.
- Narrowed the RielaCLI non-goal.
- Updated the git-diff done criterion.
- Added the `package run` tests to verification command 3.

`WorkflowStagedVerification.swift` is scenario-only and stays unchanged.

## Amendment 2026-11-11 (blocked-wave-scope-or-contract, round 1)

Blocker (dependency "Approved build artifact location"): the plan declared
`artifactRoots: []`, but `swift build` defaults to `.build`, which is
undeclared. The checkpoint was `00c6d768`.

Decision:

- Authorize exactly one artifact root,
  `tmp/node-cwd-relative/ncr-01-runner-resolution/build-scratch`. It is listed
  in both `writePaths` and `artifactRoots`, it is not in `sharedPaths`, and it
  is not inside any other source path.
- Every `swift build` / `swift test` run passes `--scratch-path` to it.
- `swiftlint` runs with `--no-cache`.
- The baseline re-run on `3a9c1dad` is dropped. Failures are classified from
  their failure text instead.
- After verification, record `du -sh` and the entry count of the root, then
  remove it.

Unchanged: the source writePaths, the planId, the design decisions, and the
test matrix.

Follow-up from Step 5 review finding NCR-A1 (high):

- The same amendment is now applied to the committed dispatch manifest,
  `impl-plans/active/node-cwd-relative-dispatch.json`. In `plans[0]`:
  - `writePaths` gains the build-scratch root.
  - `artifactRoots` is exactly that root.
  - `sharedPaths` stays `[]`.
  - The `verification` array now uses the literal `--scratch-path` on
    `swift build` and both `swift test` commands, `swiftlint --no-cache`,
    the git diff check, and the cleanup / no-`.build` command.
- The plan's Verification section no longer uses a `$S` shell variable,
  because it is not visible inside `arch -arm64 /bin/zsh -lc`. It lists the
  same literal commands as the manifest.

## Amendment 2026-11-11 (blocked-wave-scope-or-contract, round 2)

### Blocker

The dependency is "Checkpoint amendment authorizing registry resolution and
regression-test paths". The blocker names these paths:

- `Sources/RielaWorkflowRegistry/WorkflowRegistryBundleLoader.swift`
- `Sources/RielaCLI/WorkflowResolution.swift`

Terra's evidence: a real command with `command.workingDirectory: "explicit/dir"`
ran in `<workflowDefinitionDir>/<workflowId>/explicit/dir`. Before the run,
`WorkflowRegistryBundleLoader.absolutizedStdioPaths`
(`WorkflowRegistryBundleLoader.swift:185, 235-245`, and
`+SharedNodeRefs.swift:270`) turns relative `command.workingDirectory`,
`command.executable` and `container.workingDirectory` into
workflow-directory paths. The exception is values with a `./` prefix.
`WorkflowResolution.swift:737-757` holds an identical copy, and `rg` finds no
caller for it.

### Decision

No write paths are authorized. The blocker is escalated to Step 5 as
`needs_design_revision`. The source writePaths are unchanged.

### Reason

The gap cannot be closed without a design change. The accepted design
(`design-docs/specs/design-workflow-json.md`, "`workingDirectory` resolution")
says a relative command or container `workingDirectory` "never resolves
against the ... workflow definition directory". The shipped bundles depend on
exactly that behavior:

- `examples/node-combinations-showcase/nodes/node-command-worker.json:17`
- `examples/monja-typescript-sdk/nodes/node-monja-command.json:10`
- `examples/apple-gateway-packaging-plan/nodes/node-packaging-plan.json:17`

Each of these sets `command.workingDirectory: "scripts"`, which means the
bundle's own `scripts/` directory. Re-anchoring that to `--working-dir` would
break these examples and bundle portability. That contradicts the constraint
"additive and minimal; keep existing behavior".

The node-level `workingDirectory` and the inherited command/container
directory are not affected. Terra verified the inherited case passes
(continuation-command-check: 1 of 2 passed).

### Proposed design revision for Step 5 (not applied here)

- Narrow the rule. An explicitly authored relative `command.workingDirectory`
  or `container.workingDirectory` keeps its existing bundle-relative
  resolution at load time.
- Only the node-level `workingDirectory` anchors to the workspace root. A
  command or container with no directory of its own inherits that node value.
- The runner anchoring stays as planned. Bundle-absolutized values are already
  absolute, so for them it is a no-op.
- Revise the test matrix: replace "explicit `command.workingDirectory: "c"` →
  `root/c`" with a runner-level unit test plus a note that bundle loading
  absolutizes explicit values first. Under that revision, no registry file
  needs editing.

## Amendment 2026-11-11 (blocked-wave-scope-or-contract, round 2: resolution after the design was revised)

The escalation above produced a design revision (NCR-D1, then D2, then D3).
Step 3 accepted the revision in comm-000040. The accepted design is
`design-docs/specs/design-workflow-json.md#workingDirectory-resolution`
(decisions D8, D11 and D12). The pending user decision is recorded in
`design-docs/user-qa/qa-node-cwd-relative.md`; until it is made, option A is
the default.

This round authorizes the paths below and supersedes the round-2 "No write
paths are authorized" decision. The planId and all earlier work stay as they
are. Do not revert the runner, CLI or test changes made in wave 2.

### Authorized paths and decisions for each blocker path

- `Sources/RielaWorkflowRegistry/WorkflowRegistryBundleLoader.swift`:
  authorized (change 4).
- `Sources/RielaCLI/WorkflowResolution.swift`: NOT authorized. Its
  `absolutizedStdioPaths` copy at about line 737 has no callers, so it is
  not on the execution path. The design leaves it unchanged.
- Added for the design contract:
  - `Sources/RielaCore/WorkflowModel.swift` (change 5)
  - `Tests/RielaCLITests/WorkflowBundleWorkingDirectoryLoadTests.swift`
    (new, registry-level tests)
  - the four example node JSONs (change 6)
- Placement regression tests go in the already-owned
  `Tests/RielaCoreTests/NodeWorkingDirectoryResolutionTests.swift`.

### 5. `Sources/RielaCore/WorkflowModel.swift`

- Add `public var authoredWorkingDirectory: String?` to
  `WorkflowCommandExecution` (about line 684) and to
  `WorkflowContainerExecution` (about line 767).
- Add an optional init parameter that defaults to nil, as the last
  parameter, so existing call sites compile unchanged.
- Add the key to both `CodingKeys` (the synthesized encode uses these and
  omits nil, so fingerprints of existing definitions do not change).
- Add the key to the Riela decoding keys
  (`RielaCommandCodingKeys` / `RielaContainerCodingKeys`) using
  `decodeIfPresent`, so loaded payloads persisted by the definition store
  round-trip with the field intact.
- Pitfalls:
  - Do not change `normalizedScriptExecutable` (WorkflowModel.swift:~756).
  - Do not change `workingDirectory` decoding.
  - Equatable is synthesized, and the new field takes part in it. That is
    intended.

### 4. `Sources/RielaWorkflowRegistry/WorkflowRegistryBundleLoader.swift`

`absolutizedStdioPaths` (about line 235) keeps every current rewrite
byte-for-byte: `command.executable`, `command.workingDirectory` and
`container.workingDirectory` are all still absolutized relative to the
bundle. In addition, for each of the two working-directory fields:

- If the loader rewrote a relative value (no `/` or `./` prefix), set
  `authoredWorkingDirectory` to the original value.
- Otherwise set `authoredWorkingDirectory = nil`. This includes absolute
  values, `./` values, a nil `workingDirectory`, and an author-supplied
  `authoredWorkingDirectory`, which is always overwritten.

To get the "did it rewrite" decision, compare the result with the input or
reuse the same guard as `absoluteCommandPath`. Do not change
`absoluteCommandPath`'s output.

`+SharedNodeRefs.swift:270` calls the same function, so it needs no edit.

Pitfall: the remote (placed) dispatch input must not change at all. The
placement tests below check this.

### 1b. Runner change in `Sources/RielaCore/DeterministicWorkflowRunner+ExecutionEvents.swift` (already owned)

In `anchoringLocalWorkingDirectories`, for `command` and `container`, use
`authoredWorkingDirectory ?? workingDirectory` as the value to anchor. Write
the anchored result into `workingDirectory` and set
`authoredWorkingDirectory = nil` in the local copy. The node-level
`workingDirectory` is unchanged.

This function runs only when `step.placement == nil`, and that guard already
exists at both dispatch sites. Placed dispatch keeps forwarding the
unmodified payload.

### 6. Example migration (option A, design D9)

Delete the line `"workingDirectory": "scripts"` from:

- `examples/node-combinations-showcase/nodes/node-command-worker.json`
- `examples/monja-typescript-sdk/nodes/node-monja-command.json`
- `examples/apple-gateway-packaging-plan/nodes/node-packaging-plan.json`
- `examples/first-four-arithmetic-pipeline/workflows/divide/nodes/node-divide-worker.json`

Why this is required:

- With `workingDirectory: "scripts"`, `normalizedScriptExecutable` turns
  `scriptPath: "scripts/x.sh"` into `"./x.sh"`. The loader does not rewrite
  `./`-prefixed values, so the executable resolves relative to the cwd.
- Under the new local rule that cwd would be `<working-dir>/scripts`, and the
  spawn would fail.
- Without the line, `scriptPath` stays `scripts/x.sh` and the loader makes it
  bundle-absolute.

The scripts themselves are cwd-independent (verified at Step 2), so outputs
are unchanged. Keep the JSON otherwise byte-identical: same key order and
trailing newline, with only the comma before the removed line adjusted.

### Tests added in this round

`Tests/RielaCLITests/WorkflowBundleWorkingDirectoryLoadTests.swift` uses a
temp bundle and `WorkflowRegistryBundleLoader().loadBundle(at:rootDirectory:scope:)`.
Imitate `Tests/RielaCLITests/WorkflowTaskAddonTests.swift:49` and
`Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift:76`.

- `command.workingDirectory: "sub"` → loaded `workingDirectory ==
  <bundle>/sub` (unchanged) and `authoredWorkingDirectory == "sub"`.
- `container.workingDirectory: "sub"` → the same result.
- `command.workingDirectory` is absolute or `./sub` → `authoredWorkingDirectory == nil`,
  and `workingDirectory` is unchanged.
- An authored JSON that sets `"authoredWorkingDirectory": "x"` together with
  an absolute `workingDirectory` → the loaded value is nil.
- `command.executable` / `scriptPath` → still bundle-absolute, exactly as
  before.

Additions to `Tests/RielaCoreTests/NodeWorkingDirectoryResolutionTests.swift`.
These use a recording `DistributedNodeExecuting`. The worker's mapping is
already covered by `DistributedWorkerWorkspace`, so a direct unit call is
acceptable for the mapping and rejection checks.

- Local command step whose payload has `workingDirectory: "/controller/workflows/demo/sub"`
  and `authoredWorkingDirectory: "sub"`, with root `/ws` → the stdio executor
  sees `/ws/sub`.
- The same payload on a step with `placement` → the recorder sees
  `workingDirectory == "/controller/workflows/demo/sub"` and
  `authoredWorkingDirectory == "sub"`, both unchanged.
- `DistributedWorkerWorkspace(root: /worker, controllerRoot: /controller).resolve("/controller/workflows/demo/sub")`
  → `/worker/workflows/demo/sub`.
- The same call without `controllerRoot` → throws `invalidInput`.
  `resolve` is internal, so use `@testable import RielaCore`.
- One workflow whose two steps share the node, one local and one placed →
  local `/ws/sub`, remote unchanged.
- The container equivalent of the local case.

### Rehydration audit (required, report in the progress log)

Run `rg -n 'nodePayloads' Sources/RielaCLI/WorkflowDefinition* Sources/RielaCore/*DefinitionStore*`
and confirm that stored and looked-up payloads go through `Codable`, so the
field survives. `WorkflowDefinitionServiceTests` in command 3 exercises
`lookup`. If some path rebuilds payloads without the field, record it as a
blocker. Do not weaken acceptance.

### Still forbidden

- `Sources/RielaCLI/WorkflowResolution.swift`
- `Sources/RielaCore/DistributedWorkerNodeExecutor.swift`
- `Sources/RielaAdapters/**`
- `+SharedNodeRefs.swift`
- any escape check
- any change to remote inputs
- any bundle-root expected value for the explicit local case

## Progress log

Keep `impl-plans/progress/ncr-01-runner-resolution.md` up to date with:

- the timestamped steps taken
- pre- and post-edit `shasum -a 256` of each edited source file
- the `rg` construction-site output
- each verification command with its exit status and log path
- any skipped case with its reason

Edit only this plan's own progress file. Re-read each target file just before
editing it. If its content no longer matches what you read earlier (drift),
stop, record the drift, and re-plan the edit against the fresh content.

## Implementation status 2026-11-11

Implemented the local dispatch and package-run wiring. The assigned core and CLI
filters passed (53 and 59 tests), the isolated build passed, and selected-file
SwiftLint found zero violations. Actual command verification passed for inherited
node cwd but exposed explicit command cwd resolving against the workflow directory
in `Sources/RielaWorkflowRegistry/WorkflowRegistryBundleLoader.swift`. This path
is outside the assigned write scope; implementation is blocked pending a checkpoint
amendment. See `impl-plans/progress/ncr-01-runner-resolution.md` for evidence.
Formal review and final handoff remain downstream.
