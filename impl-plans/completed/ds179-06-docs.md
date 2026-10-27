# DS179-06 Documentation: Definition Store and Execution-Mode Policy

**planId**: `ds179-06-docs`
**Status**: Implementation complete; formal review pending
**Workflow Mode**: issue-resolution
**Issue Reference**: tacogips/riela#179 section 2 + execution-mode policy + (A) whole-workflow update + (B) improvement node
**Design Reference**: `design-docs/specs/design-workflow-definition-store.md` §1, §5, §7, §8, §9, §10, §11
**dependsOn**: `ds179-07-improvement-node` (the last plan of the serial chain 01→02→03→04→05→07→06)
**Branch**: `feat/definition-store-179` (local commits only; `gitPush=false`)
**Progress log**: `impl-plans/progress/ds179-06-docs.md`

## Intent and context

The acceptance criteria require docs that describe the service-vs-CLI
resolution policy and the `riela workflow definition` CLI. The README has
topic sections such as `## Runtime Data Retention` (around line 676) and
`## Routines` (around line 904). Topic docs live under `docs/`, for example
`docs/terminal-retention.md` and `docs/work-handover.md`.

## Non-goals

- No source or test changes.
- Do not edit design-docs/specs; the design is accepted.
- No skill-doc edits outside this repository.

## File-level changes

1. **`docs/workflow-definition-store.md` (new).** Write it from the shipped
   behavior, after re-reading the implemented commands, which are the source
   of truth. Cover:
   - The §1 policy table: service paths (GraphQL `executeWorkflow`, RielaApp
     configured runs, `events serve` including cron, routines and daemon
     workflows) versus one-time paths.
   - Seed on first use. Registered workflows ignore file edits, and so do
     registry and editor saves until `import --force` or `update
     --from-file` (user QA Q1).
   - `import` (unchanged/differs), `import --force --reason`, overwritten
     changes, `restore`.
   - `update` (A): `--patch` (RFC 6902 over the authored view, `show
     --authored`), `--from-file` and `--from-file --force`, the mandatory
     `--reason`, `--expected-version`, `--evidence`, `--actor` and
     `--actor-kind`, and the JSON result and error codes.
   - `riela workflow update` stays the mutable-registry file command
     (design §11).
   - `update-prompt` field names and the shared-prompt-file rule.
   - The audit record fields, the actor kinds
     `user|cli|api|improvementNode` and `approval_state = applied`.
   - **Builtin improvement node (B):**
     - the `riela/improve-workflow-context` and `riela/improve-workflow-apply`
       config keys and output payloads
     - the three-node shape, the one-time-run skip and the recursion guard
     - the CLI-subprocess-only apply
     - a pointer to `examples/definition-store-self-improvement`
   - The `definitionSource` pin on sessions (store versus file).
   - Export (`--to`, `--to-source --overwrite`; GraphQL `writeToSource`).
   - A GraphQL field list.
   - Schema generation 10 with the in-place migration, and that stores
     holding definitions are never auto-discarded.
2. **`README.md`.**
   - Add a short `## Workflow Definition Store (service vs one-time runs)`
     section, 15-30 lines, right before `## Runtime Data Retention`. It
     gives the policy table, three example commands, and a link to
     `docs/workflow-definition-store.md`.
   - If `## Control Surfaces` lists workflow commands, add
     `riela workflow definition` there too.

## Invariants

- Every command and flag shown appears in `riela --help` output, or in the
  parser.
- The docs name `riela workflow definition update` as the audited
  whole-workflow store update. They never say that `riela workflow update`
  writes the store.

## Verification (each command must exit 0)

- `arch -arm64 /bin/zsh -lc 'swift build 2>&1 | tee tmp/ds179/06-build.log'`
- `arch -arm64 /bin/zsh -lc '.build/debug/riela --help 2>&1 | tee tmp/ds179/06-help.log | grep -c "riela workflow definition"'`
  must print 8 or more.
- For each command in the docs, check that it appears in
  `tmp/ds179/06-help.log`:
  `grep -o "riela workflow definition [a-z-]*" docs/workflow-definition-store.md | sort -u`
- `arch -arm64 /bin/zsh -lc 'swift test --filter SurfaceParitySkillTests 2>&1 | tee tmp/ds179/06-skill-parity.log'`.
  This catches documented flags that the parser does not accept, if the
  gate scans docs.

## Done criteria

- `docs/workflow-definition-store.md` exists.
- `grep -n "riela workflow definition update" docs/workflow-definition-store.md`
  and `grep -n "riela/improve-workflow-apply" docs/workflow-definition-store.md`
  both match.
- `grep -n "Workflow Definition Store" README.md` matches.
- Every verification command exits 0. The progress log records exitStatus,
  testsRun and failureCount (0/0 where no tests ran) and the log paths.

## Progress log expectations

Log both file edits in `impl-plans/progress/ds179-06-docs.md` with the
pre-edit and post-edit sha256. Re-read `README.md` fresh before editing.

## Implementation completion

- Added `docs/workflow-definition-store.md` from the implemented CLI, GraphQL
  schema and improvement example. It documents the service/file policy, store
  seeding and force operations, audited definition and prompt writes, addon
  behavior, pins, export, GraphQL fields and schema generation 10.
- Added the README policy section before Runtime Data Retention with the guide
  link and CLI examples. `riela workflow update` is explicitly described as a
  file-based mutable-registry command.
- Build, CLI help and command coverage, documentation checks, diff check and
  `SurfaceParitySkillTests` passed; see
  `impl-plans/progress/ds179-06-docs.md` for command exits, counts and logs.
- Formal review and workflow finalization are downstream steps.


## Operator amendment 1 (after session-494 blocked wave)

- ds179-01-store-core is accepted and committed in 6337aa24. The definition store API now returns
  `WorkflowDefinitionCurrent` (struct with head/version/document) from `current(workflowName:)`, and
  `WorkflowDefinitionDiffEntry.Op` was renamed to `WorkflowDefinitionDiffEntry.Operation`.
- Known pre-existing failures on main f4fcf68c (not caused by this work; exclude them from gates with
  `--skip` and never treat them as blockers): `DeterministicWorkflowRunnerFailureStateTests.testRetryFailedStepErrorNamesTimeoutForCompletedSession`,
  `HandoverContractsTests.testSessionSuspendAndClosedStatusRoundTrip`, `SessionObservabilityTests.testTransitionalCancelledFailureKindIsTerminal`.
  `DeterministicWorkflowRunnerFanoutTests.testProductionCollectPartialPersistsCancelledChildBeforePublishingJoin` is timing-flaky under
  full-suite load and passes in isolation.

## Operator amendment 2 (after session-498 blocked wave)

- ds179-02 and ds179-03 are accepted (commit 695c0af9). `Resources/skills/riela-workflow-run/SKILL.md` is owned by ds179-04; it is a sharedPath of this plan: if this plan adds CLI catalog rows, update the generated command blocks in that file so SurfaceParitySkillTests stays green.
