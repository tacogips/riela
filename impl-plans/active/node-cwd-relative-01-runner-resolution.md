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
    "impl-plans/progress/ncr-01-runner-resolution.md"
  ],
  "sharedPaths": []
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

1. `swift build --build-tests 2>&1 | tee tmp/node-cwd-relative/build.log; echo "exit=${pipestatus[1]}"`
   → exit 0.
2. `swift test --skip-build --filter 'NodeWorkingDirectoryResolutionTests|DeterministicWorkflowRunnerBackendEventTests|AgentPromptGuardTests|PromptOverflowGuardIntegrationTests|SessionObservabilityTests|DeterministicWorkflowRunnerMemoryTests|FanoutArtifactEvidenceRunnerTests' 2>&1 | tee tmp/node-cwd-relative/test-core.log; echo "exit=${pipestatus[1]}"`
   → exit 0, and every new test is listed as passed.
3. `swift test --skip-build --filter 'ScopedParityCallStepFanoutTests|WorkflowHostCapabilityTests|WorkflowCommandTests/testPackage' 2>&1 | tee tmp/node-cwd-relative/test-cli.log; echo "exit=${pipestatus[1]}"`
   → exit 0. These are CLI suites that run with a workspace root and with
   placement. `WorkflowCommandTests/testPackage` selects the `package run`
   suite in `Tests/RielaCLITests/WorkflowPackageArchiveCommandTests.swift`,
   which is an extension of `WorkflowCommandTests`. An example is
   `testPackagePackValidateInstallAndRunRielaPackageArchive`.
4. `swiftlint lint Sources/RielaCore/DeterministicWorkflowRunner+ExecutionEvents.swift Sources/RielaCore/DeterministicWorkflowRunner.swift Sources/RielaCLI/WorkflowPackageParityCommands.swift Tests/RielaCoreTests/NodeWorkingDirectoryResolutionTests.swift 2>&1 | tee tmp/node-cwd-relative/lint.log; echo "exit=${pipestatus[1]}"`
   → no new violations in the changed lines.
5. `git diff --stat` → only the five writePaths changed.

If a pre-existing failure appears in step 2 or 3, confirm it on the original
HEAD `3a9c1dad` before calling it unrelated. Use a separate scratch path such
as `--scratch-path tmp/node-cwd-relative/base-scratch`, or reason from the
failure text, and record it.

## Acceptance / done criteria (mechanically checkable)

- `rg -n 'func anchoredWorkingDirectory' Sources/RielaCore` → 1 hit.
- `rg -n 'anchoringLocalWorkingDirectories' Sources/RielaCore/DeterministicWorkflowRunner.swift` → 2 hits.
- `git diff --name-only 3a9c1dad -- Sources/RielaAdapters Sources/RielaCLI Sources/RielaCore/DistributedWorkerNodeExecutor.swift`
  → exactly `Sources/RielaCLI/WorkflowPackageParityCommands.swift`.
- `rg -n 'fanoutWorkspaceRoot' Sources/RielaCLI/WorkflowPackageParityCommands.swift` → 1 hit.
- `git diff 3a9c1dad -- Sources/RielaCLI/WorkflowPackageParityCommands.swift`
  → one added argument line only.
- Commands 1–3 exit 0, and lint reports no new violations on changed files.
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
