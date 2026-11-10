# Instance control 06: parent admission port, installed start record, child replacement primitives

**Status**: Planned
**planId**: instance-control-06-parent-admission-runtime
**dependsOn**: instance-control-01-contracts (admission wire types, `WorkflowServingController.admissionControl`, `RielaAppInstanceStartRecord`, `RielaAppInstanceReloadFingerprint`)
**Design Reference**: design-docs/specs/design-instance-reload-run-cli.md D4 steps 5 (installed start record, record-advance rule), 6 (parent sequence), 8 (confirm, replace)
**Created**: 2026-11-10
**Evidence root**: tmp/instance-control/instance-control-06-parent-admission-runtime/

## Intent and context

The App supervises event children through:
- `RielaAppDaemonWorkflowRuntime` (`Sources/RielaAppSupport/DaemonWorkflowSupport.swift`), which keeps `runningWorkflows`, and its `startController`, `start` and `refresh`;
- the process layer `Sources/RielaAppSupport/DaemonWorkflowEventServeProcess.swift`, which provides `EventServeSourceHandle`, `FoundationEventServeProcessHandle` and the stdin channel writes plus ack parsing (around lines 500-540).

This plan adds:
1. sending admission frames to a child and awaiting its `admission-ack`;
2. an **installed start record** per running child. It is written only after a successful start, so the reload decision (plan 08) compares against what the child really runs (fix DR-003);
3. runtime methods the App glue (plan 09) calls: `admissionControl`, `installedStartRecord`, `isChildRunning`, `replaceChild`.

## Non-goals

- No reload orchestration (plan 08) and no HTTP route (plan 09).
- No change to environment-reload semantics.
- Do not always enable the channel. Children without it (no `runtimeEnvironmentGeneration`, `DaemonWorkflowSupport.swift:~1050`) report admission `unsupported`.

## File-level changes

### Sources/RielaAppSupport/DaemonWorkflowEventServeProcess.swift

- `RielaAppDaemonEventServeProcessHandle` gains `func admissionControl(_ frame: WorkflowServeAdmissionFrame) async throws -> WorkflowServeAdmissionAcknowledgement`, with a default that throws `WorkflowServeAdmissionError.unsupported`.
- `FoundationEventServeProcessHandle` implements it:
  - It needs `inputPipe != nil`; otherwise `unsupported`. A child that is not running → `childExited`.
  - Write `frame.encodedLine()` under the same write-serialization used by `updateRuntimeEnvironment` (`frameWriteInProgress`). Admission writes and env writes must not interleave bytes.
  - Wait for an ack line where `WorkflowServeAdmissionAcknowledgement.decodeLine` succeeds and `requestId` matches. Time out after 5 s → `noAcknowledgement`.
  - The stdout line parser (around line 520) must try `RuntimeEnvironmentChannelAcknowledgement.decodeLine` **and** `WorkflowServeAdmissionAcknowledgement.decodeLine`. Each matches only its own `type`. Store admission acks in a dictionary keyed by requestId. Pending waits use continuations or poll; reuse the existing env-ack waiting pattern in the file.
  - Never log frame or ack contents beyond type, state and counts.
- `EventServeSourceHandle` (around line 329) forwards `admissionControl` to its process handle. This satisfies the RielaServer protocol method from plan 01.

### Sources/RielaAppSupport/DaemonWorkflowSupport.swift

- `RielaAppDaemonWorkflowRuntime`: add `public typealias StartRecordProvider = @Sendable (RielaAppDaemonWorkflowCandidate, String /* sessionStoreRoot */) -> RielaAppInstanceStartRecord?`.
  - Add init parameter `startRecordProvider: StartRecordProvider? = nil`; existing call sites are unchanged.
  - Add `public func setStartRecordProvider(_:)` so the App can install it after init.
- `RunningWorkflow` gains `var startRecord: RielaAppInstanceStartRecord?` and `var pendingStartRecord: RielaAppInstanceStartRecord?`.
- In `startController`:
  - compute `pendingStartRecord = provider?(candidate, sessionStoreRoot)` **before** `controller.start(...)`;
  - after the controller reports a running state, set `startRecord = pendingStartRecord`.
  - On a failed start, leave the previous entry's `startRecord` value in place. A replacement entry inherits the old `startRecord` until it succeeds: copy it from the previous `runningWorkflows[candidate.id]` before overwriting the entry.
  - This covers initial start, the `start`/`restart` actions and monitor `refresh` restarts.
- New public methods:
  - `installedStartRecord(identity:) -> RielaAppInstanceStartRecord?`
  - `isChildRunning(identity:) -> Bool`: true when the snapshot status is `.running` or `.starting` and the candidate starts event sources.
  - `admissionControl(identity:frame:) async throws -> WorkflowServeAdmissionAcknowledgement`: forwards to the running entry's `controller.admissionControl(frame)`. No entry → `childExited`.
  - `replaceChild(_ candidate:configuration:server:sessionStoreRoot:) async -> RuntimeSnapshot`:
    - `await stop(identity: candidate.id)`, then `await start(candidate, configuration:, server:, sessionStoreRoot:)`, returning `snapshot(for:)`.
    - Do **not** clear `startRecord` in `stop`. Keep a side map `lastInstalledStartRecord[identity]` that `stop` preserves and only a successful start overwrites, so `installedStartRecord` stays answerable while stopped.

## Key pitfalls

- The record must not advance on failure: a lost handoff, a failed start, or `partial`.
- `installedStartRecord` returns the last successfully installed record even while the child is restarting.
- Do not change port allocation, monitor scheduling or environment-generation bookkeeping.

## Tests

**Tests/RielaAppSupportTests/DaemonAdmissionRuntimeTests.swift (new)** — imitate the fake launcher/process handles in `Tests/RielaAppSupportTests/RuntimeEnvironmentChannelProcessTests.swift` and `DaemonRuntimeEnvironmentTests.swift`.

| Situation | Expected |
| --- | --- |
| Fake process with stdin/stdout pipes echoing `admission-ack` for the requestId | `admissionControl` returns the ack |
| An ack for a different requestId, then the matching one | the matching one is returned |
| No ack within 5 s (injectable timeout) | `noAcknowledgement` |
| Child without an input pipe | `unsupported` |
| Interleaving: env reload frame and admission frame sent concurrently | each line is a valid JSON object; no byte interleaving |
| Start with a provider returning record A | `installedStartRecord == A` |
| `replaceChild` with provider B, where start fails (fake controller failure) | record stays A |
| `replaceChild` with provider B, where start succeeds | record becomes B |
| `stop` | the record is still A |

## Verification

1. `mkdir -p tmp/instance-control/instance-control-06-parent-admission-runtime && arch -arm64 /bin/zsh -lc 'swift test --filter "DaemonAdmissionRuntimeTests|RuntimeEnvironmentChannelProcessTests|DaemonRuntimeEnvironmentTests|RuntimeEnvironmentReloadSafetyTests|DaemonWorkflowSupportTests" 2>&1 | tee tmp/instance-control/instance-control-06-parent-admission-runtime/test.log; exit ${pipestatus[1]}'` — 0 failures.
2. `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet Sources/RielaAppSupport/DaemonWorkflowEventServeProcess.swift Sources/RielaAppSupport/DaemonWorkflowSupport.swift Tests/RielaAppSupportTests/DaemonAdmissionRuntimeTests.swift 2>&1 | tee tmp/instance-control/instance-control-06-parent-admission-runtime/lint.log; exit ${pipestatus[1]}'`

## Edit safety

- Fresh-read before each edit; record the pre- and post-edit sha256.
- Both source files are owned only by this plan. On drift, re-apply only these additions.

## Completion criteria

- [ ] Port and record implemented.
- [ ] Tests pass.
- [ ] Lint exits 0.
- [ ] Progress log written.

## Progress Log

### Session: 2026-11-10
Plan authored (Opus). Not started.
