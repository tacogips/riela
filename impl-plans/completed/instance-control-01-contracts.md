# Instance control 01: shared contracts (admission wire, reload DTOs, start record)

**Status**: Completed; accepted (code in checkpoint ca369733, recorded as acceptedDependency in `instance-control-dispatch.json`)
**planId**: instance-control-01-contracts
**dependsOn**: none (wave 1)
**Design Reference**: design-docs/specs/design-instance-reload-run-cli.md D4 steps 5, 6, 8 and the response shape; §5
**Issue**: none (request text in workflow input)
**Created**: 2026-11-10
**Evidence root**: tmp/instance-control/instance-control-01-contracts/

## Intent and context

Wave 1 pins every type and pure function that several wave-2 plans share, so they can work in parallel:

| Consumer plan | Uses |
| --- | --- |
| 05 (child gate) | admission frame/ack wire types |
| 06 (parent runtime) | the handle protocol method, the start record, the digest and fingerprint functions |
| 07 (CLI reload library) | the fingerprint function |
| 08 (coordinator) | the request/response DTOs, error codes, the respawn decision, the port protocol |

This plan writes types, pure functions and one forwarding method only. It contains no orchestration.

## Non-goals

- Do not send frames, launch processes or start/stop children (plans 05/06).
- Do not register routes or touch App glue (plan 09).
- Do not change the existing `RuntimeEnvironmentChannelFrame` or `RuntimeEnvironmentChannelAcknowledgement` encoding (`Sources/RielaAppSupport/RuntimeEnvironmentSnapshot.swift`). Do not edit that file.

## File-level changes

### Sources/RielaServer/WorkflowServeAdmission.swift (new)

Wire types for the admission barrier. They live in RielaServer so that RielaServer, RielaAppSupport and RielaCLI can all import them.

- `public enum WorkflowServeAdmissionWire`:
  - `controlTypes = ["admission-close", "admission-confirm", "admission-open"]`
  - `acknowledgementType = "admission-ack"`
  - `defaultLeaseSeconds = 120`
- `public struct WorkflowServeAdmissionFrame: Codable, Equatable, Sendable { var type: String; var requestId: String; var leaseSeconds: Int? }`
  - `encodedLine() throws -> Data`: sorted keys, newline-terminated, at most `RuntimeEnvironmentChannelWire.maxFrameBytes` (1 MiB). Hard-code `1_048_576` here, because RielaServer cannot import RielaAppSupport.
  - `static func decodeControlLine(_:) -> Self?`: returns nil unless `type` is one of `controlTypes`.
- `public enum WorkflowServeAdmissionState: String, Codable, Sendable { case open, closed, expired }`
- `public struct WorkflowServeAdmissionAcknowledgement: Codable, Equatable, Sendable { var type: String; var requestId: String; var state: WorkflowServeAdmissionState; var running: Int; var queued: Int }`
  - `static func decodeLine(_:) -> Self?`: returns nil unless `type == "admission-ack"`.
- `public enum WorkflowServeAdmissionError: Error, Equatable, Sendable { case unsupported, noAcknowledgement, childExited }`
- Pitfall: the frames carry no environment values or names. The ack carries only counts and state.

### Sources/RielaServer/WorkflowServingController.swift (edit)

- `WorkflowServeEventSourceHandle` gains `func admissionControl(_ frame: WorkflowServeAdmissionFrame) async throws -> WorkflowServeAdmissionAcknowledgement`.
  - Add a default implementation in the existing `public extension` that throws `WorkflowServeAdmissionError.unsupported`. Imitate `updateRuntimeEnvironment`'s default at lines 29-33.
- `WorkflowServingController` gains `public func admissionControl(_ frame:) async throws -> WorkflowServeAdmissionAcknowledgement`:
  - forwards to the single event-source handle of `activeGeneration`;
  - `activeGeneration == nil` → throws `WorkflowServeRuntimeEnvironmentError.noActiveGeneration`;
  - more than one handle → forward to each; return the first ack whose `state` is not `open` when the frame type is close, otherwise the last ack.
  - Imitate `updateRuntimeEnvironment` (lines 86-100). Do not mutate `activeGeneration` state.

### Sources/RielaAppSupport/RielaAppInstanceReloadContract.swift (new)

1. `public struct RielaAppInstanceReloadRequest: Codable, Equatable, Sendable { expectedProfile: String; expectedRevision: Int; reason: String; workflowDirectory: String?; interruptRunning: Bool }`.
   - Add `static func decodeStrict(_ body: Data) throws -> Self`:
     - body ≤ 65_536 bytes;
     - the key set is exactly the 5 keys (`workflowDirectory` must be present and may be `null`);
     - `reason` trimmed is 1–512 UTF-8 bytes;
     - a non-null `workflowDirectory` is absolute (starts with `/`), standardized, and contains no NUL byte.
   - Any violation throws `RielaAppInstanceReloadError(code: .invalidReloadRequest)`.
   - Imitate the exact-key check in `Sources/RielaApp/RielaAppConfiguredRunAPI.swift` (`Set(object.keys) == [...]`).
2. `public enum RielaAppInstanceReloadCode: String, Codable, Sendable` — the closed codes, each with its HTTP status:

   | Case | Wire string | HTTP |
   | --- | --- | --- |
   | `invalidReloadRequest` | `invalid_reload_request` | 400 |
   | `instanceNotFound` | `instance_not_found` | 404 |
   | `configurationConflict` | `configuration_conflict` | 409 |
   | `invalidWorkflowSource` | `invalid_workflow_source` | 422 |
   | `invalidWorkflowDefinition` | `invalid_workflow_definition` | 422 |
   | `workflowIdMismatch` | `workflow_id_mismatch` | 422 |
   | `invalidEventBindings` | `invalid_event_bindings` | 422 |
   | `instanceRunInFlight` | `instance_run_in_flight` | 409 |
   | `instanceHandoffUnavailable` | `instance_handoff_unavailable` | 409 |
   | `definitionConflict` | `definition_conflict` | 409 |
   | `definitionStoreFailure` | `definition_store_failure` | 500 |
   | `configurationIOFailure` | `configuration_io_failure` | 500 |
   | `instanceStartFailed` | `instance_start_failed` | 422 |
   | `instanceNotReady` | `instance_not_ready` | 422 |
   | `instanceBusy` | `instance_busy` | 409 |

   Expose `var httpStatus: Int`.
3. `public struct RielaAppInstanceReloadError: Error, Equatable, Sendable { code; message: String; committed: Bool; partial: String?; running: Int?; queued: Int? }`.
4. `public struct RielaAppInstanceReloadResponse: Codable, Equatable, Sendable`, with exactly these fields:
   - `profile`, `revision`, `identity`, `workflowId`, `workflowDirectory`, `sourceChanged`
   - `definition: Definition { outcome: String /* seeded|unchanged|forceUpdated */; versionId: String?; digest: String? }`
   - `eventBindings: EventBindings { respawnRequired: Bool; respawned: Bool }`
   - `handoff: String /* none|completed|interrupted|lost */`
   - `runtimeStatus: String`, `committed: Bool`
5. `public struct RielaAppInstanceStartRecord: Equatable, Sendable { workflowDirectory: String; eventRoot: String?; eventRootDigest: String; triggerDefaultsFingerprint: String }`.
6. `public enum RielaAppInstanceReloadFingerprint`, with three static functions:
   - `eventRootDigest(eventRoot: String?) throws -> String`
     - SHA-256 hex over each regular file under the event root, sorted by relative path. For each file feed `relativePath + "\0" + byteCount + "\0" + bytes`.
     - Symlinks and directories are skipped. Use `lstat` semantics: `URLResourceValues.isSymbolicLink`.
     - A nil or missing root gives the constant digest of the empty set.
   - `triggerDefaultsFingerprint(_ value: EventOverlapSettings?) -> String`
     - SHA-256 hex of the sorted-keys JSON encoding; `nil` hashes the literal `none`.
     - `EventOverlapSettings` is defined in `Sources/RielaCore/EventOverlapPolicy.swift`; `WorkflowModel.swift:548` uses it as `triggerDefaults`.
   - `respawnRequired(childRunning: Bool, installed: RielaAppInstanceStartRecord?, proposed: RielaAppInstanceStartRecord) -> Bool`
     - false when the child is not running;
     - true when the child is running and `installed == nil` (unknown baseline is treated as different, never as equal);
     - otherwise true iff any of the 4 fields differ.
     - **The store head is not a parameter** (DR-003).
7. `public protocol RielaAppInstanceReloadPorts: Sendable` (implemented by plan 09, faked by plan 08). Every method is `async`:
   - `currentInstance(identity:) -> RielaAppInstanceReloadInstance?`, where `RielaAppInstanceReloadInstance { identity; workflowId; sourceId; workflowDirectory; eventRoot: String? }`
   - `validateRevision(expectedRevision:expectedProfile:) throws`, which throws code `configurationConflict`
   - `discoverCandidate(instance:requestedDirectory:) throws -> RielaAppInstanceReloadCandidate`, where `RielaAppInstanceReloadCandidate { sourceId; workflowDirectory; eventRoot: String?; sourceChanged: Bool }`
   - `validate(candidate:instance:) throws -> RielaAppInstanceReloadValidated { workflowId; triggerDefaultsFingerprint; eventRootDigest }`
   - `installedStartRecord(identity:) -> RielaAppInstanceStartRecord?`, and `childRunning(identity:) -> Bool`
   - `admission(identity:frame:) throws -> WorkflowServeAdmissionAcknowledgement`
   - `importDefinition(candidate:reason:) throws -> RielaAppInstanceReloadResponse.Definition`
   - `relink(identity:candidate:) throws -> Int`, which returns the new revision
   - `refreshCache()`
   - `replaceChild(identity:interrupt:) throws -> String`, which returns the runtime status
   - `profile() -> String`, and `revision() -> Int`

   Keep signatures exactly as above. Plans 08 and 09 rely on them.

### Tests

**Tests/RielaAppSupportTests/RielaAppInstanceReloadContractTests.swift (new)** — imitate the XCTest style of `Tests/RielaAppSupportTests/RuntimeEnvironmentChannelProcessTests.swift`.

Request decoding:
- exact 5 keys → decodes.
- an extra key or a missing `workflowDirectory` key → `invalid_reload_request`.
- `reason` "  " → invalid; a 513-byte reason → invalid.
- a relative `workflowDirectory` → invalid.

Event-root digest:
- two temp dirs with the same files created in different order → equal digest.
- one byte changed → different digest.
- a symlink added → digest unchanged.
- a nil root equals a missing root.

Trigger-defaults fingerprint:
- nil vs `EventOverlapSettings` with a policy → different; the same value twice → equal.

`respawnRequired`:
- not running → false.
- running, installed nil → true.
- all fields equal → false.
- only `triggerDefaultsFingerprint` differs → true.
- only `eventRootDigest` differs → true.

`httpStatus` mapping for every code.

**Tests/RielaServerTests/WorkflowServeAdmissionTests.swift (new)**
- Frame `encodedLine` round-trips through `decodeControlLine`.
- `decodeControlLine` of a runtime-environment frame JSON (`{"generation":1,...}`) → nil.
- `Acknowledgement.decodeLine` of a `runtime-environment-ack` → nil.
- A controller with no active generation → `admissionControl` throws `noActiveGeneration`.
- A fake handle without an override → `unsupported`.

## Invariants

- No existing type, encoding or protocol requirement changes behaviour.
- The new protocol method has a default implementation, so every existing conformer compiles unchanged.
- RielaServer gains no dependency.

## Verification (each must exit 0; complete logs under the evidence root)

1. `mkdir -p tmp/instance-control/instance-control-01-contracts && arch -arm64 /bin/zsh -lc 'swift build 2>&1 | tee tmp/instance-control/instance-control-01-contracts/build.log; exit ${pipestatus[1]}'`
2. `arch -arm64 /bin/zsh -lc 'swift test --filter "RielaAppInstanceReloadContractTests|WorkflowServeAdmissionTests" 2>&1 | tee tmp/instance-control/instance-control-01-contracts/test.log; exit ${pipestatus[1]}'` — the log shows both classes ran with 0 failures.
3. `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet Sources/RielaServer/WorkflowServeAdmission.swift Sources/RielaServer/WorkflowServingController.swift Sources/RielaAppSupport/RielaAppInstanceReloadContract.swift Tests/RielaAppSupportTests/RielaAppInstanceReloadContractTests.swift Tests/RielaServerTests/WorkflowServeAdmissionTests.swift 2>&1 | tee tmp/instance-control/instance-control-01-contracts/lint.log; exit ${pipestatus[1]}'`

Record the integer exit status, testsRun and failureCount for each in the progress log.

## Edit safety

- Fresh-read every file before editing, and record the pre- and post-edit sha256 in the progress log.
- `WorkflowServingController.swift` is touched only by this plan. On drift, re-apply only the two additions.
- Never stage, commit, stash or reset.

## Completion criteria

- [x] All symbols above exist with the exact names and signatures.
- [x] Verification 1–3 exit 0, with log paths recorded.
- [x] Progress log updated.

## Progress Log

### Session: 2026-11-10
Plan authored (Opus). Not started.

### Implementation: 2026-11-10

Implemented admission wire and controller forwarding, strict reload contracts, fingerprints and ports, with focused tests. This is a moving shared tree; formal review and serial integration remain downstream.

- Build: `arch -arm64 /bin/zsh -lc 'swift build 2>&1 | tee tmp/instance-control/instance-control-01-contracts/build.log; exit ${pipestatus[1]}'` — exit 0, tests 0, failures 0.
- Tests: `arch -arm64 /bin/zsh -lc 'export HOME="$PWD/tmp/instance-control/instance-control-01-contracts/home" RIELA_APP_ROOT="$PWD/tmp/instance-control/instance-control-01-contracts/app"; swift test --filter "RielaAppInstanceReloadContractTests|WorkflowServeAdmissionTests" 2>&1 | tee tmp/instance-control/instance-control-01-contracts/test.log; exit ${pipestatus[1]}'` — exit 0, 5 tests, 0 failures.
- Plan selected-file lint: `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet Sources/RielaServer/WorkflowServeAdmission.swift Sources/RielaServer/WorkflowServingController.swift Sources/RielaAppSupport/RielaAppInstanceReloadContract.swift Tests/RielaAppSupportTests/RielaAppInstanceReloadContractTests.swift Tests/RielaServerTests/WorkflowServeAdmissionTests.swift 2>&1 | tee tmp/instance-control/instance-control-01-contracts/lint.log; exit ${pipestatus[1]}'` — exit 0, tests 0, failures 0.
- Strict lint through `tmp/instance-control/instance-control-01-contracts/changed-swift.nul`: exit 0, log `tmp/instance-control/instance-control-01-contracts/lint-strict.log`, tests 0, failures 0. The first lint attempt found trailing whitespace; it was corrected before final checks.
- Pre-edit SHA-256: `WorkflowServingController.swift` 2371722538ef1fc515213c24651f76e46be06b84c73a1e799fb29a45d46a8ed9; this plan 2af14f8548b07b8abcf61e1c9729e6bbaf3d24bb98e6e0469721325a7e0df44a; four new Swift files absent. Full pre/post source hashes and per-edit intentions are recorded in `tmp/instance-control/instance-control-01-contracts/`.
- Post-edit SHA-256: `WorkflowServeAdmission.swift` 6f8d0e60b71147477efddb4d42d2e375b4e15010adec3a88197f7427d41e93e4; `WorkflowServingController.swift` ba8053c03a5ddc8e51186ea75d2c98a852d206635211bd00983f1e62895ad306; `RielaAppInstanceReloadContract.swift` 946e5c5340306ae7126b069aa6ce2fd9ae851bbea853ab37c47936fca9f631de; `RielaAppInstanceReloadContractTests.swift` 9c0b0b99c8dabfe62de0eb816bdcbaedf1e382ff66c2c131afb46feebc5b5f12; `WorkflowServeAdmissionTests.swift` b2cfe5ee589b5e7d4061d1d1f58a810ea6a9c5a1bfb378507ec7afd708b1dcb9.
