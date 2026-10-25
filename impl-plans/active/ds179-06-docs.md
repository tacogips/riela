# DS179-06 Documentation: Definition Store and Execution-Mode Policy

**planId**: `ds179-06-docs`
**Status**: Ready for implementation
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
