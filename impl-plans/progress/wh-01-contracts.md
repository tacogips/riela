# wh-01-contracts progress

- **Plan:** `wh-01-contracts` (`impl-plans/active/wh-01-contracts.md`)
- **Workflow mode:** `issue-resolution`; dispatch branch `wh-01-contracts`; execution `nested-v1-52fa3b7895fc6123ecccd25efadcea66bdf2ea1346e350f193852aa64a29895c`
- **Branch:** `feat/work-handover-and-takeover`; starting checkpoint `5e5596b08703cefe3f26689091959b114fd23cd8`; no Git state mutation.
- **Issue:** no GitHub issue supplied; design/spec `design-docs/specs/design-work-handover-and-takeover.md`, umbrella `impl-plans/active/work-handover-and-takeover.md`.
- **Codex-agent references:** none supplied.
- **Accepted design/plan:** runtime records unchanged acceptance at HEAD `6e18f9f5`, Step 5 review `comm-002964` in `opus-luna-design-and-implement-review-loop-session-231`, decision `accept`, findings `[]`.

## Implementation

Implemented the wh-01 contract types and strict tagged enum Codable forms in `Sources/RielaCore/HandoverContracts.swift` and `Sources/RielaWork/WorkHandover.swift`; canonical JSON/date/hash behavior in `Sources/RielaCore/JSONCanonical.swift`; suspended session/event/workflow/host-trait/deliverable models; Work Runtime decision, evidence, attempt, lease, and policy cases; schema generation 9, generated fence and new handover tables/indexes; canonical handover CRUD and atomic `sealHandoverRecords`; reserved envelope validation, git branch producer detection, and local memory/KV warning. Updated the work-task fixture and Codable tests.

Sink mirror refs update only `record.sinks`; `HandoverPacket.canonicalDigest()` deliberately excludes sinks, so the stable packet digest remains verifiable after mirror publication. Store reads verify the stored digest against both the packet field and recomputed canonical digest. Tests cover tamper detection and atomic rollback/success.

### Completion criteria

- [x] Every wh-01 contract type and new enum case has Codable round-trip coverage; envelope validation, strict decoding, host trait normalization, canonical JSON/date/hash, and unknown tagged cases are covered by the new contract tests.
- [x] Session schema generation 9, `work_handovers`, `work_handover_requests`, lease heartbeat/expiry/fence/host columns, task fence, indexes, and `tableNames` are implemented and tested.
- [x] `sealHandoverRecords` runs in one transaction; version-conflict no-write and successful task/attempt/lease/decision/evidence effects are tested.
- [x] Current-source build, focused tests, exact changed-file strict SwiftLint, and `git diff --check` pass. Exhaustive-switch edits and hashes are listed below and in `tmp/work-handover/wh-01-contracts/final-source-sha256.txt`.

## Exhaustive-switch edits / downstream seams

These compile/model integration edits were limited to handling the newly introduced enum cases. File hashes are in the final source inventory cited above.

- `Sources/RielaCore/RuntimeStore.swift:541-542,837-838`: persist suspended status from a suspended step and keep suspended step status nonterminal.
- `Sources/RielaCore/SessionObservability.swift:533-535,546-548` and `Sources/RielaCLI/SpecialistCommands.swift:556`: suspended sessions remain pending/nonterminal.
- `Sources/RielaCore/DeterministicWorkflowRunner+Events.swift:174-175,208`: accept handover events without inventing telemetry completion behavior.
- `Sources/RielaCLI/WorkflowRunLivePersistence.swift:189`: include handover events in live session persistence.
- `Sources/RielaWork/DecisionApplier.swift:94-99`: handover/answer/takeover decisions are routed to handover store APIs.
- `Sources/RielaWork/WorkStore+Reservation.swift:692-694`: temporary `.resume` mapping documents that wh-03's handover coordinator persists the typed takeover decision.
- `Sources/RielaCLI/TaskDispatch.swift:583-584`: explicit error until wh-14 resolves takeover packet resume-step dispatch.
- `Sources/RielaCLI/RielaCommand.swift:20`: `CLIExitCode.suspended = 5`.

The wh-03 coordinator and wh-14 takeover resume-step behavior remain owned by those downstream plans. These seams are not wh-01 omissions.

## Pre-review verification (superseded after integrity review)

1. `arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-01-contracts/build-final-3.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-01-contracts/build-final-3.log'` — **exit=0**, build complete.
2. `arch -arm64 /bin/zsh -lc 'swift test --filter "HandoverContractsTests|JSONCanonicalTests|WorkHandoverModelsTests|WorkStoreHandoverRecordsTests|WorkModelsCodableTests|WorkStoreTests|WorkStoreReservationTests|DeterministicDirectorTests|RuntimeStoreTests|WorkflowValidation" > tmp/work-handover/wh-01-contracts/focused-final-3.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-01-contracts/focused-final-3.log'` — **exit=0**, 120 tests, 120 passed, 0 failures.
3. `arch -arm64 /bin/zsh -lc 'changed_swift_manifest=tmp/work-handover/wh-01-contracts/changed-swift-files.nul; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\n" "No Swift files changed; selected-file SwiftLint not run."; fi > tmp/work-handover/wh-01-contracts/swiftlint-final-3.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-01-contracts/swiftlint-final-3.log'` — **exit=0**; exact changed Swift files are NUL-delimited in `tmp/work-handover/wh-01-contracts/changed-swift-files.nul`.
4. `git diff --check` — **exit=0**.

### Earlier attempts retained

All attempts and complete logs remain under `tmp/work-handover/wh-01-contracts/`. Initial build logs `build.log`, `build-retry-1.log`, and `build-retry-2.log` captured compile errors while adding the new switches/private storage; `build-retry-3.log` passed before later digest/lint/test changes. Focused logs `focused-attempt-1.log` through `focused-attempt-8.log` captured test compilation and assertion corrections; `focused-attempt-9.log` passed 120 tests before the later canonical digest and round-trip-coverage edits. `build-final.log` and `focused-final.log` passed before SwiftLint cleanup; `swiftlint-final.log` found only tuple-size, UTF-8 conversion, and switch alignment diagnostics. Those were corrected, then `build-final-3.log`, `focused-final-3.log`, and `swiftlint-final-3.log` passed before the integrity review. The review reproduced two adjacent-suite failures, now fixed and verified below.

## Integrity review repair — communication `comm-002970`

Both mid findings are addressed without relaxing strict decoding or suppressing the required validator warning. The accepted plan says distributed registration traits decode strictly; the valid registration test now carries `"traits":[]` and asserts decoding fails when that required key is absent. The producer-walk test now asserts there are no error diagnostics and that the expected memory/KV warning is present.

The two review-directed test paths are justified writePaths amendments for this plan because the current source changes made their previous assertions stale and the review reproduced unowned, non-baseline failures:

| Amended write path | Pre-edit SHA-256 | Post-edit SHA-256 | Intent/preimage evidence |
| --- | --- | --- | --- |
| `Tests/RielaCLITests/DistributedWorkerConfigurationTests.swift` | `7a49e59c51a95f3c870a84cccd697c10c6032cb3f765a5e99c05de3a05d58b7d` | `67f2549977001a583a6472a548710bf705db8d088430d4731e0e4d1cb28bc126` | `tmp/work-handover/wh-01-contracts/attempt-02/edit-adjacent-regressions/intent.txt` and `.pre` |
| `Tests/RielaCoreTests/AgentNodeOutputContractValidationTests.swift` | `350908d56398bbbb502cd4ff5bfb6d8a30140be2d2d30017b99b2cd52f431b5e` | `3d6f27a7489d1fb6818dab98dcfbe017ed65c14bebf8705896e2f8d52d26b6ab` | `tmp/work-handover/wh-01-contracts/attempt-02/edit-adjacent-regressions/intent.txt` and `.pre` |

Progress-log update preimage and intent: `tmp/work-handover/wh-01-contracts/attempt-02/edit-progress-update/`. Prior source inventory retained at `tmp/work-handover/wh-01-contracts/attempt-01/final-source-sha256.txt`.

### Final-source verification after review repair

1. `arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-01-contracts/build-review-repair.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-01-contracts/build-review-repair.log'` — **exit=0**, build complete.
2. `arch -arm64 /bin/zsh -lc 'swift test --filter "HandoverContractsTests|JSONCanonicalTests|WorkHandoverModelsTests|WorkStoreHandoverRecordsTests|WorkModelsCodableTests|WorkStoreTests|WorkStoreReservationTests|DeterministicDirectorTests|RuntimeStoreTests|WorkflowValidation|DistributedWorkerConfigurationTests|AgentNodeOutputContractValidationTests" > tmp/work-handover/wh-01-contracts/focused-review-repair.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-01-contracts/focused-review-repair.log'` — **exit=0**, 136 tests, 136 passed, 0 failures; includes both previously failing adjacent suites.
3. `arch -arm64 /bin/zsh -lc 'changed_swift_manifest=tmp/work-handover/wh-01-contracts/changed-swift-files.nul; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\n" "No Swift files changed; selected-file SwiftLint not run."; fi > tmp/work-handover/wh-01-contracts/swiftlint-review-repair.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-01-contracts/swiftlint-review-repair.log'` — **exit=0**; updated nonempty manifest has 34 Swift paths, including both amendments.
4. `git diff --check` — **exit=0**.

Review reproduction logs `tmp/work-handover/wh-01-contracts/step6-review/adjacent-suites.log` and `core-work-modules.log` remain as failed pre-repair evidence; the expanded current-source rerun passed both tests. No review finding remains unresolved.

## Final source hashes

SHA-256 for all 35 changed source/test/fixture files (including both authorized test-path amendments and shared exhaustive-switch edits) is recorded in `tmp/work-handover/wh-01-contracts/final-source-sha256.txt`. The plan-local preimages and per-edit intentions are in `tmp/work-handover/wh-01-contracts/attempt-01/` and `attempt-02/`; no scratch artifact is tracked.

## Handoff state

The wh-01 implementation and required behavioral verification are complete. Keep `impl-plans/active/wh-01-contracts.md` active for downstream workflow review/finalization; no adversarial review, shared documentation/index refresh, staging, commit, or push is claimed here.
