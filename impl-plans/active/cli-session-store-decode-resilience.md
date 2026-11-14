# CLI Session Store Decode Resilience — Implementation Plan

**Status**: Blocked pending scope decision; resilient reads implemented
**Workflow Mode**: `issue-resolution`
**Issue Reference**: title-only, “Make CLIWorkflowSessionStore skip undecodable
record_json rows instead of aborting the command”
**Design References**:
`design-docs/specs/design-cli-session-store-decode-resilience.md#behavioral-contract`,
`design-docs/specs/design-cli-session-store-decode-resilience.md#warning-contract`,
`design-docs/specs/design-cli-session-store-decode-resilience.md#session-identity-and-numbering`,
`design-docs/specs/design-cli-session-store-decode-resilience.md#validation-and-regression-coverage`,
`design-docs/user-qa/qa-cli-session-store-decode-resilience.md`
**Codex-Agent References**: None
**Created**: 2026-07-24
**Last Updated**: 2026-07-24

## Objective

Make SQLite-backed CLI session reads resilient to individually undecodable
`record_json` values while preserving strict model decoding, non-destructive
storage, warning aggregation, valid-record ordering, and collision-safe session
allocation from raw identity columns.

## Scope

Included:

- `CLIWorkflowSessionStore.load(sessionId:)`, `loadAll()`, and `list(...)`
  decode-failure handling.
- One injectable, `@Sendable` warning sink with a stderr default.
- A raw `session_id`/`workflow_id` identity read used to seed the monotonic
  allocator independently from full-record decoding.
- Focused temporary-store regression coverage and the accepted CLI suites.
- Review of directly affected repository documentation and package-digest
  requirements before handoff.

Excluded:

- Any compatibility/defaulting decoder for
  `WorkflowResolutionOptions.includeDeactivated`.
- Changes to `Sources/RielaCLI/RielaCommand.swift`.
- Deleting, updating, repairing, or migrating incompatible rows.
- Compensating queries when `list(...)` returns fewer valid rows than its SQL
  limit.
- Access to the developer's real `~/.riela` store.

## Scope-Decision Gate

Before implementing collision-safe allocation, record the answer to
`design-docs/user-qa/qa-cli-session-store-decode-resilience.md`.

- If the narrow scope expansion is approved, add the minimum raw-ID observation
  seam in `Sources/RielaCore/RuntimeStore.swift` and focused tests.
- If it is declined, stop and report that the numbering acceptance criterion
  cannot be satisfied within the remaining file boundary. Do not silently omit
  the criterion or fabricate partial runtime sessions.

## Task Breakdown

| Task | Deliverables | Primary write scope | Dependencies | Parallelizable |
| --- | --- | --- | --- | --- |
| T1 Scope decision | Record approval or rejection of the narrow runtime-store observation seam; preserve the decision in the progress log | `design-docs/user-qa/qa-cli-session-store-decode-resilience.md`, this plan | Accepted Step 3 design | No; implementation gate |
| T2 Warning and resilient-read seam | Add an injectable `@Sendable (String) -> Void` sink with a newline-terminated stderr default; preserve `CLIWorkflowSessionStore: Sendable`; centralize per-invocation skipped counting and the stable warning text without changing strict Codable behavior | `Sources/RielaCLI/CLIWorkflowSessionStore.swift` | T1 approval | No; shares the store file with T3 |
| T3 Read behavior | Make `loadAll()` and `list(...)` retain decodable rows in SQL order and skip decode failures; make `load(sessionId:)` warn once and throw the existing not-found error for an undecodable selected row; preserve all non-decode errors | `Sources/RielaCLI/CLIWorkflowSessionStore.swift` | T2 | No; same file and behavior seam |
| T4 Collision-safe identity seeding | Query raw `session_id` and `workflow_id` columns without decoding `record_json`; expose the minimum runtime-store observation operation; observe all raw identities before seeding valid decoded sessions | `Sources/RielaCLI/CLIWorkflowSessionStore.swift`, conditionally approved `Sources/RielaCore/RuntimeStore.swift` | T1 approval, T3 | No; integrates with T3's startup path |
| T5 Regression tests | Save one current record, insert one incompatible JSONB record missing `includeDeactivated`, and assert resilient scans, targeted not-found behavior, exactly one warning per affected invocation through concurrency-safe capture, no warning for a clean read, raw row count of two, valid-session seeding, and no ID collision when the bad row has the highest suffix | `Tests/RielaCLITests/CLIWorkflowSessionStoreResilienceTests.swift`; focused core test only if needed for the approved runtime seam | T2–T4 | No; depends on final public/internal seams |
| T6 Documentation and package review | Reconcile the accepted design and QA decision with final behavior; review `README.md` and `.codex/skills/riela-impl-workflow/SKILL.md` for directly affected user-facing text; refresh `riela-package.json` digests only if workflow, prompt, script, or packaged-skill content changes | Design/plan docs and directly affected repository docs only | T2–T5 | No; post-implementation evidence |
| T7 Integrated verification and handoff | Run build, focused suites, mutation/protected-file checks, diff hygiene, and record exact outcomes, unrelated failures, changed files, review decisions, and residual risks | This plan's Progress Log; fixes remain in the owning task's scope | T2–T6 | No; final gate |

No implementation tasks are scheduled in parallel. The production tasks share
the session-store/startup data flow, and the regression task depends on the
final warning and allocator seams.

## Data-Flow Deliverable

The completed startup path must follow this order:

1. Read raw `session_id` and `workflow_id` values from
   `cli_workflow_sessions`.
2. Advance the runtime ID generator for every raw identity without creating a
   runtime session object.
3. Read and independently decode full `record_json` values.
4. Seed only valid decoded sessions and their available workflow messages.
5. Emit one aggregate warning for each public read invocation that skipped one
   or more records.

Read paths must not execute `DELETE`, `UPDATE`, upsert, schema repair, or record
rewrite operations.

## Verification

Run from the repository root and record command, exit status, test count when
available, and any unrelated failure:

```bash
swift build
swift test --filter CLIWorkflowSessionStoreResilienceTests
swift test --filter WorkflowCommandSessionDiscoveryTests
swift test --filter WorkflowCommandLivePersistenceTests
swift test --filter CLIWorkflowSessionResolutionTests
git diff --check
git diff --exit-code -- Sources/RielaCLI/RielaCommand.swift
rg -n "DELETE|UPDATE" Sources/RielaCLI/CLIWorkflowSessionStore.swift
git status --short
```

The resilience suite must use `RielaCLITemporaryDirectory` and must prove the
raw row count remains two after every read. Review any `DELETE` or `UPDATE`
reported by `rg` and confirm it is absent from the changed read paths. Known
unrelated `DaemonWorkflowNodePatchTests` and agent-VM interleaved-submit flakes
must be recorded separately and must not be labeled regressions without causal
evidence.

## Completion Criteria

- [ ] The QA scope decision is recorded; an approved runtime seam is minimal,
  or a declined decision is reported as a blocker.
- [x] `loadAll()` and `list(...)` return every selected decodable record,
  preserve SQL order, and skip undecodable full records without throwing.
- [x] `load(sessionId:)` maps a selected row's decode failure to
  `CLIWorkflowSessionStoreError.notFound`.
- [x] Each affected public read emits exactly one
  `warning: skipped N unreadable CLI session record(s)` line through the
  injectable sink; clean reads emit none.
- [x] No read deletes, updates, repairs, migrates, or rewrites stored rows.
- [x] `WorkflowResolutionOptions.includeDeactivated` remains a required
  synthesized-Codable key and `Sources/RielaCLI/RielaCommand.swift` is
  unchanged.
- [ ] Allocation observes raw identity columns and cannot reuse an undecodable
  highest-numbered row's `session_id`.
- [x] Runtime startup seeds valid sessions and excludes incompatible rows as
  session objects.
- [x] All temporary data stays under test-managed temporary directories; the
  developer's real `~/.riela` store is untouched.
- [x] Build, focused test suites, diff hygiene, documentation review, and any
  required digest refresh are complete with evidence.

## Progress Log Expectations

For every implementation session, append a dated entry containing:

- tasks completed and tasks still in progress;
- exact changed file paths;
- the scope-decision result and any design deviation;
- verification commands with exit status and test counts;
- warnings or unrelated failures separated from feature regressions;
- review findings and their disposition;
- remaining blockers or residual risks.

## Progress Log

### Session: 2026-07-24

- Tasks Completed: Step 4 implementation plan created from the accepted Step 3
  design review; Step 5 low traceability and Sendable-testability feedback
  incorporated; T2–T3 resilient reads and warnings implemented; T5 read
  behavior, warning, row-preservation, and valid-session-seeding coverage
  implemented; documentation review and available verification completed.
- Tasks In Progress: T1 scope decision; T4 collision-safe identity seeding; T5
  collision regression; T7 final handoff.
- Blockers: Explicit approval to add the narrow raw-session-ID observation seam
  in `Sources/RielaCore/RuntimeStore.swift` remains unresolved. The conditional
  Step 6 changes and self-authored approval statement were reverted.
- Changed Files:
  `Sources/RielaCLI/CLIWorkflowSessionStore.swift`,
  `Tests/RielaCLITests/CLIWorkflowSessionStoreResilienceTests.swift`,
  and this plan.
- Verification:
  - `swift build`: passed.
  - `swift test --filter RielaCLITests.CLIWorkflowSessionStoreResilienceTests`:
    1 test passed.
  - `swift test --filter WorkflowCommandSessionDiscoveryTests`: 5 tests
    passed.
  - `swift test --filter WorkflowCommandLivePersistenceTests`: 8 tests passed.
  - `swift test --filter CLIWorkflowSessionResolutionTests`: 8 tests passed.
  - Xcode-toolchain `swiftlint --quiet --no-cache`: exited zero; six unrelated
    pre-existing warnings remained, with no warning in changed files.
  - `git diff --check`: passed.
  - `git diff --exit-code -- Sources/RielaCLI/RielaCommand.swift`: passed with
    no diff.
  - `rg -n "DELETE|UPDATE" Sources/RielaCLI/CLIWorkflowSessionStore.swift`:
    only the existing `ON CONFLICT ... DO UPDATE` save-path statement matched;
    no read-path mutation exists.
- Resolved Verification Findings: The initial test compile used async calls
  inside XCTest autoclosures, and the first runtime-seeding fixture lacked the
  runtime persistence schema. Awaiting into local values and preparing the
  temporary test schema resolved both without broadening production behavior.
  Step 6 self-review also required raw row-count checks after each public read;
  those assertions are now present.
- Documentation Review: `README.md` and
  `.codex/skills/riela-impl-workflow/SKILL.md` require no user-facing update;
  no repository-root `riela-package.json` exists and no workflow, prompt,
  script, or packaged-skill content changed.
- Notes: Step 3 had no high or mid findings and returned
  `accepted_for_implementation_planning`; Step 5 accepted implementation with
  two low findings; Step 6 self-review rejected self-authorization of the
  conditional runtime scope and that expansion was reverted; no Codex-agent
  reference input was provided.
