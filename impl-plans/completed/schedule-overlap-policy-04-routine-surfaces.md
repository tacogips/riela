# Schedule Overlap Policy 04: Routine CLI and GraphQL Surfaces Implementation Plan

**planId**: `overlap-04-routine-surfaces`
**Status**: Completed 2026-10-22 (implemented in `3cd0c117`; accepted by the session-474 integration review)
**Workflow Mode**: issue-resolution
**Issue Reference**: none (no issueUrl or issueNumber). The intake came from
workflowInput.requestedBehavior via comm-008602 and comm-008603.
workflowExecutionId: `opus-luna-design-and-implement-review-loop-session-471`.
**Design Reference**: `design-docs/specs/design-scheduled-overlap-policy.md`
(accepted by Step 3, comm-008607): §9 routine integration and §7.3 routine
inspection. See also `design-docs/routine-management.md`.
**dependsOn**: `overlap-01-contracts`
**Branch**: `feat/schedule-overlap-policy`. Make no commits, run no git write
commands.
**Progress log**: `impl-plans/progress/overlap-04-routine-surfaces.md`
**Evidence dir**: `tmp/schedule-overlap-policy-20261021-session-471/overlap-04-routine-surfaces/`

## Intent and Context

Routines own exactly one cron binding (`<routineId>-binding`). Operators must
be able to set its overlap policy at create time and later, through both the
CLI and GraphQL. The values are stored on `RoutineRecord` and copied onto the
binding file.

Relevant code:

- `Sources/RielaWorkflowRegistry/RoutineService.swift`:
  - `RoutineCreateRequest` (l.15)
  - `create` (l.104), which validates via `EventContractValidator` at l.150
  - `setStatus` (l.241)
  - `eventBinding(for:storeRoot:)` (l.295)
  - `writeBindingFile` (l.340)
- `Sources/RielaWorkflowRegistry/RoutineGraphQLProvider.swift`: the
  `FileRoutineGraphQLProvider` methods.
- `Sources/RielaGraphQL/RoutineGraphQL.swift`:
  - DTOs: `GraphQLRoutine` (l.36), `GraphQLCreateRoutineInput` (l.101),
    `GraphQLSetRoutineStatusInput` (l.156)
  - protocol `RoutineGraphQLProviding` (l.227)
  - `RoutineGraphQLDocumentExecutor.mutationFields` (l.238) and its execute
    switch (l.307-345)
  - SDL string `routineGraphQLSchemaTypes` (l.423)
- `Sources/RielaGraphQL/GraphQLSchemaGenerator.swift`: the mutation map
  (l.641 has `"Mutation.setRoutineStatus"`).
- `Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift`: the
  **generated** SDL. Only `scripts/surface-parity/generate-sdl.sh` may change
  it.
- `Sources/RielaCore/SurfaceCatalog+RowsCLI.swift`: `routineCLIRows`
  (l.406-470); copy the `routine.set-status` row.
- `Sources/RielaCLI/RoutineCommands.swift`: `ParsedRoutineOptions`,
  `routineResult`, `routineSummaryLine`, `routineDetailLines`.
- `Sources/RielaCLI/RielaClientFamilyArguments.swift:129`:
  `RoutineClientAction`, which `CLISurfaceEnumeration.swift:97` enumerates
  for parity gates.

Contracts from `overlap-01-contracts`:

- `RoutineRecord.overlapPolicy` / `maxQueuedRuns` / `maxConcurrentRuns`
- `EventBindingContract` fields with the same names
- `EventContractValidator` diagnostics (code `INVALID_EVENT_OVERLAP_POLICY`)
- `EventOverlapPolicy`

## Non-Goals

- Do not change the builtin routine add-ons
  (`ProductionNodeAdapter+RoutineAddon.swift`). The new
  `RoutineCreateRequest` parameters have defaults, so that file must still
  compile unmodified.
- Do not touch the serve, dispatcher, or `ScopedParityCommands` files.
- Make no `RoutineStore` schema or generation change.
- Never hand-edit `GraphQLContractProjector+Schema.swift`.
- Running serve processes pick up changes only at their next start. Add no
  hot reload.

## File-Level Changes

### 1. `Sources/RielaWorkflowRegistry/RoutineService.swift`

- `RoutineCreateRequest`: add `overlapPolicy: String?`, `maxQueuedRuns: Int?`
  and `maxConcurrentRuns: Int?`. Append init parameters defaulting to nil.
- `create`: copy the three values onto `RoutineRecord`.
- `eventBinding(for:storeRoot:)`: pass the three values into
  `EventBindingContract`.
- Create-time validation already runs through `EventContractValidator`. An
  invalid value must make `create` throw `RoutineServiceError`, whose message
  includes the validator message. Verify how `create` turns diagnostics into
  an error (around l.150-157) and keep that path.
- New method:

  ```swift
  public func setOverlapPolicy(routineId: String, overlapPolicy: String?, maxQueuedRuns: Int?, maxConcurrentRuns: Int?, routineStoreRoot: String? = nil) throws -> RoutineMutationResult
  ```

  1. Load the record. A missing record throws `RoutineServiceError`.
  2. Build the candidate record with the new values. `overlapPolicy == nil`
     clears all three, so the binding inherits.
  3. Build the binding with `eventBinding(for:storeRoot:)` and validate it
     with `EventContractValidator.validate(sources: [EventSourceContract(id: record.sourceId, kind: .cron)], bindings: [binding])`.
     On error, throw **before** persisting anything.
  4. Persist with `store.update` (or `save`, the same as `setStatus`), then
     rewrite the binding file with `writeBindingFile`. `enabled` follows the
     current status, as `eventBinding` already computes.
  5. Return the result. Add a diagnostic line
     `binding=<path> overlapPolicy=<v|inherit>`.

### 2. `Sources/RielaWorkflowRegistry/RoutineGraphQLProvider.swift`

- Pass the three new create fields through.
- Implement `setRoutineOverlapPolicy(input:)` by delegating to
  `service.setOverlapPolicy` through `mapServiceError`.

### 3. `Sources/RielaGraphQL/RoutineGraphQL.swift`

- `public enum GraphQLEventOverlapPolicy: String, Codable, Equatable, Sendable { case skip, cancelRunning, queue, concurrent }`
  - The raw values equal the case names.
  - GraphQL enum values are `skip cancelRunning queue concurrent`, exactly
    as in design §9. Do not uppercase them.
  - Add conversions to and from the raw `String`. An unknown stored string
    maps to nil in the DTO.
- `GraphQLRoutine`: add `overlapPolicy: GraphQLEventOverlapPolicy?`,
  `maxQueuedRuns: Int?` and `maxConcurrentRuns: Int?`, filled from the record.
- `GraphQLCreateRoutineInput`: add the same three fields, optional, with init
  parameters defaulting to nil.
- New `public struct GraphQLSetRoutineOverlapPolicyInput: Codable, Equatable, Sendable { routineId: String; overlapPolicy: GraphQLEventOverlapPolicy?; maxQueuedRuns: Int?; maxConcurrentRuns: Int?; routineStoreRoot: String? }`.
- `RoutineGraphQLProviding`: add
  `func setRoutineOverlapPolicy(input: GraphQLSetRoutineOverlapPolicyInput) async throws -> GraphQLRoutineMutationPayload`.
- `RoutineGraphQLDocumentExecutor`: add `"setRoutineOverlapPolicy"` to
  `mutationFields`, and add a `case` in the execute switch modeled on
  `setRoutineStatus`.
- `routineGraphQLSchemaTypes`:
  - add `enum EventOverlapPolicy { skip, cancelRunning, queue, concurrent }`;
  - add the three nullable fields to `type Routine` and to
    `input CreateRoutineInput` (`overlapPolicy: EventOverlapPolicy`,
    `maxQueuedRuns: Int`, `maxConcurrentRuns: Int`);
  - add `input SetRoutineOverlapPolicyInput { routineId: String!, overlapPolicy: EventOverlapPolicy, maxQueuedRuns: Int, maxConcurrentRuns: Int, routineStoreRoot: String }`.

### 4. `Sources/RielaGraphQL/GraphQLSchemaGenerator.swift`

Add the mutation map entry
`"Mutation.setRoutineOverlapPolicy": .init(name: "setRoutineOverlapPolicy", arguments: "input: SetRoutineOverlapPolicyInput!", type: "RoutineMutationPayload!")`,
next to `setRoutineStatus`. Check whether an ordered list of mutation names
elsewhere in the file also needs the name; grep for `"setRoutineStatus"`.

### 5. `Sources/RielaCore/SurfaceCatalog+RowsCLI.swift`

Add a row to `routineCLIRows`, modeled on `routine.set-status`:

- `id: "routine.set-overlap-policy"`
- `family: "routine"`
- `kind: .mutation`
- `cli: "routine set-overlap-policy"`
- `graphql: graphQLMutation("setRoutineOverlapPolicy")`

### 6. `Sources/RielaCLI/RielaClientFamilyArguments.swift`

Add `case setOverlapPolicy = "set-overlap-policy"` to `RoutineClientAction`.

### 7. `Sources/RielaCLI/RoutineCommands.swift`

- `ParsedRoutineOptions`: add
  - `@Option(name: .customLong("overlap-policy")) var overlapPolicy: String?`
  - `@Option(name: .customLong("max-queued-runs")) var maxQueuedRuns: Int?`
  - `@Option(name: .customLong("max-concurrent-runs")) var maxConcurrentRuns: Int?`
  - `@Flag(name: .customLong("clear-overlap-policy")) var clearOverlapPolicy = false`

  Copy the existing `@Option(name: .customLong("completion-criteria"))`
  pattern.
- `create`: pass the three values.
- New action `set-overlap-policy <routine-id>`:
  - It requires exactly one of `--overlap-policy` and
    `--clear-overlap-policy`. Otherwise throw
    `CLIUsageError("routine set-overlap-policy requires exactly one of --overlap-policy or --clear-overlap-policy")`.
  - `--clear-overlap-policy` together with a cap is a usage error with a
    similar message.
  - Call `service.setOverlapPolicy`.
  - Output the summary line plus diagnostics, the same as
    `complete`/`enable`.
- `routineDetailLines`:
  - append `overlapPolicy=<v ?? "inherit">`;
  - append `maxQueuedRuns=<n>` / `maxConcurrentRuns=<n>` only when set.
- Leave `routineSummaryLine` unchanged.

### 8. SDL regeneration

After items 3-5 compile, run `scripts/surface-parity/generate-sdl.sh`. It
rewrites `Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift`. Then run
the parity tests. Never edit the generated file by hand.

### 9. Tests

**`Tests/RielaGraphQLTests/RoutineGraphQLTests.swift`** (update):

- `StubRoutineProvider` (l.6) must implement the new protocol method.
- `setRoutineOverlapPolicy` mutation document
  `{routineId:"r", overlapPolicy: queue, maxQueuedRuns: 2}` → the stub
  receives `.queue` and 2, and the payload is accepted.
- The schema contract contains `setRoutineOverlapPolicy`,
  `enum EventOverlapPolicy` and `Routine.overlapPolicy`. Extend
  `testSchemaContractCarriesRoutineFields`.

**`Tests/RielaCLITests/RoutineCommandTests.swift`** (update). Use temp
`--event-root` and `--routine-store`, the same as the existing tests.

| Situation | Expected outcome |
|---|---|
| `routine create ... --overlap-policy queue --max-queued-runs 2` | the binding JSON file contains `"overlapPolicy" : "queue"` and `"maxQueuedRuns" : 2`; `routine inspect` shows `overlapPolicy=queue` and `maxQueuedRuns=2` |
| `routine create` without flags | the binding file has no `overlapPolicy` key; inspect shows `overlapPolicy=inherit` |
| `routine create --overlap-policy bogus` | fails; the message contains `overlapPolicy must be one of skip, cancelRunning, queue, concurrent; got 'bogus'`; no record or binding file is created |
| `routine set-overlap-policy <id> --overlap-policy concurrent --max-concurrent-runs 3` | the record and binding file are updated; a disabled routine's binding keeps `enabled: false` |
| `routine set-overlap-policy <id> --clear-overlap-policy` | all three keys are removed from the binding file |
| `routine set-overlap-policy <id> --overlap-policy skip --max-queued-runs 2` | fails with the `requires overlapPolicy queue` message; the record is unchanged |
| `routine set-overlap-policy <id>` with neither flag | usage error |

**`Tests/RielaGraphQLTests/` provider round-trip.** If a test file for
`FileRoutineGraphQLProvider` exists, add one round trip there: create via the
provider with `overlapPolicy: .cancelRunning`, then set it to nil → the
record is cleared. Otherwise cover this in `RoutineCommandTests`. Do not
create new test targets.

## Invariants

- Existing routines and bindings without the fields are unchanged, and their
  files are byte-stable when rewritten without overlap values.
- Invalid values are never persisted.
- SurfaceCatalog, the CLI enumeration and the generated SDL stay in parity.

## Execution Protocol (shared working directory)

- **Before each edit:** read the file fresh and record `git hash-object` before
  and after. On drift, re-read and reapply your intent.
- **Write scope:** edit only this plan's `writePaths`. The generated SDL file
  changes only through the script.
- **Concurrent plans:** `overlap-02` and `overlap-03` are editing other
  `RielaCLI` files at the same time.
- **Build failures in files you do not own:** retry up to three times, then
  record the failure. Never edit those files.
- **Scratch files:** only under `tmp/schedule-overlap-policy-20261021-session-471/overlap-04-routine-surfaces/`.
- **Git:** run no git write commands.

## Verification

```text
V0: mkdir -p tmp/schedule-overlap-policy-20261021-session-471/overlap-04-routine-surfaces
V1: arch -arm64 /bin/zsh -lc 'swift build --build-tests' > tmp/schedule-overlap-policy-20261021-session-471/overlap-04-routine-surfaces/v1-build.log 2>&1
V2: scripts/surface-parity/generate-sdl.sh > tmp/schedule-overlap-policy-20261021-session-471/overlap-04-routine-surfaces/v2-sdl.log 2>&1
V3: arch -arm64 /bin/zsh -lc 'swift test --skip-build --filter "RoutineGraphQLTests|RoutineCommandTests|RoutineAddonTests|EventRoutineBindingTests|SurfaceParity"' > tmp/schedule-overlap-policy-20261021-session-471/overlap-04-routine-surfaces/v3-tests.log 2>&1
V4: arch -arm64 /bin/zsh -lc 'swiftlint lint --strict Sources/RielaWorkflowRegistry/RoutineService.swift Sources/RielaWorkflowRegistry/RoutineGraphQLProvider.swift Sources/RielaGraphQL/RoutineGraphQL.swift Sources/RielaGraphQL/GraphQLSchemaGenerator.swift Sources/RielaCore/SurfaceCatalog+RowsCLI.swift Sources/RielaCLI/RielaClientFamilyArguments.swift Sources/RielaCLI/RoutineCommands.swift Tests/RielaGraphQLTests/RoutineGraphQLTests.swift Tests/RielaCLITests/RoutineCommandTests.swift' > tmp/schedule-overlap-policy-20261021-session-471/overlap-04-routine-surfaces/v4-lint.log 2>&1
```

V3 runs after V2, against the regenerated SDL. V2 runs a `swift test` filter
internally. If V1 has not built, V2 builds on demand.

Expected results:

- V1: exit 0.
- V2: exit 0, and `git diff --stat Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift`
  shows the change. Record that output in the log.
- V3: exit 0, `testsRun > 0`, 0 failures.
- V4: exit 0.

For each command, record an integer `exitStatus`, `testsRun`, `failureCount`
and `logPath`.

## Acceptance Criteria

1. `grep -n "setRoutineOverlapPolicy" Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift Sources/RielaGraphQL/GraphQLSchemaGenerator.swift Sources/RielaCore/SurfaceCatalog+RowsCLI.swift` matches in all three files.
2. `grep -n "set-overlap-policy" Sources/RielaCLI/RielaClientFamilyArguments.swift` matches.
3. `grep -n "func setOverlapPolicy" Sources/RielaWorkflowRegistry/RoutineService.swift` matches.
4. V1-V4 pass, and the SurfaceParity tests are green.

## Progress Log Expectations

`impl-plans/progress/overlap-04-routine-surfaces.md` must contain:

- a task checklist;
- a table of pre and post hashes, including the regenerated SDL file;
- the V1-V4 records;
- residual notes. They must not start with a severity word.
