# eh-11-catalog-help-docs: CLI catalog rows, help text, user docs, the surface-parity gate

```json
{
  "planId": "eh-11-catalog-help-docs",
  "planPath": "impl-plans/active/efficient-history-11-catalog-help-docs.md",
  "dependsOn": ["eh-08-memory-surfaces", "eh-09-definition-surfaces", "eh-10-storage-commands"],
  "wave": 5,
  "writePaths": [
    "Sources/RielaCore/SurfaceCatalog+RowsCLI.swift",
    "Sources/RielaCLI/RielaCLIApplication.swift",
    "Tests/RielaCLITests/SurfaceParityCLITests.swift",
    "Sources/RielaCLI/CLISurfaceEnumeration.swift",
    "Sources/RielaCLI/RielaClientFamilyArguments.swift",
    "docs/evolution-history.md",
    "docs/memory-history-retirement.md",
    "docs/workflow-definition-store.md",
    "docs/session-cancellation-and-reconcile.md",
    "docs/terminal-retention.md",
    "docs/storage-doctor-and-compact.md",
    "impl-plans/progress/eh-11-catalog-help-docs.md"
  ],
  "sharedPaths": [],
  "sharedPathNotes": [
    {"path": "Sources/RielaCLI/RielaCLIApplication.swift", "intendedEdit": "Usage/help text only (memory lines ~:357-364, doctor ~:338, workflow definition lines, new storage compact line, session reconcile flag). Do not touch the eh-10 dispatch cases."},
    {"path": "Tests/RielaCLITests/SurfaceParityCLITests.swift", "intendedEdit": "Only if it hard-codes command/flag lists that must include the new commands; never weaken a parity assertion."},
    {"path": "Sources/RielaCLI/CLISurfaceEnumeration.swift", "intendedEdit": "Move doctor from leafRoutes to expandedRoutes with an expansion [doctor] + [doctor storage]; add the storage route expanding StorageClientAction (eh-10); register ParsedStorageCommandArguments.helpMessage() and the workflow-definition hand-parsed option sets in optionNames()."},
    {"path": "Sources/RielaCLI/RielaClientFamilyArguments.swift", "intendedEdit": "Add `case undo` and `case redo` to WorkflowDefinitionClientSubcommand (enumeration-only enum; raw values match the eh-09 parser tokens). No other edit."}
  ]
}
```

## Intent and context

Design §9 (catalog) and §12 (docs). Earlier plans added these CLI surfaces:

- **eh-08:** `memory undo|redo`, `--diff-against`, `--history-retention`.
- **eh-07:** `session reconcile --abandoned-after-hours`.
- **eh-10:** `doctor storage`, `storage compact`.
- **eh-09:** the definition rows and the SDL; this plan does not touch them.

The surface-parity gates require catalog rows and help text for every CLI
command and flag.

Patterns:

- `memoryRows` and `memoryDefaults` in `SurfaceCatalog+RowsCLI.swift:19-23,245-267`;
- `doctor.report` and `gc.sweep` rows at `:349-350` (`localToolDefaults`);
- the `session.reconcile` row in `SurfaceCatalog+Rows.swift:253`. eh-09
  already added `--abandoned-after-hours` to it. Do not edit that file.

How the CLI gate works (EH5-F1). `SurfaceParityCLITests` checks a
bijection between `CLISurfaceEnumerator.commands()` and the catalog
`cli` values (`SurfaceParityCLITests.swift:10,78`), requires
`CLISurfaceEnumerator.unclassifiedRoutes()` to be empty (`:103-109`), and
requires every catalog `cliOptions` entry to resolve in
`CLISurfaceEnumerator.optionNames()` (`:58`, `:125`). Today:

- `doctor` is in `leafRoutes` (`CLISurfaceEnumeration.swift:116`), so only
  `doctor` is enumerated.
- eh-10 registers a new `storage` router route that is in neither set, so
  `unclassifiedRoutes() == ["storage"]`.
- `workflow definition *` commands come from
  `WorkflowDefinitionClientSubcommand.allRawValues` (`:55-58`), and that
  enum (`RielaClientFamilyArguments.swift:71-80`) has no `undo`/`redo`. It
  is used only by the enumerator, not by the parser
  (`grep -rn WorkflowDefinitionClientSubcommand Sources` → 2 hits).
- `optionNames()` (`:140-178`) reads only the listed `ParsableArguments`
  help messages plus hand-listed tokens. The workflow-definition parser is
  hand-rolled (`ParsedWorkflowDefinitionCommand.valueOptions` /
  `flagOptions`, `WorkflowDefinitionArguments.swift:29-34`) and is not
  registered.

After eh-09 (wave 3) and eh-10 (wave 4) the gate is therefore red until this
plan lands. Flag sources from earlier plans: `--history-retention` and
`--diff-against` come from `ParsedMemoryOptions` (eh-08), already listed in
`optionNames()`; `--abandoned-after-hours` comes from
`ParsedSessionReconcileArguments` (eh-07), already listed; the storage flags
come from `ParsedStorageCommandArguments` (eh-10, `StorageRoots.swift`).

## Non-goals

- No behavior changes.
- Do not change the existing `doctor` command output (eh-10 non-goal) or
  the `doctor.report` row's `cli: "doctor"` value.
- No GraphQL or SDL change (eh-09 owns them).
- No README or skill updates.

## File-level changes

- **`RielaClientFamilyArguments.swift`.** Add `case undo` and `case redo`
  to `WorkflowDefinitionClientSubcommand`, right after `restore`. Raw values
  `undo`/`redo` must equal the operation tokens eh-09 accepts in
  `WorkflowDefinitionArguments.swift`. No other edit in this file.
- **`CLISurfaceEnumeration.swift`:**
  1. Remove `"doctor"` from `leafRoutes` and add it to `expandedRoutes`.
     Add `case "doctor": return [CLICommandDescriptor([route]), CLICommandDescriptor([route, "storage"])]`
     to `expand(route:)`.
  2. Add `"storage"` to `expandedRoutes` and
     `case "storage": return nested(StorageClientAction.allRawValues)`
     (eh-10 enum; yields `storage compact`).
  3. In `optionNames()`, add `ParsedStorageCommandArguments.helpMessage()`
     to the help-message array, and
     `names.formUnion(ParsedWorkflowDefinitionCommand.valueOptions)` plus
     `names.formUnion(ParsedWorkflowDefinitionCommand.flagOptions)` next to
     the hand-parsed block, with a one-line comment ("workflow definition
     options are parsed by hand").
  4. Only list `cliOptions` on catalog rows that `optionNames()` resolves.
     Check each new option against it before finishing.
- **`SurfaceCatalog+RowsCLI.swift`:**
  - `memory.undo` and `memory.redo` rows (kind `.mutation`, `memoryDefaults`,
    with cliOptions `--memory-root`, `--record-id`,
    `--expected-head-version`, `--output`);
  - add `--history-retention` to the save/update/restore-version rows and
    `--diff-against` to show-version;
  - `doctor.storage` (`.query`, `localToolDefaults`, `cli: "doctor storage"`);
  - `storage.compact` (`.process`, `localToolDefaults`).
- **`RielaCLIApplication.swift` usage text.** Document the new commands and
  flags in the same terse style as the neighboring lines.
- **Docs.** Plain text; no marketing.
  - `evolution-history.md`:
    - the new storage (compressed full or splice, no base64);
    - `historyRetention` defaults 2/1 and the range;
    - revision vs version;
    - undo/redo;
    - the shared diff;
    - `version_not_retained`;
    - legacy rows readable, with conversion on write or via compact;
    - remove the sentence "Automatic history retention/pruning is not
      implemented."
  - `memory-history-retirement.md`: default retention makes manual
    retirement rarely needed. For new-format records, retirement drops all
    non-head versions.
  - `workflow-definition-store.md`:
    - the window of 10 (with config key and flag);
    - the pins (the head, last-file version, live sessions, 24-hour former
      heads);
    - guarded deletes, and that they are not a security boundary;
    - the audit-row rule;
    - undo/redo on the CLI and GraphQL;
    - `definition_version_not_retained`;
    - `pendingBackfill`.
  - `session-cancellation-and-reconcile.md`: abandoned nested invocations
    and `--abandoned-after-hours`.
  - `terminal-retention.md`: execution rows and payload bytes, and family
    payload deletion.
  - New `storage-doctor-and-compact.md`:
    - the session-storage model (one canonical copy, execution rows,
      payload dedupe per family, nested refs);
    - the doctor report fields;
    - the compact steps, dry run and resumability;
    - the VACUUM free-space requirement;
    - the run-end bounded vacuum.

## Tests and verification

Test cases (add to `SurfaceParityCLITests.swift` without changing any
existing assertion, the `unclassifiedRoutes` gate or the dummy-descriptor
negative tests):

- `CLISurfaceEnumerator.commands().map(\.command)` → contains
  `workflow definition undo`, `workflow definition redo`, `doctor`,
  `doctor storage` and `storage compact`.
- `CLISurfaceEnumerator.unclassifiedRoutes()` → `[]`.
- `CLISurfaceEnumerator.optionNames()` → contains `--history-retention`,
  `--diff-against`, `--abandoned-after-hours`, `--max-batch`, `--top`,
  `--kv-root`, `--cache-root` and `--expected-revision`.
- The existing bijection test passes with the new rows (no
  "declared but not actual" and no "actual but not declared").

Do not hand-list the new commands in a test to bypass the enumerator.

```
arch -arm64 /bin/zsh -lc 'swift test --filter "SurfaceParity|CommandParsingTests"' > tmp/efficient-history/eh-11-catalog-help-docs/test.log 2>&1; echo $?
arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet --no-cache Sources/RielaCore/SurfaceCatalog+RowsCLI.swift Sources/RielaCLI/RielaCLIApplication.swift Sources/RielaCLI/CLISurfaceEnumeration.swift Sources/RielaCLI/RielaClientFamilyArguments.swift Tests/RielaCLITests/SurfaceParityCLITests.swift'
grep -n "Automatic history retention/pruning is not implemented" docs/evolution-history.md   # expect exit 1
git diff --check -- docs                                                                    # expect no output
```

Expected: exit 0 for the tests and lint. All `SurfaceParity*` suites
execute and pass.

## Done criteria

- [ ] Every new CLI command and flag has a catalog row or option and help
      text. SurfaceParity is green, with `SurfaceParityCLITests` executed
      (non-zero test count in the log) and no existing assertion removed
      (`git diff Tests/RielaCLITests/SurfaceParityCLITests.swift` shows
      additions only).
- [ ] `grep -n '"doctor"' Sources/RielaCLI/CLISurfaceEnumeration.swift`
      shows `doctor` in `expandedRoutes` and not in `leafRoutes`;
      `grep -n "case undo\|case redo" Sources/RielaCLI/RielaClientFamilyArguments.swift`
      matches both.
- [ ] The six docs are updated or created as listed. `git diff --check` is
      clean.
- [ ] The progress log is complete.
