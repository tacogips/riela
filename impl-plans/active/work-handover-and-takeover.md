# Work Handover and Takeover Implementation Plan (umbrella)

**Status**: Planned — decomposed into plans `wh-00` … `wh-20` (2026-09-30); no code written
**Workflow Mode**: issue-resolution (no GitHub issue; tracked by the design below)
**Design Reference**: `design-docs/specs/design-work-handover-and-takeover.md` (all sections, including §15.1 and §21 R1–R22)
**User decisions**: `design-docs/user-qa/qa-work-handover-and-takeover.md` Q1–Q8 (every one proceeds on its stated default)
**Branch**: `feat/work-handover-and-takeover` only. No merge or push to `main`, no PR into `main`.
**Created**: 2026-09-30 · **Last Updated**: 2026-09-30

This file owns the wave map, the original task list (T0.1–T7.5) and which child
plan implements each task, the shared-path ledger, the common execution
contract, the completion criteria and the global progress log. Workers never
edit this file. Only the serial integration owner edits it, in `wh-00` and `wh-20`.

---

## Summary

When a Work Runtime task attempt stalls because it needs the user (an answer,
or the user's presence on a host), or because its owner died, the runtime seals
a digest-sealed `HandoverPacket` (work state, bounded history, deliverable
locators, rendered brief). It publishes the attempt's `riela/task/<taskId>/g<n>`
branch. It then lets another worker, on the same host or another, reserve an
`AttemptEntry.takeover` attempt that materializes the branch, imports the
history, receives the answer and continues from the resume step. Leases gain
heartbeat, expiry and a fence.

**Excluded** (unchanged from the design): a `cancelled` session status;
`session fork` and `idleSuspendMs`; the execution-environment consolidation;
P3 chat intake and `MonjaTrackerAdapter`; the full P5 task API; cross-host
vendor thread continuation; copying cwd-local memory or KV into packets;
force-push or publication outside `riela/task/*`; skills that live outside
this repository (R13); a `SessionBackendActivityVerdict.awaiting-user` case
(it was in the first plan draft but is not in the design, so it is dropped).

---

## Wave map

| Wave | Plans (parallel within a wave) | Depends on |
| --- | --- | --- |
| W0 (serial) | `wh-00-baseline` — COMPLETED 2026-09-30 (session 228), removed from the dispatch DAG | — |
| W1 | `wh-01-contracts` | — (baseline already recorded) |
| W2 | `wh-02-runner-suspend`, `wh-03-work-store`, `wh-04-packet-coordinator`, `wh-05-history-import`, `wh-06-wait-signal`, `wh-07-git-branch-runtime`, `wh-08-deliverable-collector`, `wh-09-handover-sinks`, `wh-10-host-traits`, `wh-11-director-notify`, `wh-12-graphql-contracts`, `wh-13-gc-sweep` | wh-01 |
| W3 | `wh-14-task-dispatch-runtime` | wh-02 … wh-11 |
| W4 | `wh-15-task-commands`, `wh-16-graphql-provider`, `wh-17-examples` | wh-14 (wh-16 also needs wh-12) |
| W5 | `wh-18-remote-takeover`, `wh-19-docs-skills` | wh-15, wh-16 |
| W6 (serial) | `wh-20-reconcile` | all |

Child plans live beside this file as `impl-plans/active/wh-NN-*.md`. Each one
has its own progress log at `impl-plans/progress/wh-NN-*.md`.

## Original tasks → child plans

| Task | Owner plan |
| --- | --- |
| T0.1 session suspend model | wh-01 (types), wh-02 (runner, store, events) |
| T0.2 resume from suspended | wh-02 |
| T0.3 failure kinds `stalled` / `leaseLost` | wh-01 |
| T1.1 handover models | wh-01 |
| T1.2 store table and queries | wh-01 (tables, CRUD, seal transaction), wh-03 (reservation, leases, answers) |
| T1.3 packet builder + brief | wh-04 |
| T1.4 attempt/decision/evidence extensions | wh-01 (cases), wh-03 (application rules) |
| T1.5 same-store `task takeover` | wh-14 (runtime), wh-15 (command) |
| T2.1 envelope | wh-01 (type and parse), wh-02 (extraction and suspend) |
| T2.2 `riela/handover-request` add-on | wh-14 |
| T2.3 wait-signal classifier | wh-06 (classifier), wh-14 (wiring) |
| T2.4 inactivity policy | wh-11 (director rule), wh-14 (seal after cancel) |
| T2.5 `task handover` | wh-03 (request rows), wh-02 (boundary hook), wh-14 (runtime), wh-15 (command) |
| T2.6 run event + notification | wh-01 (event type), wh-02 (emission), wh-11 (dispatcher), wh-14 (send at seal) |
| T3.1 `task answer` | wh-03 (store), wh-14 (runtime), wh-15 (command) |
| T3.2 answer injection | wh-14 (task), wh-02 (plain `session resume`) |
| T3.3 history import from suspended/bundle | wh-05 |
| T3.4 session adoption | wh-04 (`TaskAdoption`), wh-14 (runtime), wh-15 (`session handover`) |
| T4.1 `GitBranchWorkspaceRuntime` | wh-07 |
| T4.2 attempt branch + `Attempt.isolation` | wh-14 |
| T4.3 checkpoints | wh-07 (operation), wh-14 (step-boundary hook) |
| T4.4 publish + `riela/git-publish-branch` | wh-07 |
| T4.5 materialize at takeover | wh-07 (operation), wh-14 (use) |
| T4.6 worker allowance | wh-01 (validation list), wh-07 (test proving the add-on is not denied) |
| T4.7 document deliverables | wh-01 (`output.deliverables`, validate warning), wh-08 (collector) |
| T5.1 lease columns + heartbeat | wh-01 (columns), wh-03 (queries) |
| T5.2 owner-side fence check | wh-14 |
| T5.3 `--force-orphan` | wh-03 (`fenceOrphan`), wh-14 (runtime), wh-15 (flag) |
| T5.4 `task reconcile` | wh-14 (runtime), wh-15 (command) |
| T5.5 superseded reconciliation | wh-03 |
| T6.1 sinks | wh-09 |
| T6.2 host traits + placement | wh-01 (fields), wh-10 |
| T6.3 GraphQL fields | wh-12 (contracts and executor), wh-16 (provider, serve), wh-20 (catalog, SDL) |
| T6.4 remote takeover / heartbeat / report | wh-16 (controller side), wh-18 (successor side) |
| T6.5 `task serve --takeover` | wh-18 |
| T7.1 examples | wh-17 |
| T7.2 skills + docs | wh-19 |
| T7.3 catalog rows + SDL | wh-20 |
| T7.4 `riela gc` | wh-13 |
| T7.5 final verification | wh-20 |

## Corrections to the first draft's paths and names

These were applied in the child plans (design §21 R1–R22): `normalizeOutputContractEnvelope`
is in `Sources/RielaCore/AdapterContracts.swift`. `DistributedWorkerNodeExecutor` is in
`Sources/RielaCore`. `ServeWebHost` is in `Sources/RielaCLI`. The runner returns
`WorkflowRunResult` (`status`, `exitCode`), and the new exit code is `CLIExitCode.suspended = 5`.
The git seam is the internal `GitCommandRunning`. `dirtyPaths` replaces reuse of fanout
capture. Local traits come from the app profile `hostTraits` or `--traits` (there is no
`riela config`). `DeterministicDirectorRules.handoverOnInactivity` replaces
`HandoverPolicy.onInactivity`. Placement gets a `requiredTraits` parameter.
`SuspendRecord.reasonKind: SuspendReasonKind`. The GraphQL provider lives in `RielaCLI`.
`output.deliverables` replaces `output.projection.deliverables`.

## Shared-path ledger (sequential ownership across waves)

No two plans in the same wave write the same file. The files below are written
by several plans in *different* waves. Each later plan must fresh-read the file and
make only the edit stated in its `sharedPathNotes`.

| Path | Order of owners |
| --- | --- |
| `Sources/RielaCore/RuntimeStore.swift` | wh-01 (exhaustive-switch arms only) → wh-02 |
| `Sources/RielaCore/DeterministicWorkflowRunner+Events.swift` | wh-01 (arms only) → wh-02 |
| `Sources/RielaWork/DecisionApplier.swift` | wh-01 (arms only) → wh-03 |
| `Sources/RielaCLI/RielaCommand.swift` | wh-01 (`CLIExitCode.suspended`) → wh-15 (task and session kinds) → wh-18 (`serve` kind) |
| `Sources/RielaCLI/WorkflowRunCommand.swift` | wh-02 (suspended exit and hint) → wh-14 (task hooks) |
| `Sources/RielaCLI/SessionCommands.swift` | wh-02 (resume) → wh-15 (`session handover`) |
| `Sources/RielaAddons/RielaAddons.swift` | wh-07 (`riela/git-publish-branch`) → wh-14 (`riela/handover-request`) |
| `Sources/RielaCLI/TaskCommands.swift`, `Sources/RielaCLI/TaskHandoverCommands.swift` | wh-15 → wh-18 |
| `README.md` | wh-17 (example links) → wh-20 (index/docs link) |
| `Sources/RielaCore/SurfaceCatalog+RowsCLI.swift`, `Sources/RielaGraphQL/GraphQLSchemaGenerator.swift`, `Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift`, `Sources/RielaCLI/CLISurfaceEnumeration.swift` | wh-20 only (wh-15 may add the `handover` session subcommand to `CLISurfaceEnumeration.swift` only if that list is hard-coded) |

## Common execution contract (every child plan repeats the essentials)

1. Authority: the design and this umbrella plan. The committed design, all plans and
   this file are committed before native Riela fanout begins. Never
   re-inspect workflow or package registries.
2. There is one branch and one working directory. No worktrees, private branches, stash,
   reset or checkout of another worker's files, and no git state changes (add,
   commit, push) by workers.
3. Before every edit, do a fresh read. Record the SHA-256 (or `ABSENT`), a
   preimage and a write-once intent snapshot under `tmp/work-handover/<planId>/<attempt>/`.
   Re-check the prehash immediately before writing. If it differs, reread and reconcile,
   and never overwrite from a stale snapshot. Record the posthash and the patch.
4. Edit only `writePaths`. For `sharedPaths`, make only the stated intended edit. Any
   other file needs an explicit ownership update recorded in the progress log
   before it is touched. The one pre-authorized exception is wh-01's exhaustive-switch rule.
5. Run every Swift command in the foreground under the arm64 shell, with the full log under
   `tmp/work-handover/<planId>/`. Pattern:
   `arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/<planId>/build.log 2>&1; echo "exit=$?" >> tmp/work-handover/<planId>/build.log'`.
   The following are not a pass: a truncated log, a missing `exit=` line, `0 tests`, or `No matching test cases`.
6. `.build` is shared, so the integration owner serializes builds and tests across
   concurrently editing plans. A compile error in a file outside your `writePaths` that
   another in-flight plan caused is recorded as blocked-by-drift, not "fixed".
7. Workers do not run `SurfaceParity*`, `scripts/surface-parity/generate-sdl.sh`,
   `RielaExampleParityTests` or the full suite. Those belong to wh-17 and wh-20.
   The parity and SDL gates are expected to be red between wh-01 and wh-20
   (new enum values, commands and fields without rows). Record this; do not patch it.
8. Progress log: only your own `impl-plans/progress/<planId>.md`. Record timestamp,
   task status, changed paths, pre/post hashes, intent paths, exact commands, log paths,
   exit status, test names and counts, findings and remaining work. Do not
   mark a task done without evidence. Scratch goes under `tmp/` only and is never committed.
9. No backward compatibility (repo policy): strict decoding, update fixtures, no
   shims. The one exception is a user profile field (wh-10), which uses `decodeIfPresent`
   because it is user configuration, not a store.
10. Imitate the cited existing code. Do not refactor, reformat or rename unrelated
    code. New tests must exercise behavior, not echo constants.

## Module Status

| Plan | Status | Evidence |
| --- | --- | --- |
| wh-00-baseline | COMPLETED | `impl-plans/progress/wh-00-baseline.md` |
| wh-01-contracts | NOT_STARTED | — |
| wh-02 … wh-13 | NOT_STARTED | — |
| wh-14-task-dispatch-runtime | NOT_STARTED | — |
| wh-15 … wh-17 | NOT_STARTED | — |
| wh-18, wh-19 | NOT_STARTED | — |
| wh-20-reconcile | NOT_STARTED | — |

## Verification (global; executed by wh-20)

- `swift build`, and `swiftlint --strict` on every touched Swift file.
- The focused filters of every child plan, rerun serially after the join.
- `scripts/surface-parity/generate-sdl.sh`, then the `SurfaceParity*` suites green, with an empty diff on a second regeneration.
- `.build/debug/riela workflow validate` for the three new examples, and `workflow run --mock-scenario` runs (answer and presence end exit 5 / `suspended`; orphan ends `completed`).
- `RielaExampleParityTests` and `TaskHandoverExampleTests`.
- A full serial `swift test` compared with the wh-00 baseline. Every failure is classified as pre-existing, flake (with evidence) or regression, and regressions are fixed.
- `git diff --check`, plus a check that no scratch files are staged.

## Completion Criteria

- [ ] A task attempt that emits the `handover` envelope ends `suspended`, seals a packet with a stable digest, and `task show` lists it
- [ ] `task answer` + `task takeover` (same store) continues at the resume step with the answer in the step input and the history imported
- [ ] A repository task publishes `riela/task/<id>/g<n>` at handover; a takeover on a second clone materializes it and continues
- [ ] An attempt whose owner is killed is taken over with `--force-orphan` after expiry; the killed owner, if revived, fails with `leaseLost`
- [ ] A presence handover is refused on a host without `userReachable` and accepted on one with it
- [ ] Remote takeover over `/graphql` heartbeats and reports; the controller runs verification and director on the reported outcome
- [ ] kaiba, gitRef, file and command sinks round-trip the packet with digest verification
- [ ] Three examples pass in mock mode (§15.1); skills, docs, catalog rows and SDL updated; full `swift test` has no new failures against the wh-00 baseline

Archive this file and the child plans to `impl-plans/completed/` only when every
box has evidence (wh-20). Otherwise they stay active with an accurate progress log.

## Progress Log

### Session: 2026-09-30 (planning)
**Tasks Completed**: Design reconciled with the source (design §21 R1–R22); the plan was decomposed into wh-00 … wh-20
**Tasks In Progress**: None
**Blockers**: None. Q1–Q8 proceed on their defaults
**Notes**: The baseline (wh-00) must run before any source edit

### Session: 2026-09-30 (run session-228)
**Tasks Completed**: wh-00 baseline at 56aed135: 2778 run, 2775 passed, 2 skipped, 1 failed (`WorkflowCommandCrossWorkflowDispatchTests.testSubprocessAbruptTerminationCheckpointsReopenCanonicalSQLiteWithoutDuplicatingDurableEffect`, 180 s scratch-build subprocess timeout). Logs under `tmp/work-handover/wh-00/`.
**Blockers**: The run stopped because the branch progress check treats a failing full-suite command as materially unverified, even for the baseline plan whose job is to record failures.
**Notes**: wh-00 was removed from the dispatch DAG. The wh-20 full-suite gate is now a baseline-comparison command (exit 0 iff no failure outside the wh-00 baseline); the raw `swift test` exit is reported as `suiteExit`.

## Related Plans

- **Previous**: `impl-plans/active/work-runtime-p1-*.md` (shipped P1 dispatcher, reservation, guard, director)
- **Next**: Work Runtime P4 (`ChangeRuntime` beyond the branch slice), P5 (full GraphQL task API)
- **Aligns With**: `impl-plans/active/execution-environment-consolidation.md` (E2 adopts `riela/task/*` and `refs/riela/handovers`)
