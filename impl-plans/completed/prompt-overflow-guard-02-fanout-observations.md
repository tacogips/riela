# Prompt Overflow Guard 02: Bounded Fanout Change-Evidence Observations

**planId**: `pog-02-fanout-observations`
**Status**: Completed 2026-10-22 (accepted by the session-479 integration
review, comm-008796; uncommitted on `feat/agent-prompt-overflow-guard` above
checkpoint `34223697`)
**Wave**: 2
**dependsOn**: `pog-01-contracts`
**Workflow Mode**: issue-resolution
**Issue Reference**: none. Incident: opus-luna 0.1.8 session-471. Current
run: `opus-luna-design-and-implement-review-loop-session-475`.
**Design Reference**: `design-docs/specs/design-agent-prompt-overflow-guard.md`
Part A. Also the amended join-field paragraph in
`design-docs/specs/design-fanout-dependency-waves-and-change-evidence.md`.
**Branch**: `feat/agent-prompt-overflow-guard`. Do not run any git write
command.
**Progress log**: `impl-plans/progress/pog-02-fanout-observations.md`
**Evidence dir**: `tmp/prompt-overflow/pog-02-fanout-observations/`
**planPath**: `impl-plans/completed/prompt-overflow-guard-02-fanout-observations.md`

**writePaths**:

- `Sources/RielaCore/WorkflowFanoutChangeEvidence.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner+Fanout.swift`
- `Tests/RielaCoreTests/WorkflowFanoutObservationBoundTests.swift`
- `Tests/RielaCoreTests/WorkflowFanoutMapReduceTests.swift`
- `Tests/RielaCoreTests/FanoutArtifactEvidenceRunnerTests.swift`
- `impl-plans/progress/pog-02-fanout-observations.md`
- `tmp/prompt-overflow/pog-02-fanout-observations`

**sharedPaths**: none.

**artifactRoots**: `tmp/prompt-overflow/pog-02-fanout-observations`.

## Intent and Context

In session-471, the fanout join's `changeEvidence.observations` grew without
bound: one entry per branch, capture record and drifted path. This plan
aggregates and caps the inline list and writes the complete list to a file.
The drift comparison itself stays exactly the same.

How the code works today:

- `WorkflowFanoutChangeEvidence.reduce()`
  (`Sources/RielaCore/WorkflowFanoutChangeEvidence.swift:112-141`) iterates
  `records.keys.sorted()`. Within each branch it walks the records in capture
  order and calls `reduceRecord`, which appends `observation(...)` values
  (lines 143-190).
- `hasDrift` is `!observations.isEmpty`.
- `limits` comes from `Self.limits`.
- The evidence directory `directory` is
  `<root>/tmp/riela-fanout/<uuid>`, created with mode 0700. Capture files are
  written with `open(O_WRONLY|O_CREAT|O_EXCL, 0o600)` (lines 92-103).
- `DeterministicWorkflowRunner+Fanout.swift:96` calls
  `changeEvidence.reduce()`. `directive.changeTracking` is a
  `WorkflowFanoutChangeTracking`, which after `pog-01` has
  `observationInlineLimit: Int?` and the static constants
  `defaultObservationInlineLimit` (200) and `maximumObservationInlineLimit`
  (10000).

## Non-Goals

- Do not change `capture`, the snapshot or manifest code, the limits on
  paths, entries or bytes, or the drift reasons.
- Do not change `artifactPaths`, `captureFailures`, `requiresSemanticReview`
  or `observationBoundary`.
- Do not touch prompt composition, the runner agent path or classification.
- Do not edit `WorkflowFanoutScheduling.swift` or
  `WorkflowRawValidation.swift`. `pog-01` owns them.

## File-Level Changes

### `Sources/RielaCore/WorkflowFanoutChangeEvidence.swift`

- Change the signature to
  `func reduce(observationInlineLimit: Int = WorkflowFanoutChangeTracking.defaultObservationInlineLimit) throws -> JSONObject`.
  Clamp the limit to `0...maximumObservationInlineLimit`.
- `reduceRecord` keeps producing raw findings in the same order. Collect
  them as raw tuples `(branchId, selection, path, reason, stepId, snapshotPath)`
  instead of final JSON. A small private struct is fine.
- Aggregate by the key `(branchId, selection, path)`. Each aggregated entry
  has:
  - `branchId`, `selection`, `path`;
  - `reason`: the first raw finding's reason;
  - `reasons`: distinct reasons in first-seen order, as a JSON array;
  - `occurrences`: an integer;
  - `firstStepId` and `lastStepId`;
  - `firstSnapshotPath` and `lastSnapshotPath`.
- Sort aggregated entries by `branchId`, then `selection`, then `path`, all
  ascending with plain `String` `<`.
  - This differs from the current per-record order, so tests must not rely on
    the old order.
- Inline list: the first `limit` aggregated entries.
- Full-list file: `directory/observations.json`.
  - Contents: `{"observations": [ ...every aggregated entry, each also with "occurrenceDetails": [{stepId, snapshotPath, reason}] in raw order ]}`.
  - Serialize with `JSONValue.object(...).compactJSONString()` (sorted keys,
    deterministic).
  - Write it with the same `O_EXCL` / 0600 / cleanup-on-failure pattern as
    `capture` (lines 92-103). Reuse that pattern, ideally through a small
    private helper shared with `capture`.
  - Write it on every `reduce()`, even with zero observations.
  - If the write fails (for example because the directory is not writable),
    append a `reduceFailures` diagnostic built with
    `FanoutSnapshotFailure(.providerError, "fanout observations list could not be persisted: <error>", path: "observations.json").diagnostic(branchId: nil, stepId: "reduce", phase: "reduce")`.
    In that case set `observationsPath` to `null`.
  - If `reduce()` runs twice on the same actor, the second `O_EXCL` fails.
    Handle this by removing and replacing the file deterministically. Either
    write to a temporary name in the same directory and `rename` it over
    `observations.json`, or delete first. Pick one and record it in the
    progress log. `rename` is preferred.
- The returned object adds these fields:
  - `observationCount`: the number of aggregated entries;
  - `observationOccurrenceCount`: the number of raw findings;
  - `inlineObservationCount`;
  - `observationsTruncated`;
  - `observationsPath`: an absolute string, or `null` on write failure;
  - `observationCountsByBranch`: `{branchId: {"total": n, "inline": m}}`, only
    for branches with at least one aggregated entry.
- `hasDrift` becomes `observationCount > 0`. Never compute it from the
  inline subset.
- `complete` stays `reduceFailures.isEmpty`, and now also accounts for the
  persistence failure.
- `limits` adds `"observationInline": <effective limit>`. The static
  `Self.limits` used in capture records stays unchanged. Build the reduce
  `limits` by copying `Self.limits` and adding the key.

### `Sources/RielaCore/DeterministicWorkflowRunner+Fanout.swift`

- Line 96: call
  `changeEvidence.reduce(observationInlineLimit: directive.changeTracking?.observationInlineLimit ?? WorkflowFanoutChangeTracking.defaultObservationInlineLimit)`.
  Make no other change.

### Existing tests

- `Tests/RielaCoreTests/WorkflowFanoutMapReduceTests.swift` (assertObservation
  at about line 538) and
  `Tests/RielaCoreTests/FanoutArtifactEvidenceRunnerTests.swift` (about line
  214) match on `reason`.
- Run them first. Change them only if a case fails because the expected
  reason is now in `reasons` rather than `reason`. Then switch that helper to
  accept `reason == r || reasons contains r`.
- Do not weaken any other assertion.

## Invariants

- The drift set is identical: the same `(branch, selection, path)` keys are
  reported as before, just aggregated.
- `reduceFailures` and `captureFailures` are unchanged for the same tree.
- With limit `0`, `hasDrift` is still true when drift exists, and
  `observations` is `[]`.
- Output is deterministic: two reduces of identical trees produce identical
  JSON, apart from the absolute evidence directory path.

## Tests: `Tests/RielaCoreTests/WorkflowFanoutObservationBoundTests.swift` (new)

Use a scratch root under the repository `tmp/`, as
`FanoutArtifactEvidenceRunnerTests.scratch()` does, and remove it in
teardown.

- Three branches (`a`, `b`, `c`). Each captures `dir` with 3 node-boundary
  records:
  1. `capture(branchId:paths:["dir"],stepId:"fanout-dispatch")`;
  2. `after:n1`;
  3. `after:n2`.

  `dir` must stay within the 512-entry source limit, so use a few seed files.
  After the captures, create about 400 new files under `dir` per branch, so
  the drift appears in every record. Expected outcome:
  - `observationCount == aggregated count`;
  - the occurrences of a file present in all records equals 3;
  - `firstStepId == "fanout-dispatch"` and `lastStepId == "after:n2"`;
  - `observations.count == 200` and `observationsTruncated == true`;
  - `observationCountsByBranch` has `a`, `b` and `c`;
  - `observationsPath` exists and holds `observationCount` entries with
    `occurrenceDetails`;
  - the serialized `changeEvidence` (`compactJSONString().utf8.count`) is
    under 262144 bytes;
  - `hasDrift == true` and `complete == true`.

  If the snapshot limit blocks the growth, use separate directories per
  branch or several roots instead, and keep the per-branch drifted-path count
  at least 300.
- `reduce(observationInlineLimit: 0)` on drift → `observations == []`,
  `hasDrift == true`, `inlineObservationCount == 0`.
- No drift → `observationCount == 0`, `hasDrift == false`, and the file
  exists with an empty list.
- Persistence failure: `chmod 0500` the evidence directory (obtain it from
  the actor's `directory`), then reduce. Restore permissions in a `defer`.
  Expected: `reduceFailures` contains `path == "observations.json"`,
  `complete == false`, `observationsPath` is null, and the inline observations
  are still present.
- Determinism: two reduces of the same actor and tree produce equal
  `observations` arrays.
- Runner wiring: a fanout with `changeTracking.observationInlineLimit: 1`
  through `DeterministicWorkflowRunner` → the join's
  `changeEvidence.limits.observationInline == 1`. Imitate
  `FanoutArtifactEvidenceRunnerTests` for the runner setup with
  `fanoutWorkspaceRoot`.

## Verification

1. `arch -arm64 /bin/zsh -lc 'swift build' 2>&1 | tee tmp/prompt-overflow/pog-02-fanout-observations/build.log`
   must exit 0.
2. `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowFanoutObservationBoundTests|WorkflowFanoutMapReduceTests|FanoutArtifactEvidenceRunnerTests|DeterministicWorkflowRunnerFanoutTests"' 2>&1 | tee tmp/prompt-overflow/pog-02-fanout-observations/test.log`
   must exit 0 and show 0 failures.
3. `arch -arm64 /bin/zsh -lc "swiftlint lint --strict Sources/RielaCore/WorkflowFanoutChangeEvidence.swift Sources/RielaCore/DeterministicWorkflowRunner+Fanout.swift Tests/RielaCoreTests/WorkflowFanoutObservationBoundTests.swift" 2>&1 | tee tmp/prompt-overflow/pog-02-fanout-observations/lint.log`
   must exit 0. Also lint any edited existing test file.

## Done Criteria

- `reduce` returns all the listed fields, and `hasDrift` is derived from
  `observationCount`.
- `observations.json` is written. All new tests pass.
- Verification logs and exit codes are recorded in the progress log, along
  with pre- and post-edit sha256 values for every edited file.

## Overwrite Safety

- Re-read each file before editing it, and hash it before and after.
- Stop on unexpected drift.
- Only `pog-02` edits `WorkflowFanoutChangeEvidence.swift` and
  `DeterministicWorkflowRunner+Fanout.swift` in this wave.
