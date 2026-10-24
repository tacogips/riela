# ISW-163: opt-in bounded command failure diagnostics

**Status**: Ready
**planId**: ISW-163-command-failure-diagnostics
**Issue**: https://github.com/tacogips/riela/issues/163
**Design Reference**: design-docs/specs/design-command-failure-diagnostics.md
**dependsOn**: none (wave 1)
**Created**: 2026-10-24

## Intent and context

When a command node exits nonzero, its stdout is dropped today. Add an opt-in
`command.failureDiagnostics` policy. On a nonzero exit it records a bounded,
schema-validated object as one non-authoritative backend event
`command_failure_diagnostics`. The command still fails.

The reference implementation is commit `155f1145` on `fix/command-failure-metadata`.
Treat that branch as read-only and read it with `git show 155f1145 -- <path>`.
It conflicts with the current tree, so port its intent by hand. Never
cherry-pick, merge or check out that branch.

## Non-goals

- No change to container nodes, mock-scenario stdio executors
  (`makeScenarioBackedStdioNodeExecutor`) or distributed workers.
- No new store tables, artifact files, CLI flags or GraphQL fields.
- No retention of metadata for any other backend event type.
- No validation of `failureDiagnostics` at `workflow validate` time. An
  invalid policy yields a `rejected` receipt at runtime, as in the reference.

## Write ownership (writePaths)

- `Sources/RielaCore/WorkflowFailureDiagnostics.swift` (new)
- `Sources/RielaCore/WorkflowModel.swift`
- `Sources/RielaCore/RuntimeStore.swift`
- `Sources/RielaAdapters/LocalProcess.swift`
- `Sources/RielaAdapters/WorkflowStdioNodeExecutor.swift`
- `Tests/RielaAdaptersTests/CommandFailureDiagnosticsTests.swift` (new)
- `Tests/RielaCoreTests/RuntimeStoreTests.swift`
- `README.md`
- `impl-plans/command-failure-metadata.md` (new; ported plan record)
- `impl-plans/progress/issue-sweep-20261024-163-command-failure-diagnostics.md`

No other plan writes these files.

## File-level changes

1. **`Sources/RielaCore/WorkflowFailureDiagnostics.swift`**: new
   `public struct WorkflowFailureDiagnostics: Codable, Equatable, Sendable`
   with these members:
   - `schema: JSONObject`
   - `maxBytes: Int`, default 16_384
   - `path: [String]`, default `[]`
   - `static let stdoutByteLimit = 65_536`
   - `func metadata(from stdout: String) -> JSONObject?`

   Take the decoder and the restricted-schema acceptor from
   `git show 155f1145:Sources/RielaCore/WorkflowFailureDiagnostics.swift`
   unchanged in behavior. The schema rules are the table in the design doc.
2. **`Sources/RielaCore/WorkflowModel.swift`**:
   - add `failureDiagnostics: WorkflowFailureDiagnostics?` to
     `WorkflowCommandExecution`: the stored property, a defaulted `init`
     parameter `failureDiagnostics: WorkflowFailureDiagnostics? = nil`, a
     case in both `CodingKeys` and `RielaCommandCodingKeys`, and
     `decodeIfPresent` in `init(from:)`;
   - check how the struct encodes. If it has a custom `encode(to:)`, add the
     key there too. The Codable round-trip test below must pass.
3. **`Sources/RielaCore/RuntimeStore.swift`**: in
   `InMemoryWorkflowRuntimeStore.appendRecentBackendEvent`, pass
   `metadata: input.eventType == "command_failure_diagnostics" ? input.metadata : nil`
   into `WorkflowBackendEventRecord`. Its `metadata` field already exists in
   `Sources/RielaCore/RuntimeSession.swift`. Change nothing else.
4. **`Sources/RielaAdapters/LocalProcess.swift`**:
   - add `stdoutCaptureByteLimit: Int?` (default nil) to
     `LocalProcessConfiguration`, as a stored property and as the last init
     parameter;
   - add `captureByteLimit` to `LocalProcessPipeReader`: retain at most that
     many bytes, keep draining the pipe, and pass only retained bytes to the
     line event handler;
   - wire it for stdout only, in `FoundationLocalProcessRunner`.

   Imitate the `155f1145` diff of this file.
5. **`Sources/RielaAdapters/WorkflowStdioNodeExecutor.swift`**:
   - in `processConfiguration(for:)`, `.command` case: keep
     `inheritEnvironment: false`, which the current tree has and
     `155f1145` lacks. Add
     `stdoutCaptureByteLimit: command.failureDiagnostics == nil ? nil : WorkflowFailureDiagnostics.stdoutByteLimit + 1`;
   - in `execute`, inside the nonzero `guard`: when `input.kind == .command`
     and a policy exists, call `policy.metadata(from: result.stdout)` and emit
     exactly one
     `AdapterBackendEvent(provider: "command", eventType: "command_failure_diagnostics", channel: .lifecycle, metadata: [...])`
     via `await context.backendEventHandler?(...)`. Then throw the same
     `providerError` as today, with the message unchanged;
   - after the guard, on exit zero with a policy, throw
     `AdapterExecutionError(.providerError, "command stdout exceeded diagnostic capture limit")`
     when `result.stdout.utf8.count > WorkflowFailureDiagnostics.stdoutByteLimit`;
   - check `AdapterBackendEvent` for a `metadata` init parameter. The
     reference uses it; if the current tree names it differently, adapt the
     call, not the type.
6. **`README.md`**: add the opt-in paragraph from the `155f1145` README diff
   at the end of the command-node / distributed-workers area (near the
   "controller and worker setup" paragraph). Keep the link to
   `impl-plans/command-failure-metadata.md`.
7. **`impl-plans/command-failure-metadata.md`**: port the reference file. Add
   a line pointing to `design-docs/specs/design-command-failure-diagnostics.md`,
   and replace the old Verification paragraph with this run's evidence.

## Invariants (must stay true)

- Without a policy, behavior and the process configuration are identical to
  today: no capture limit and no event.
- A nonzero exit always throws `providerError`. Diagnostics never enter
  `failureReason`, `acceptedOutput`, `rootOutput` or a route message.
- Metadata always contains `authoritative: false`, the integer `exitCode`, and
  `captureStatus` set to `validated` or `rejected`. `diagnostics` is present
  only when validated.
- A rejected capture retains no raw stdout, no fragment and no sibling key.

## Pitfalls

- Do not drop the current `inheritEnvironment: false`; the reference predates
  it.
- The overflow sentinel is `limit + 1` retained bytes. A stdout of exactly
  65,536 bytes is allowed. Test both 65,536 and 65,537.
- Do not stream excess bytes to the output event handler.
- `path` keys select nested objects. The selected value must be an object, and
  the result is encoded and then checked against `maxBytes`.
- Do not touch `Sources/RielaCore/RuntimeHistoryImport.swift`,
  `DeterministicWorkflowRunner+*.swift` or `WorkflowGatewayAddonValidation.swift`.
  Other plans own them.

## Tests (`Tests/RielaAdaptersTests/CommandFailureDiagnosticsTests.swift`, plus `Tests/RielaCoreTests/RuntimeStoreTests.swift`)

Imitate `git show 155f1145:Tests/RielaAdaptersTests/CommandFailureDiagnosticsTests.swift`,
and use the stub runner pattern in
`Tests/RielaAdaptersTests/WorkflowStdioNodeExecutorTests.swift`.

| Situation | Expected outcome |
| --- | --- |
| Nonzero exit, no policy, JSON stdout | throws `providerError`; zero backend events |
| Nonzero exit, valid policy + matching diagnostics | one event; `captureStatus: "validated"`; `diagnostics` equals the selected object; still throws `providerError` |
| Nonzero exit, stdout contains an extra sibling key outside `path`, or an extra field inside the object | `rejected` (extra field) or `validated` without the sibling (sibling outside `path`); the sibling sentinel string is absent from the event |
| Nonzero exit, stdout 65,537 bytes | `rejected` |
| Exit zero with policy, stdout 65,537 bytes | throws "command stdout exceeded diagnostic capture limit" |
| Exit zero with policy, stdout ≤ 65,536 valid JSON | normal accepted payload |
| Schema violations: open object, free string, integer bound > 1e9, `maxItems` > 256, `maxBytes` 0 | `rejected` |
| `WorkflowCommandExecution` with `failureDiagnostics` | JSON encode/decode round trip is equal |
| Process configuration | with a policy, `stdoutCaptureByteLimit` is 65,537 and `inheritEnvironment` is false; without a policy, the limit is nil |

`RuntimeStoreTests`: port
`testCommandFailureDiagnosticsPersistAsMetadataWithoutAcceptedOutput` from
`155f1145`. Another event type's metadata is not retained;
`command_failure_diagnostics` metadata is retained; `acceptedOutput` is nil;
the metadata survives Codable round trip.

## Verification commands

Run from the repository root. Logs go under
`tmp/issue-sweep-20261024/ISW-163/`, and each log ends with an
`echo exitStatus=$?` line:

```
arch -arm64 /bin/zsh -lc 'swift build > tmp/issue-sweep-20261024/ISW-163/build.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-163/build.log'
arch -arm64 /bin/zsh -lc 'swift test --filter CommandFailureDiagnosticsTests > tmp/issue-sweep-20261024/ISW-163/cfd.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-163/cfd.log'
arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowStdioNodeExecutorTests > tmp/issue-sweep-20261024/ISW-163/stdio.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-163/stdio.log'
arch -arm64 /bin/zsh -lc 'swift test --filter RuntimeStoreTests > tmp/issue-sweep-20261024/ISW-163/store.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-163/store.log'
arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet Sources/RielaCore/WorkflowFailureDiagnostics.swift Sources/RielaCore/WorkflowModel.swift Sources/RielaCore/RuntimeStore.swift Sources/RielaAdapters/LocalProcess.swift Sources/RielaAdapters/WorkflowStdioNodeExecutor.swift Tests/RielaAdaptersTests/CommandFailureDiagnosticsTests.swift Tests/RielaCoreTests/RuntimeStoreTests.swift > tmp/issue-sweep-20261024/ISW-163/lint.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-163/lint.log'
```

Every command must show exitStatus 0. Each test filter must show
`failureCount=0` with `testsRun` > 0. Lint must report no warnings in these
files.

## Edit discipline (shared working directory)

- Before each edit, re-read the target file and record its `shasum -a 256`.
  After the edit, record it again in the progress log.
- If a pre-edit hash differs from your last recorded post-edit hash, another
  writer changed the file. Stop, re-read, and re-apply your recorded intent
  only.
- A build failure in a file outside your writePaths is drift: retry once and
  record it. Do not edit that file.
- Do not run git commands that change the index or working tree (no add,
  commit, stash or checkout).

## Completion criteria

- [ ] All file-level changes are made. `git diff --stat` touches only the
      writePaths.
- [ ] Every test table row has a passing test.
- [ ] Build, the three filters and lint all pass, with the integer fields
      recorded.
- [ ] The README paragraph and the ported impl-plan record exist.

## Progress log expectations

`impl-plans/progress/issue-sweep-20261024-163-command-failure-diagnostics.md`
records per-edit hashes, commands, integer `exitStatus`/`testsRun`/`failureCount`,
log paths and any drift.
