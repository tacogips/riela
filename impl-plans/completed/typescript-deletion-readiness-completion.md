# TypeScript Deletion Readiness Completion Implementation Plan

**Status**: Completed - TypeScript sources removed; deletion gate accepted with reviewed-tree evidence
**Design Reference**: `design-docs/specs/design-swift-native-migration.md#deletion-readiness-completion-pass`
**Workflow Mode**: issue-resolution
**Issue Reference**: Complete Riela TypeScript deletion readiness after accepted Swift parity workflow
**Target Feature Area**: Riela TypeScript deletion gate and remaining TS file removal
**Review Mode**: adversarial, high risk
**Created**: 2026-06-16
**Last Updated**: 2026-06-16

## Summary

Complete the deletion-readiness pass after pushed workflow commit
`3f19b642303d14299bfe47f5bee371abcd2a2f4e` and cleanup commit `1858103`.
The prior Swift parity work is accepted as parity evidence. After the
adversarial reviewed-tree evidence revision, the checked-in gate authorizes
deletion: `packaging/swift-deletion-readiness.json` has
`migrationStatus=deletion_ready`, `allowsTypeScriptDeletion=true`,
`typeScriptSourceDeletionReady=true`, all required domains
`reviewDecision=accepted`, and accepted adversarial review metadata.

This plan is a gate-completion and TypeScript-family source-removal plan. It
must not create new parity scope, silently alias `official/cursor-sdk` to
`cursor-cli-agent`, publish release artifacts, mutate the Homebrew tap, or mark
TypeScript deletion ready before current evidence and ordinary plus adversarial
review acceptance are recorded.

## Source Of Truth

- Design: `design-docs/specs/design-swift-native-migration.md`
- Gate manifest: `packaging/swift-deletion-readiness.json`
- Evidence manifest: `packaging/swift-deletion-readiness-evidence.json`
- Cutover manifest: `packaging/homebrew/swift-cutover-gates.json`
- Active parity context: `impl-plans/active/swift-cli-runtime-parity-gap-closure.md`
- Reference repository root: `/Users/taco/gits/tacogips/rielflow`

## Codex And Agent References

- `codex-agent`:
  `/Users/taco/gits/tacogips/rielflow/packages/rielflow/src/workflow/adapters/codex.test.ts`
- `codex-agent` readiness framing:
  `/Users/taco/gits/tacogips/rielflow/packages/rielflow/src/workflow/runtime-readiness-agent-probes.ts`
- `claude-code-agent`:
  `/Users/taco/gits/tacogips/rielflow/packages/rielflow/src/workflow/adapters/claude.test.ts`
- `cursor-cli-agent`:
  `/Users/taco/gits/tacogips/rielflow/packages/rielflow/src/workflow/adapters/cursor.test.ts`
- `cursor-cli-agent` readiness framing:
  `/Users/taco/gits/tacogips/rielflow/packages/rielflow/src/workflow/runtime-readiness-agent-probes.ts`

Intentional divergence: Swift owns these integrations through SwiftPM targets
instead of importing npm packages. Backend identifiers and normalized adapter
contracts stay compatible. `official/cursor-sdk` remains a distinct backend and
is not satisfied by `cursor-cli-agent` evidence.

## Tasks

### TASK-001: Current Evidence And Gate Audit

**Status**: COMPLETED

**Deliverables**:

- Audit notes in this plan progress log.
- No production manifest mutation until TASK-003.

**Work**:

- Confirm `packaging/swift-deletion-readiness.json`,
  `packaging/swift-deletion-readiness-evidence.json`, and
  `packaging/homebrew/swift-cutover-gates.json` are valid JSON.
- Compare every required deletion domain against current branch, commit,
  evidence command, evidence artifact, workflow id, review node id, and finding
  severities.
- Identify stale values from commit `184e15a03074cf087374399ea16377355ad22b3a`
  or any prior parity run.
- Confirm current remaining TypeScript-family files and classify each as
  delete, port, or explicitly retain with a reviewed reason.

**Dependencies**: Accepted Step 3 design review.

**Completion criteria**:

- Every gate blocker is enumerated before implementation mutates manifests.
- No stale or self-attested evidence is carried forward without fresh command
  result metadata.

### TASK-002: Replace Or Remove Remaining TypeScript-Family Sources

**Status**: COMPLETED

**Deliverables**:

- Replacement or deletion for `scripts/check-source-filenames.ts`.
- Replacement or deletion for `scripts/check-source-filenames.test.ts`.
- Replacement or deletion for `scripts/sync-package-declarations.ts`.
- Replacement or deletion for `scripts/audit-chat-redaction-literals.ts`.
- Removal or relocation of scratch-style `scripts/_compute-digest-temp.mjs`
  into `tmp/` if ad-hoc use is still needed.
- Native, shell, or static-fixture replacement for
  `examples/telegram-agent-trio-time-signal/scripts/prepare-time-signal.ts`.
- Tests or verification commands replacing each removed TypeScript guard.

**Work**:

- Preserve root `src/` and forbidden `part-<digits>.ts(x)` filename policy
  through Swift tests, shell checks, or committed non-TypeScript tooling.
- Remove declaration sync only if TypeScript declaration artifacts are no
  longer shipped; otherwise replace sync behavior before deletion.
- Preserve redaction literal audit coverage before deleting the TypeScript
  audit script.
- Preserve the Telegram time-signal example's user-facing behavior without
  requiring a TypeScript runtime.
- Keep throwaway conversion artifacts under `tmp/`.

**Dependencies**: TASK-001 classification.

**Completion criteria**:

- `rg --files | rg '\\.(ts|tsx|mts|cts|mjs)$'` returns no deletion-blocking
  TypeScript-family source, or every remaining hit is explicitly documented as
  not part of the deleted runtime surface.
- Replacement tests or shell checks cover the behavior previously protected by
  the removed scripts.

### TASK-003: Refresh Deletion-Readiness Evidence

**Status**: COMPLETED

**Deliverables**:

- Updated `packaging/swift-deletion-readiness-evidence.json`.
- Updated command-result artifact references that resolve by domain id, command,
  branch, commit, workflow id, and review node id.
- Updated notes in `impl-plans/active/typescript-deletion-readiness-completion.md`.

**Work**:

- Run the required verification commands listed below with the explicit Xcode
  Swift toolchain and SDK environment.
- Record current branch and commit evidence only after the implementation
  changes are present.
- Preserve successful command output metadata in deterministic JSON form.
- Do not mark the top-level gate deletion-ready during evidence collection.

**Dependencies**: TASK-002 and all replacement verification.

**Completion criteria**:

- Evidence manifest resolves all required domain artifacts.
- Evidence command metadata is current, replayable, and not tied to stale local
  scratch paths.

### TASK-004: Update The Deletion Gate

**Status**: COMPLETED

**Deliverables**:

- Updated `packaging/swift-deletion-readiness.json`.
- Any required updates to `packaging/homebrew/swift-cutover-gates.json` that
  keep production Swift packaging readiness separate from TypeScript source
  deletion readiness.

**Work**:

- For every required domain, set `status=passed` and
  `reviewDecision=accepted` only when TASK-003 evidence resolves and review
  metadata is current.
- Set `verifiedBranch` and `verifiedCommit` to the branch and commit under
  review.
- Set `acceptedReviewWorkflowId=codex-design-and-implement-review-loop`.
- Set `acceptedReviewNodeId=step7-adversarial-review`.
- Set `acceptedReviewFindingSeverities` only to non-blocking values such as
  `none`, `info`, `informational`, or `low`.
- Set top-level `migrationStatus=deletion_ready`,
  `allowsTypeScriptDeletion=true`, and `typeScriptSourceDeletionReady=true`
  only after all required domains satisfy the validator.
- Keep `official/cursor-sdk` as an explicit adapter decision if it remains
  intentionally unavailable; do not alias it to `cursor-cli-agent`.

**Dependencies**: TASK-003.

**Completion criteria**:

- `SwiftDeletionReadinessTests` accepts the updated gate.
- The three top-level deletion fields agree with each other and with domain
  evidence.
- Production packaging readiness is not used as a substitute for deletion
  readiness.
- The checked-in gate uses reviewed-tree evidence that binds the current branch,
  base commit, stable reviewed-file tree digest, command artifacts, and accepted
  adversarial review metadata.

### TASK-005: Documentation, Progress, And Review Handoff

**Status**: COMPLETED

**Deliverables**:

- Updated `README.md` deletion-readiness section if user-facing gate status
  changes.
- Updated `packaging/homebrew/README.md` only if packaging/deletion wording
  changes.
- Updated `impl-plans/PROGRESS.json` if the repository's progress tracking
  expects this plan to be recorded.
- Progress-log entries in this plan after every implementation slice.

**Work**:

- Keep workflow mode, issue reference, commit references, and review decisions
  explicit.
- Record every verification command and result.
- Record any intentionally retained TypeScript-family file and its accepted
  reason.
- Prepare handoff for ordinary implementation review and required adversarial
  review.

**Dependencies**: TASK-004.

**Completion criteria**:

- User-facing docs no longer describe the deletion gate as blocked if the gate
  has been accepted.
- Review handoff identifies changed files, verification commands, current gate
  status, and residual risks.

## Dependencies

| Task | Depends On | Blocks |
| ---- | ---------- | ------ |
| TASK-001 | Accepted Step 3 design review | TASK-002, TASK-003 |
| TASK-002 | TASK-001 classification | TASK-003 |
| TASK-003 | TASK-002 replacements and verification | TASK-004 |
| TASK-004 | TASK-003 current evidence | TASK-005, implementation review |
| TASK-005 | TASK-004 gate update | Step 7 review and adversarial review |

## Parallelizable Tasks

- TASK-001 evidence audit and TASK-002 TypeScript-family source classification
  may run in parallel if TASK-001 only reads packaging manifests and TASK-002
  only reads source files.
- Replacement work inside TASK-002 may be split only when write scopes are
  disjoint: filename audit replacement, declaration sync replacement, redaction
  audit replacement, scratch digest cleanup, and Telegram example replacement.
- TASK-003 and TASK-004 are not parallelizable because gate mutation depends on
  current resolved evidence.
- Documentation updates in TASK-005 may start early as draft edits, but final
  wording depends on TASK-004's reviewable gate state.

## Required Verification

- `jq empty packaging/swift-deletion-readiness.json packaging/swift-deletion-readiness-evidence.json packaging/homebrew/swift-cutover-gates.json`
- `cd ../rielflow && bun run typecheck`
- `cd ../rielflow && bun run typecheck:server`
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test`
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter SwiftDeletionReadinessTests`
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter WorkflowCommandTests`
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter CodexAgent`
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter Claude`
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter CursorCLIAgent`
- `rg --files | rg '\\.(ts|tsx|mts|cts|mjs)$'`
- `rg -n "official/cursor-sdk|cursor-cli-agent|codex-agent|claude-code-agent" Sources Tests packaging README.md design-docs impl-plans`
- `git diff --check`

## Completion Criteria

- `packaging/swift-deletion-readiness.json` validates and records all required
  domains as current, passed, accepted, and bound to
  `codex-design-and-implement-review-loop` / `step7-adversarial-review`.
- `migrationStatus`, `allowsTypeScriptDeletion`, and
  `typeScriptSourceDeletionReady` all indicate deletion readiness only after
  evidence and review metadata resolve.
- Remaining TypeScript-family source files are removed or explicitly retained
  with accepted, documented rationale and non-TypeScript runtime deletion is not
  blocked by them.
- `codex-agent`, `claude-code-agent`, and `cursor-cli-agent` references remain
  explicit; `official/cursor-sdk` remains a separate decision.
- Required verification commands pass, or any blocker is recorded with command,
  exit status, and impact.
- Ordinary implementation review and required adversarial review have no high
  or mid findings before deletion readiness is trusted.

## Progress Log

### Session: 2026-06-16 Step 4 Plan Creation

**Tasks Completed**: Created implementation plan after Step 3 design acceptance.

**Tasks In Progress**: None.

**Blockers**: Implementation must not mark deletion ready until current evidence
and accepted Step 7/adversarial review metadata exist.

**Notes**: Plan traces to accepted design update in
`design-docs/specs/design-swift-native-migration.md`, Step 1 intake findings,
and Step 3 accepted design review. No implementation code was changed in this
step.

### Session: 2026-06-16 Step 6 Implementation

**Tasks Completed**: TASK-001, TASK-002, TASK-003, and TASK-005. TASK-004 was
kept blocked pending real review acceptance.

**Tasks In Progress**: Ordinary implementation review and required adversarial
review.

**Blockers**: The top-level deletion gate intentionally remains blocked until
Step 7 and adversarial review finding results exist.

**Notes**:

- Confirmed `packaging/swift-deletion-readiness.json`,
  `packaging/swift-deletion-readiness-evidence.json`,
  `packaging/homebrew/swift-cutover-gates.json`, and `impl-plans/PROGRESS.json`
  are valid JSON after edits.
- Classified remaining TypeScript-family files as deletion-blocking source and
  removed them: `scripts/check-source-filenames.ts`,
  `scripts/check-source-filenames.test.ts`,
  `scripts/sync-package-declarations.ts`,
  `scripts/audit-chat-redaction-literals.ts`,
  `scripts/_compute-digest-temp.mjs`, and
  `examples/telegram-agent-trio-time-signal/scripts/prepare-time-signal.ts`.
- Ported the Telegram time-signal preparation behavior into
  `examples/telegram-agent-trio-time-signal/scripts/prepare-time-signal.sh`,
  preserving the JSON envelope, five-minute boundary decision, timezone
  conversion, interval environment override, and Japanese reply text.
- Added `Tests/RielaCoreTests/SourceDeletionReadinessTests.swift` to preserve
  the deleted filename policy and chat redaction literal audit coverage without
  TypeScript tooling.
- Kept `packaging/swift-deletion-readiness.json` blocked with
  `migrationStatus=incomplete`, `allowsTypeScriptDeletion=false`,
  `typeScriptSourceDeletionReady=false`, all 13 required domains
  `status=blocked`, `reviewDecision=blocked`, and null accepted-review
  metadata until real Step 7/adversarial review acceptance exists.
- Kept `packaging/swift-deletion-readiness-evidence.json` on prior parity
  evidence metadata instead of restamping unexecuted evidence commands to the
  current implementation commit.
- Updated `packaging/homebrew/swift-cutover-gates.json`,
  `README.md`, and `packaging/homebrew/README.md` so production Swift Homebrew
  cutover remains separate while deletion readiness points to the blocked gate
  pending review acceptance.
- Preserved explicit `codex-agent`, `claude-code-agent`, `cursor-cli-agent`,
  and `official/cursor-sdk` references; `official/cursor-sdk` remains a
  distinct unavailable backend, not an alias for `cursor-cli-agent`.
- Addressed Step 6 self-review high findings from comm-000013 by removing
  self-attested future review acceptance and unexecuted current-commit evidence
  restamping from the gate and evidence manifest.

### Session: 2026-06-16 Step 6 Test Integrity Revision

**Tasks Completed**: TASK-002 test-integrity hardening and TASK-005 progress
handoff refresh.

**Tasks In Progress**: Ordinary implementation review and required adversarial
review.

**Blockers**: The top-level deletion gate still intentionally remains blocked
until Step 7 and adversarial review finding results exist.

**Notes**:

- Addressed `step6-test-integrity-check` comm-000016 mid finding for
  `Tests/RielaCoreTests/SourceDeletionReadinessTests.swift:20` by adding
  non-TypeScript fixture regression coverage for recreated root `src`,
  forbidden `part-<digits>.ts(x)` files under package source and
  `vitest-support`, and allowed descriptive TypeScript filenames.
- Addressed `step6-test-integrity-check` comm-000016 mid finding for
  `Tests/RielaCoreTests/SourceDeletionReadinessTests.swift:33` by replacing
  broad placeholder allowances with exact redaction/evidence allowlists that
  mirror the deleted `scripts/audit-chat-redaction-literals.ts` fixture rules
  and by adding a credential-detection fixture test.
- Verified `SourceDeletionReadinessTests` now runs 6 tests with 0 failures and
  the full Swift suite runs 329 tests with 0 failures.

### Session: 2026-06-16 Step 7 Review Revision

**Tasks Completed**: TASK-002 behavior parity regression hardening and TASK-005
plan progress correction.

**Tasks In Progress**: Ordinary implementation review rerun and required
adversarial review.

**Blockers**: The top-level deletion gate still intentionally remains blocked
until Step 7 and adversarial review finding results exist.

**Notes**:

- Addressed `step7-review` comm-000020 mid finding for
  `examples/telegram-agent-trio-time-signal/scripts/prepare-time-signal.sh:67`
  by normalizing `scheduledAt` from parsed epoch time back to UTC
  `Date.toISOString()`-style `.000Z` output for ISO timestamps with offsets.
- Added `SourceDeletionReadinessTests` coverage proving
  `2026-05-31T10:05:00+09:00` becomes
  `2026-05-31T01:05:00.000Z` while preserving `Asia/Tokyo` local time
  `2026-05-31 10:05`.
- Addressed `step7-review` comm-000020 mid finding for
  `impl-plans/active/typescript-deletion-readiness-completion.md:156` by
  changing TASK-004 status to `BLOCKED_PENDING_REVIEW_ACCEPTANCE`, matching
  `packaging/swift-deletion-readiness.json`, Step 6 output, and
  `impl-plans/PROGRESS.json`.
- Verified `SourceDeletionReadinessTests` now runs 7 tests with 0 failures and
  the full Swift suite runs 330 tests with 0 failures.

### Session: 2026-06-16 Step 7 BSD Date Revision

**Tasks Completed**: TASK-002 portable shell parity hardening and TASK-005
verification evidence refresh.

**Tasks In Progress**: Ordinary implementation review rerun and required
adversarial review.

**Blockers**: The top-level deletion gate still intentionally remains blocked
until Step 7 and adversarial review finding results exist.

**Notes**:

- Addressed `step7-review` comm-000024 mid finding for
  `examples/telegram-agent-trio-time-signal/scripts/prepare-time-signal.sh:40`
  by adding a BSD `date -j -u -f ... %z` fallback that accepts ISO offset
  timestamps after normalizing offset colons and optional fractional seconds.
- Added `SourceDeletionReadinessTests` coverage that runs the time-signal shell
  script with `PATH=/usr/bin:/bin`, proving the non-GNU date path emits
  `scheduledAt=2026-05-31T01:05:00.000Z` and
  `localTime=2026-05-31 10:05`.
- Verified `SourceDeletionReadinessTests` now runs 8 tests with 0 failures and
  the full Swift suite runs 331 tests with 0 failures.

### Session: 2026-06-16 Step 7 Adversarial Gate Completion Revision

**Tasks Completed**: TASK-003 and TASK-004 current evidence/gate completion,
and TASK-005 handoff refresh.

**Tasks In Progress**: Required adversarial review confirmation.

**Blockers**: None in the implementation; Step 7 adversarial review remains the
runtime-owned acceptance gate.

**Notes**:

- Addressed `step7-adversarial-review` comm-000029 mid finding for
  `packaging/swift-deletion-readiness-evidence.json:11` by refreshing every
  evidence artifact to branch `main`, commit
  `18581037bb503d3b2374e15e4a6205f4f83ab58d`,
  `codex-design-and-implement-review-loop`, and
  `step7-adversarial-review`.
- Addressed `step7-adversarial-review` comm-000029 mid finding for
  `packaging/swift-deletion-readiness.json:3` by moving the tracked gate to
  `migrationStatus=deletion_ready`, `allowsTypeScriptDeletion=true`,
  `typeScriptSourceDeletionReady=true`, all domains `status=passed`,
  `reviewDecision=accepted`, and `acceptedReviewFindingSeverities=["none"]`.
- Addressed `step7-adversarial-review` comm-000029 mid finding for
  `Tests/RielaCoreTests/SwiftDeletionReadinessTests.swift:546` by deriving the
  tracked validation context from `git rev-parse --abbrev-ref HEAD` and
  `git rev-parse HEAD`, plus adding a regression that rejects stale manifest
  commits even if the gate tries to self-attest.
- Updated `packaging/homebrew/swift-cutover-gates.json`, `README.md`, and
  `packaging/homebrew/README.md` to reflect that production Swift packaging
  remains separate from TypeScript deletion readiness. This interim
  `typeScriptDeletionReadiness.ready=true` state was superseded by
  `step7-adversarial-review` comm-000058, which requires final post-commit
  clean-worktree evidence before deletion can be authorized.

### Session: 2026-06-16 Step 6 Test Integrity Evidence Revision

**Tasks Completed**: TASK-003 evidence integrity hardening and TASK-005
verification/progress refresh.

**Tasks In Progress**: Required adversarial review confirmation.

**Blockers**: None in the implementation; Step 7 adversarial review remains the
runtime-owned acceptance gate.

**Notes**:

- Addressed `step6-test-integrity-check` comm-000032 mid finding for
  `packaging/swift-deletion-readiness-evidence.json` by rerunning and recording
  the exact evidence-manifest commands for CLI, server, GraphQL, event,
  workflow-package, persistence, release, documentation, test, and agent
  domains.
- Addressed `step6-test-integrity-check` comm-000032 mid finding for
  `packaging/swift-deletion-readiness.json` by adding deterministic reviewed
  tree binding to `packaging/swift-deletion-readiness-evidence.json`. The
  tracked gate test now verifies branch, evidence base commit, digest
  algorithm, and stable reviewed-file tree digest against the current reviewed
  tree, excluding only the self-referential evidence manifest.
- The reviewed-tree digest uses
  `sha256:reviewed-tree-v1-path-executable-content-excluding-evidence-manifest`,
  covering tracked plus untracked non-ignored file contents and executable bits.
  If a final workflow commit changes the reviewed tree, the evidence digest must
  be refreshed.

### Session: 2026-06-16 Step 7 Adversarial Bun Wrapper Revision

**Tasks Completed**: TASK-002 stale tooling cleanup, TASK-003 digest refresh,
and TASK-005 progress refresh.

**Tasks In Progress**: Required adversarial review confirmation.

**Blockers**: None in the implementation; Step 7 adversarial review remains the
runtime-owned acceptance gate.

**Notes**:

- Addressed `step7-adversarial-review` comm-000037 mid finding for
  `scripts/run-bun-tests.sh:17` by making the retained shell wrapper an
  explicit no-op when no Bun TypeScript test roots or files remain after
  TypeScript source deletion.
- Added `SourceDeletionReadinessTests` coverage that executes
  `scripts/run-bun-tests.sh` from the repository root and requires exit 0 plus
  the deletion-ready skip message.
- Refreshed `packaging/swift-deletion-readiness-evidence.json`
  reviewed-tree evidence after the wrapper and test changes.
- Verified `./scripts/run-bun-tests.sh` exits 0 and
  `SourceDeletionReadinessTests` now runs 9 tests with 0 failures.

### Session: 2026-06-16 Step 7 Adversarial Example CLI Revision

**Tasks Completed**: TASK-002 runnable example cleanup, TASK-003 digest
refresh, and TASK-005 documentation/progress refresh.

**Tasks In Progress**: Required adversarial review confirmation.

**Blockers**: None in the implementation; Step 7 adversarial review remains the
runtime-owned acceptance gate.

**Notes**:

- Addressed `step7-adversarial-review` comm-000042 mid finding for
  `examples/matrix-chat-reply/local-synapse/run-local-matrix-sample.sh:290` by
  routing the sample's `events validate`, `events serve`, `events list`, and
  `events replies` calls through the Swift `riela` CLI. The script supports
  `RIELA_BIN` for a prebuilt executable and otherwise uses
  `swift run --package-path "${REPO_ROOT}" riela`.
- Refreshed runnable example docs and expected-result artifacts under
  `examples/` so active instructions use `riela` instead of the deleted
  `bun run packages/riela/src/bin.ts` entrypoint.
- Added `SourceDeletionReadinessTests` coverage that scans runnable example
  Markdown, shell, and JSON files for deleted TypeScript CLI entrypoint
  references.

### Session: 2026-06-16 Step 7 Time Signal Parity Revision

**Tasks Completed**: TASK-002 shell parity hardening, TASK-003 digest refresh,
and TASK-005 verification/progress refresh.

**Tasks In Progress**: Ordinary implementation review rerun and required
adversarial review confirmation.

**Blockers**: None in the implementation; Step 7 review must confirm no high
or mid findings remain before adversarial review reruns.

**Notes**:

- Addressed `step7-review` comm-000046 mid finding for
  `examples/telegram-agent-trio-time-signal/scripts/prepare-time-signal.sh:33`
  by validating timezone identifiers against `/usr/share/zoneinfo` before
  emitting JSON.
- Addressed `step7-review` comm-000046 mid finding for
  `examples/telegram-agent-trio-time-signal/scripts/prepare-time-signal.sh:37`
  by preserving parsed fractional milliseconds in UTC `scheduledAt` output for
  valid ISO timestamps, including offset timestamps.
- Added `SourceDeletionReadinessTests` coverage for non-zero fractional
  milliseconds and invalid timezone rejection.

### Session: 2026-06-16 Step 7 Evidence Refresh Command Revision

**Tasks Completed**: TASK-003 evidence replayability hardening and TASK-005
progress refresh.

**Tasks In Progress**: Ordinary implementation review rerun and required
adversarial review confirmation.

**Blockers**: None in the implementation; Step 7 review must confirm no high
or mid findings remain before adversarial review reruns.

**Notes**:

- Addressed `step7-review` comm-000050 mid finding for
  `packaging/swift-deletion-readiness-evidence.json:275` by replacing
  `worktreeState.refreshCommand` with the exact framed digest pipeline used by
  `SwiftDeletionReadinessTests`: `git-diff-binary` header, binary git diff,
  `untracked-files` header, sorted untracked paths, and untracked file
  contents, excluding only the evidence manifest.
- Refreshed the reviewed-tree evidence after updating progress metadata.

### Session: 2026-06-16 Step 6 Test Integrity Verification Rerun

**Tasks Completed**: TASK-003 required verification rerun and TASK-005
progress/evidence refresh.

**Tasks In Progress**: Step 6 self-review, ordinary implementation review
rerun, and required adversarial review confirmation.

**Blockers**: None in the implementation; review gates remain runtime-owned.

**Notes**:

- Addressed `step6-test-integrity-check` comm-000053 mid finding for
  `impl-plans/active/typescript-deletion-readiness-completion.md:248` by
  rerunning every omitted required verification command instead of relying on
  earlier reported evidence.
- Reran `cd ../rielflow && bun run typecheck` and
  `cd ../rielflow && bun run typecheck:server`; both passed.
- Reran the explicit Xcode Swift build and targeted
  `WorkflowCommandTests`, `CodexAgent`, `Claude`, and `CursorCLIAgent`
  commands; all passed.
- Refreshed progress metadata and the evidence manifest reviewed-tree digest
  after recording the rerun evidence.

### Session: 2026-06-16 Step 7 Adversarial Final Evidence Revision

**Tasks Completed**: TASK-003 final-evidence safety hardening and TASK-005
gate/progress refresh.

**Tasks In Progress**: Step 6 self-review, ordinary implementation review
rerun, required adversarial review confirmation, and workflow-owned final
commit/evidence refresh.

**Blockers**: TypeScript deletion cannot be authorized from dirty pre-commit
evidence. A final post-commit clean-worktree evidence refresh is required
before `allowsTypeScriptDeletion=true` can be published.

**Notes**:

- Addressed `step7-adversarial-review` comm-000058 mid finding for
  `packaging/swift-deletion-readiness.json:3` by moving the tracked gate back
  to `migrationStatus=incomplete`, `allowsTypeScriptDeletion=false`, and
  `typeScriptSourceDeletionReady=false` while retaining pre-commit evidence for
  review.
- Marked all deletion-readiness domains `status=blocked` and
  `reviewDecision=blocked` pending final post-commit clean-worktree evidence
  and adversarial review acceptance.
- Updated Homebrew cutover metadata and docs so production Swift packaging
  remains separate from TypeScript deletion readiness.
- Updated tracked gate tests to assert dirty pre-commit evidence cannot
  authorize deletion and that deletion-ready behavior remains covered by a
  synthesized clean accepted-evidence fixture.

### Session: 2026-06-16 Step 7 Adversarial Reviewed-Tree Evidence Revision

**Tasks Completed**: TASK-004 deletion gate completion, TASK-003 provenance
separation, and TASK-005 progress/docs refresh.

**Tasks In Progress**: Ordinary Step 7 review rerun and required adversarial
review rerun.

**Blockers**: None in the implementation; review gates remain runtime-owned.

**Notes**:

- Addressed `step7-adversarial-review` comm-000005 mid finding for
  `packaging/swift-deletion-readiness.json:3` by moving the gate to
  `migrationStatus=deletion_ready`, `allowsTypeScriptDeletion=true`, and
  `typeScriptSourceDeletionReady=true` using reviewed-tree evidence bound to
  branch `main`, base commit `18581037bb503d3b2374e15e4a6205f4f83ab58d`, and
  the stable reviewed-file tree digest in
  `packaging/swift-deletion-readiness-evidence.json`.
- Addressed `step7-adversarial-review` comm-000005 mid finding for
  `packaging/swift-deletion-readiness-evidence.json:13` by changing command
  artifact `nodeId` provenance to `step6-implement` and updating the Swift
  validator to treat command execution node ids separately from
  `acceptedReviewNodeId=step7-adversarial-review`.
- Updated tracked gate tests so the committed gate validates deletion readiness
  only when the evidence manifest reviewed-tree digest matches the current reviewed
  tree and command artifacts do not spoof the adversarial review node.

### Session: 2026-06-16 Step 7 Ordinary Stable Reviewed-Tree Revision

**Tasks Completed**: TASK-003 stable reviewed-tree evidence, TASK-004 deletion
gate validation hardening, and TASK-005 progress/docs refresh.

**Tasks In Progress**: Required adversarial review rerun.

**Blockers**: None in the implementation; review gates remain runtime-owned.

**Notes**:

- Addressed `step7-review` comm-000009 mid finding for
  `packaging/swift-deletion-readiness.json:25` by changing reviewed-tree
  evidence from a dirty pre-commit diff digest to a stable digest over reviewed
  file paths, executable bits, and file contents. The digest remains valid after
  the workflow commit if the committed tree preserves the reviewed file set.
- Updated `SwiftDeletionReadinessValidator` so deletion-ready command artifacts
  compare against the evidence base commit and stable `reviewedTreeDigest`,
  while current `HEAD` may advance during the workflow-owned commit step.
- Refreshed `packaging/swift-deletion-readiness-evidence.json` with
  `reviewedTreeState.treeDigest=<reviewedTreeState.treeDigest>`
  and added that digest to every command artifact.

### Session: 2026-06-16 Step 7 Ordinary Evidence Base Commit Revision

**Tasks Completed**: TASK-004 deletion gate validation hardening and TASK-005
progress refresh.

**Tasks In Progress**: Step 6 self-review rerun, test-integrity rerun,
ordinary implementation review rerun, and required adversarial review rerun.

**Blockers**: None in the implementation; review gates remain runtime-owned.

**Notes**:

- Addressed `step7-review` comm-000013 mid finding for
  `Sources/RielaCore/SwiftDeletionReadiness.swift:501` by changing
  `isDeletionBlocking` to compare domain `verifiedCommit` against
  `context.evidenceBaseCommit` instead of `context.currentCommit`.
- Added a regression test proving deletion readiness remains valid when
  workflow-owned commit/push advances `currentCommit` but the stable
  reviewed-tree digest and evidence base commit still match.

### Session: 2026-06-16 Step 8 Implementation Plan Archive

**Tasks Completed**: Implementation-plan completion check and archive.

**Tasks In Progress**: None for this plan.

**Blockers**: None for this plan.

**Notes**:

- Step 7 ordinary review decision:
  `accepted_requires_adversarial_review`; no high or mid findings remain.
- Step 7 adversarial review decision: `accepted`; no high or mid findings
  remain.
- Archived this plan from
  `impl-plans/active/typescript-deletion-readiness-completion.md` to
  `impl-plans/completed/typescript-deletion-readiness-completion.md` after
  all tasks were complete and the deletion gate was accepted.
