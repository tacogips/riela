# Instance control 08: reload coordinator (validate → barrier → commit → replace), port-driven

**Status**: Planned
**planId**: instance-control-08-reload-coordinator
**dependsOn**: instance-control-01-contracts (`RielaAppInstanceReloadPorts`, request/response/error types, `respawnRequired`, admission wire types)
**Design Reference**: design-docs/specs/design-instance-reload-run-cli.md D4 steps 1–9 and the response; §5 orchestration cases
**Created**: 2026-11-10
**Evidence root**: tmp/instance-control/instance-control-08-reload-coordinator/

## Intent and context

The reload algorithm must be deterministic and fully testable with fakes. It lives in RielaAppSupport as a pure orchestrator over `RielaAppInstanceReloadPorts` (defined by plan 01). Plan 09 implements the ports against the real App, runtime and store.

## Non-goals

- No HTTP parsing or response encoding (plan 09). No AppKit.
- No direct file, store or process access. Everything goes through the ports.

## File-level changes

### Sources/RielaAppSupport/RielaAppInstanceReloadCoordinator.swift (new)

`public struct RielaAppInstanceReloadCoordinator: Sendable`:
- `init(ports: any RielaAppInstanceReloadPorts, makeRequestId: @Sendable () -> String = { UUID().uuidString.lowercased() })`
- `func reload(identity: String, request: RielaAppInstanceReloadRequest) async -> Result<RielaAppInstanceReloadResponse, RielaAppInstanceReloadError>`

Implement exactly this order. Every rejection before step 7 carries `committed:false`; every failure from 7.1 onward carries `committed:true`.

1. `validateRevision`. Then `currentInstance(identity)`; nil → `instanceNotFound`.
2. `discoverCandidate(instance, requestedDirectory: request.workflowDirectory)`. Its errors propagate as `invalidWorkflowSource`.
3–4. `validate(candidate, instance)` → `validated` (errors propagate with their codes).
5. `proposed = RielaAppInstanceStartRecord(workflowDirectory: candidate.workflowDirectory, eventRoot: candidate.eventRoot, eventRootDigest: validated.eventRootDigest, triggerDefaultsFingerprint: validated.triggerDefaultsFingerprint)`.
   `needsRespawn = RielaAppInstanceReloadFingerprint.respawnRequired(childRunning: await ports.childRunning(identity), installed: await ports.installedStartRecord(identity), proposed: proposed)`.
6. If `needsRespawn`:
   - `rid = makeRequestId()`. Send `admission(identity, frame(type:"admission-close", requestId: rid, leaseSeconds: 120))`.
   - Throws `unsupported`, `noAcknowledgement` or `childExited`:
     - best-effort `admission-open` (ignore its error);
     - if `!request.interruptRunning` → `instanceHandoffUnavailable`, committed false;
     - otherwise continue with `barrier = .none` and handoff mode `interrupted`.
   - Ack with `running + queued > 0`:
     - `!interruptRunning` → send `admission-open`, then return `instanceRunInFlight` with `running`/`queued` set and committed false;
     - otherwise keep the barrier closed, handoff mode `interrupted`.
   - Ack idle → barrier held, handoff mode `completed`.
7. Commit:
   1. `definition = try await ports.importDefinition(candidate, reason)`.
      - On error: if a barrier is held, send `admission-open`; return the error with committed false. Nothing was written by us; plan 07 guarantees this for `definitionConflict`.
   2. If `candidate.sourceChanged`: `revision = try await ports.relink(identity, candidate)`.
      - On error: if a barrier is held, send `admission-open` and do **not** replace the child.
      - Return `configurationIOFailure` with committed true and `partial: "definition"`.
   3. `await ports.refreshCache()`.
8. If `needsRespawn`:
   1. If the barrier is held, send `admission-confirm` with `rid`:
      - an ack with `state == .closed && running == 0 && queued == 0`, or with `interruptRunning` true → proceed;
      - anything else (expired, counts > 0, throw):
        - **do not call `replaceChild`**;
        - send `admission-open` best-effort;
        - return success with `handoff: "lost"`, `eventBindings.respawned: false`, committed true.
        - Pitfall: this is a successful HTTP 200 per the design. The CLI maps it to exit 1.
   2. `runtimeStatus = try await ports.replaceChild(identity, interrupt: request.interruptRunning)`.
      - `instanceNotReady`/`instanceStartFailed` errors → return them with committed true.
      - Success → handoff `completed` (or `interrupted`), `respawned: true`.
9. No respawn: handoff `"none"`, `respawned:false`; `runtimeStatus` is the runtime's current status. Add a small port call if needed. To keep the plan 01 port set stable, use `replaceChild` only for respawn and report `runtimeStatus` as `"running"` when `childRunning` was true, else `"stopped"`.
10. Fill the response:
    - `profile` and `revision` from the ports, after relink;
    - `identity`, `workflowId` (`validated.workflowId`), `workflowDirectory` (`candidate.workflowDirectory`), `sourceChanged`;
    - `definition`, `committed: true`.

## Key pitfalls

- Never call `replaceChild` while the barrier is open, unless `interruptRunning` is true.
- Never call `importDefinition` before the barrier decision in step 6.
- Every early return while the barrier is held must send `admission-open`. Use one helper so no path is forgotten.
- The coordinator must not consult execution history. The ports offer no such method.
- Never send `admission-*` frames on a definition-only reload.

## Tests

**Tests/RielaAppSupportTests/RielaAppInstanceReloadCoordinatorTests.swift (new)** — a fake ports actor records every call in order and lets each test script the responses.

| # | Situation | Expected |
| --- | --- | --- |
| 1 | Definition-only change (installed == proposed except no difference; child running with an active run) | 200, `handoff:none`, **no admission frames**, no `replaceChild`; `importDefinition` called once |
| 2 | Bindings digest differs, ack running 1, no interrupt | 409 `instance_run_in_flight`, `committed:false`, calls = [close, open]; no import, no relink, no replace |
| 3 | Active work beyond history: installed record differs, ack `running:1` (the fake has no history API at all) | 409. This proves the decision uses only the child counts |
| 4 | Admission throws `unsupported` with no interrupt | 409 `instance_handoff_unavailable`, no import |
| 5 | Interrupt true, ack running 1 | import → refresh → confirm → replace; `handoff:interrupted`, `respawned:true` |
| 6 | Confirm returns `expired` | 200 `handoff:lost`, `respawned:false`, `committed:true`; **replaceChild never called**; open sent |
| 7 | **triggerDefaults-only lost-handoff recovery** (DR-003), see below | as below |
| 8 | Import throws `definitionConflict` while the barrier is held | open sent, `committed:false`, no relink, no replace |
| 9 | Relink throws | `configuration_io_failure`, `committed:true`, `partial:"definition"`, open sent, no replace |
| 10 | `replaceChild` throws `instanceStartFailed` | `committed:true`; record unchanged (the fake does not advance it) |
| 11 | Validate throws `invalidEventBindings` | no admission, no import (call log contains only revision, currentInstance, discover, validate) |
| 12 | Unknown instance | `instance_not_found` |

Detail for case 7 (DR-003): installed A = {dir, root, digest D, fp TA}; proposed = {dir, root, D, TB}.
- First reload: confirm → expired → `handoff:lost`; the fake installed record stays A.
- Second reload with the same proposed values: `respawnRequired` is still true; import returns `unchanged`; the confirm ack is closed/idle; `replaceChild` succeeds and the fake now installs B.
- Third reload: no respawn and no admission frames.

## Verification

1. `mkdir -p tmp/instance-control/instance-control-08-reload-coordinator && arch -arm64 /bin/zsh -lc 'swift test --filter "RielaAppInstanceReloadCoordinatorTests|RielaAppInstanceReloadContractTests" 2>&1 | tee tmp/instance-control/instance-control-08-reload-coordinator/test.log; exit ${pipestatus[1]}'` — 0 failures, with 12+ tests run.
2. `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet Sources/RielaAppSupport/RielaAppInstanceReloadCoordinator.swift Tests/RielaAppSupportTests/RielaAppInstanceReloadCoordinatorTests.swift 2>&1 | tee tmp/instance-control/instance-control-08-reload-coordinator/lint.log; exit ${pipestatus[1]}'`

## Edit safety

- New files only; single owner. Fresh-read and record sha256.
- If the plan 01 port signatures turn out insufficient, **do not edit plan 01 files**. Record a blocker in the progress log for serial repair.

## Completion criteria

- [ ] Coordinator implemented in this order.
- [ ] Tests 1–12 pass.
- [ ] Lint exits 0.
- [ ] Progress log written.

## Progress Log

### Session: 2026-11-10
Plan authored (Opus). Not started.
