# DS179-04 `riela workflow definition` CLI Surface

**planId**: `ds179-04-cli-definition-commands`
**Status**: Ready for implementation
**Workflow Mode**: issue-resolution
**Issue Reference**: tacogips/riela#179 section 2 + execution-mode policy + (A) whole-workflow CLI update with mandatory reason
**Design Reference**: `design-docs/specs/design-workflow-definition-store.md` §5 (operations incl. `update`), §7, §8 (CLI incl. `update` result and error codes), §11; QA Q1 (reversed for CLI/GraphQL), Q3 (actor kinds)
**dependsOn**: `ds179-03-service-resolution`
**Branch**: `feat/definition-store-179` (local commits only; `gitPush=false`)
**Progress log**: `impl-plans/progress/ds179-04-cli-definition-commands.md`

## Intent and context

This plan adds the admin CLI on top of plan 02's `WorkflowDefinitionService`.
The CLI must keep the CLI surface-parity gate green. That means a
`SurfaceCatalog` row for every new command, added in this plan, with
GraphQL marked blocked until plan 05 binds it.

Commands (exact grammar):

```
riela workflow definition history <workflow> [--node <id>] [--limit <n>]
riela workflow definition show <workflow> [--version <id>] [--node <id>] [--authored]
riela workflow definition diff <workflow> [--from <versionId>] [--to <versionId> | --file]
riela workflow definition update <workflow> (--patch <json-patch-file> | --from-file <workflow.json|dir> [--force]) --reason <r> [--expected-version <id>] [--evidence <kind:id>]... [--actor <id>] [--actor-kind cli|improvementNode]
riela workflow definition update-prompt <workflow> --node <id> --field <field> (--text <s> | --text-file <path>) --reason <r> [--expected-version <id>] [--evidence <kind:id>]... [--actor <id>] [--actor-kind cli|improvementNode]
riela workflow definition restore <workflow> --version <id> --reason <r> [--evidence <kind:id>]... [--actor <id>]
riela workflow definition import <workflow> [--workflow-definition-dir <dir>] [--force --reason <r>] [--evidence <kind:id>]... [--actor <id>]
riela workflow definition export <workflow> [--version <id>] (--to <dir> | --to-source --overwrite)
```

Common options on every command:

- `--session-store <dir>`
- `--scope project|user`
- `--working-dir <dir>`
- `--output text|json`

Repository patterns to imitate:

- **Subcommand enum.** `WorkflowClientSubcommand`
  (`Sources/RielaCLI/RielaClientFamilyArguments.swift:16`). Add a
  `definition` case.
- **Nested family enum.** Follow `WorkflowManifestClientSubcommand`, which
  the surface enumerator expands at `Sources/RielaCLI/CLISurfaceEnumeration.swift:51-54`.
  Add a matching `case .definition:` that expands
  `WorkflowDefinitionClientSubcommand.allRawValues`.
- **Parsing.** `parseWorkflow` (`Sources/RielaCLI/RielaCommand.swift:507`)
  routes `.versions/.version/.restore` through `parseWorkflowVersionCommand`
  (`Sources/RielaCLI/RielaArgumentParser+WorkflowAndMemory.swift:6`) and the
  `ParsedWorkflowVersionsArguments` pattern (`RielaClientFamilyArguments.swift:229`).
  The command enum has `case version(WorkflowVersionCommandOptions)`
  (`RielaCommand.swift:142`).
- **Dispatch and help.** Dispatch is in `Sources/RielaCLI/RielaCLIApplication.swift:196`
  (`workflowVersionCommand.run(options)`). The help text is at
  `RielaCLIApplication.swift:318`. Add the 8 lines next to
  `riela workflow versions`.
- **Command runner.** Imitate `Sources/RielaCLI/WorkflowVersionCommands.swift`
  for output formatting (text and json) and for `CLICommandResult` exit
  codes.
- **Catalog rows.** Imitate the `workflow.versions/version/restore` rows at
  `Sources/RielaCore/SurfaceCatalog+Rows.swift:170-172`.

## Non-goals

- No GraphQL (plan 05), no docs (plan 06) and no improvement add-ons
  (plan 07).
- Do not change `riela workflow update` (`WorkflowRegistryCLICommand.swift:40`).
  It stays the mutable-registry file command (design §11). The audited
  store update is only `riela workflow definition update`.
- Do not change `riela workflow run`, `versions` or `restore`.

## File-level changes

1. **`RielaClientFamilyArguments.swift`.** Add `case definition` to
   `WorkflowClientSubcommand`. Add
   `enum WorkflowDefinitionClientSubcommand: String, CaseIterable { case history, show, diff, update, updatePrompt = "update-prompt", restore, `import`, export }`
   with `allRawValues`.
2. **`Sources/RielaCLI/WorkflowDefinitionArguments.swift` (new).**
   - Parsed-argument structs per operation, following the
     `RielaClientFamilyArguments` pattern used by `ParsedWorkflowVersionsArguments`.
   - `--evidence` is repeatable.
   - `--text` and `--text-file` are mutually exclusive, and exactly one is
     required.
   - `--to` and `--to-source` are mutually exclusive, and exactly one is
     required.
   - `--to-source` without `--overwrite` is a usage error.
   - `--force` without `--reason` is a usage error, as is `--reason` blank
     after trimming on update-prompt or restore.
   - `--from`/`--to` together with `--file` is a usage error.
   - `--scope` accepts only `project` or `user`.
   - **`update`:**
     - Exactly one of `--patch` and `--from-file` is required; both or
       neither is a usage error.
     - `--force` is allowed only with `--from-file`.
     - `--reason` is required and must be non-blank after trimming. A
       missing or blank reason is a usage error (exit 2, JSON error code
       `reason_required`).
   - **`--actor-kind`** on `update` and `update-prompt` accepts only `cli`
     (the default) or `improvementNode`; anything else, including `user`,
     `api` and `addon`, is a usage error. `--expected-version` takes a
     non-empty id.
   - **`show --authored`** prints `authoredView` instead of the document.
     Combined with `--node`, it is a usage error.
   - Produce `WorkflowDefinitionCommandOptions { operation; workflowName; ...; sessionStore; scope; workingDirectory; output }`.
3. **`RielaCommand.swift`.** Add `case workflowDefinition(WorkflowDefinitionCommandOptions)`
   and route `.definition` in `parseWorkflow`. Re-read the file fresh,
   because plan 03 edited it.
4. **`RielaCLIApplication.swift`.** Add a `workflowDefinitionCommand` property,
   dispatch it, and add the help lines.
5. **`CLISurfaceEnumeration.swift`.** Add the `.definition` expansion, giving
   8 descriptors `["workflow","definition",<op>]`.
6. **`Sources/RielaCLI/WorkflowDefinitionCommand.swift` (new).**
   `struct WorkflowDefinitionCommand { func run(_ options: WorkflowDefinitionCommandOptions) -> CLICommandResult }`.
   - **Store root:**
     - With `--session-store`, or with `--scope` given explicitly, use the
       single root from `WorkflowDefinitionStoreSelection.candidateRoots(...)`.
     - Otherwise, read operations and update-prompt/restore/export use the
       first candidate root that has a head (project, then user). If none
       has a head, they fail with "workflow <name> is not registered in the
       definition store".
     - `import` uses the root that already has the head if one exists.
       Otherwise it uses `WorkflowDefinitionStoreSelection.seedRoot(...)`
       for the file-resolved bundle.
     - Put this selection in `Sources/RielaCLI/WorkflowDefinitionStoreSelection.swift`
       (a shared path; plan 03 created it) as
       `static func rootWithHead(workflowName: String, sessionStore: String?, scope: WorkflowScope, workingDirectory: String, environment: [String: String]) throws -> String?`.
       Plan 05 reuses it. Do not inline it in the command.
   - **Actor:** the kind is `--actor-kind` (default `.cli`); the id is
     `--actor`, or `NSUserName()`.
   - **`update`:**
     - `update` and `update-prompt` use the first root with a head; there
       is no seeding.
     - `--patch <file>` reads the file relative to `--working-dir` and
       decodes it as a `JSONValue` array. Unreadable or non-JSON input →
       exit 1, `invalid_patch`. Call `service.update(source: .patch(...))`.
     - `--from-file <path>` without `--force`:
       - Let `dir` be `path` if it is a directory, else its parent; a
         non-directory path must be named `workflow.json`.
       - Call `service.update(source: .fromDirectory(WorkflowResolutionOptions(workflowName: <workflow>, scope: .direct, workflowDefinitionDir: dir, workingDirectory: <working-dir>)))`.
       - If `<dir>/<workflow>/workflow.json` also exists, exit 2 ("ambiguous
         --from-file directory"), because the resolver would prefer that
         child.
     - `--from-file <path> --force` calls
       `service.importDefinition(resolution: <the same options>, force: true, ...)`.
       It is exactly `import --force --workflow-definition-dir <dir>`
       (design §5), so the output is the import result.
     - `--expected-version` is passed to `update`/`updatePrompt` as
       `expectedVersionId`.
   - **JSON error shape** for every failing `definition` command with
     `--output json`: stdout is
     `{"accepted":false,"error":{"code":"<code>","message":"<msg>"}}`.
     - `code` is the plan 02 `WorkflowDefinitionServiceError.Code` raw
       value, or `usage_error`, or the store error code.
     - Exit 2 for usage errors and `reason_required` caught in the parser;
       exit 1 otherwise.
     - Plan 07 parses this shape. Pin it exactly.
   - **`update` JSON success:** `{"accepted":true,"outcome":"updated|unchanged","versionId":...,"digest":...,"auditId":...,"diff":[...]}`.
     `auditId` is null when the outcome is unchanged.
   - `--text-file` reads UTF-8 text from the path relative to
     `--working-dir`.
   - **Output.**
     - `--output json` prints the service result encoded with sorted keys:
       audit records, the version, the diff, the import outcome, and the
       exported paths.
     - Text output prints one line per audit record:
       `<createdAt> <operation> <versionId> <actor.kind>:<actor.id> node=<n> field=<f> reason=<r>`.
       For diffs it prints one line per entry, `<op> <path>`, followed by
       indented before and after values.
   - **Exit codes:**
     - 0 on success, including a non-force import that reports `differs`
     - 2 for usage errors (match the existing `CLIUsageError` code)
     - 1 for store and validation errors, with the message on stderr
7. **`SurfaceCatalog+Rows.swift`.** Add 8 rows:
   `workflow.definition.history|show|diff|update|update-prompt|restore|import|export`.
   - family `workflow`
   - kind `.query` for history, show and diff; `.mutation` for the rest
   - `cli: "workflow definition <op>"`
   - Pass `graphqlState: .blocked(evidence: "ds179-05-graphql-definition-surface binds the GraphQL field")`
     to `surfaceRow` (`Sources/RielaCore/SurfaceCatalog+RowSupport.swift:88`,
     parameter `graphqlState`). Do not pass `graphql:` yet.
   - `cliOptions` may list only flags that the parser accepts.
     `testGateFailsForAnUnknownOptionOnACatalogRow` rejects anything else.

## Invariants

- No command writes rows except `update`, `update-prompt`, `restore` and
  `import` (seed or force).
- `riela workflow update` output and behavior are byte-for-byte unchanged.
- A non-force import against a registered head changes no rows and exits 0.
- Rejected input writes nothing.
- `riela workflow run` behavior is unchanged.

## Pitfalls

- Validate `--force`/`--reason` in the parser, not after a store open.
- Do not add the GraphQL binding here. That would fail
  `SurfaceParityGraphQLTests` until plan 05 adds the SDL.
- `import` resolution must use the same scope and `--workflow-definition-dir`
  rules as `riela workflow run`, through `FileSystemWorkflowBundleResolver`.
- Export `--to-source` writes into the head's recorded source directory.
  Never infer that directory from `--working-dir`.

## Tests

Add `Tests/RielaCLITests/WorkflowDefinitionCommandTests.swift`. Invoke
commands through the same application or parser entry point that
`Tests/RielaCLITests/WorkflowVersionCommandsTests.swift` uses, and use a
temporary project with `--session-store <tmp>`.

- `import w` → exit 0, JSON outcome `seeded`.
- `import w` again → outcome `unchanged`.
- Edit the prompt file, then `import w` → outcome `differs`, a non-empty
  diff, and row counts unchanged (query the four tables before and after).
- `import w --force` → usage error, exit 2, no rows.
- `update-prompt w --node A --field promptTemplate --text X --reason r --evidence session:s1`
  → exit 0. `history w --output json` has the newest record with
  `reason == "r"`, `actor.kind == "cli"` and evidence `[session:s1]`.
- `update-prompt` without `--reason` → exit 2.
- `update-prompt ... --field bogus` → exit 1, no rows.
- `import w --force --reason "sync"` → outcome `forceUpdated` and
  `overwrittenChanges.auditIds` contains the update-prompt audit.
  `restore w --version <updatePromptVersion> --reason back` → `show w`
  reports A's prompt as `X`.
- `diff w --from <v1> --to <v2>` lists `/runtime/nodePayloads/A/promptTemplate`.
- `export w --to <emptyTmp>` writes `workflow.json` and the prompt file.
  `export w --to-source` without `--overwrite` → exit 2.
  `export w --to-source --overwrite` followed by `import w` → `unchanged`.
- `show w --version <unknown>` → exit 1.
- **`update --patch`**
  - **Success.** `update w --patch p.json --reason "tighten" --evidence session:s1 --evidence stepExecution:e1 --actor bot --actor-kind improvementNode --output json`
    → exit 0 and outcome `updated`. `history w --output json` newest is
    operation `update`, `reason == "tighten"`, `actor == {improvementNode, bot}`,
    and both evidence refs. `diff w --from <prev> --to <new>` lists the
    patched pointer.
  - **Missing reason.** `update w --patch p.json` without `--reason` → exit
    2, JSON `error.code == "reason_required"`, row counts unchanged.
  - **Both sources.** `update w --patch p.json --from-file d --reason r` →
    exit 2.
  - **Force without from-file.** `update w --patch p.json --force --reason r`
    → exit 2.
  - **Stale version.** `update w --patch p.json --reason r --expected-version <old>`
    → exit 1, `error.code == "definition_conflict"`, no rows.
  - **Disallowed actor kind.** `update w ... --actor-kind api` → exit 2.
- **`update --from-file`**
  - **Without force.** Export to a temp dir, edit its prompt, then
    `update w --from-file <tmp>/w/workflow.json --reason r` → outcome
    `updated`, operation `update`.
  - **With force.** `update w --from-file <srcdir> --force --reason sync`
    → import outcome `forceUpdated`.
- **Unregistered workflow.** `update unregistered --patch p.json --reason r`
  → exit 1, `error.code == "definition_not_registered"`.
- **`show w --authored --output json`** contains `"workflow.json"` as an
  object.
- **`riela workflow update` is untouched.** `WorkflowMutableRegistryTests`
  and `WorkflowRegistryEvolutionTests` still pass (they run in the
  verification below).
- `SurfaceParityCLITests` passes with the new rows.

## Verification (each command must exit 0)

- `arch -arm64 /bin/zsh -lc 'swift build 2>&1 | tee tmp/ds179/04-build.log'`
- `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowDefinitionCommandTests|SurfaceParityCLITests|SurfaceCatalogTests|WorkflowVersionCommandsTests|WorkflowMutableRegistryTests|WorkflowRegistryEvolutionTests" 2>&1 | tee tmp/ds179/04-test.log'`.
  Record testsRun and failureCount.
- `arch -arm64 /bin/zsh -lc 'swift test --filter SurfaceParity 2>&1 | tee tmp/ds179/04-parity.log'`
  must pass with GraphQL blocked rows.
- `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet <every changed .swift file>'`
  must print no violations.

## Done criteria

- `grep -n "workflow.definition.import" Sources/RielaCore/SurfaceCatalog+Rows.swift`
  matches.
- `grep -n "riela workflow definition" Sources/RielaCLI/RielaCLIApplication.swift`
  gives 8 or more lines.
- `grep -n "workflow.definition.update\"" Sources/RielaCore/SurfaceCatalog+Rows.swift`
  matches.
- `git diff --quiet -- Sources/RielaCLI/WorkflowRegistryCLICommand.swift`
  exits 0, so the registry `update` command is unchanged.
- All verification commands exit 0. Each is logged with exitStatus,
  testsRun, failureCount and the log path.

## Progress log expectations

Log each edit in `impl-plans/progress/ds179-04-cli-definition-commands.md`
with the pre-edit and post-edit sha256. Re-read `RielaCommand.swift` and
`SurfaceCatalog+Rows.swift` fresh before each edit, because plan 05 edits
the catalog rows next.
