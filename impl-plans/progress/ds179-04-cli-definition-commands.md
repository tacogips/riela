# ds179-04 CLI definition commands progress

Workflow mode: issue-resolution  
Issue: tacogips/riela#179  
Plan: ds179-04-cli-definition-commands  
Branch: feat/definition-store-179  
Dependency readiness: ds179-03-service-resolution appears in the runtime-owned acceptedPlanIds for this dispatch.

## Implementation

Implemented the riela workflow definition route and all eight operations:
history, show, diff, update, update-prompt, restore, import, and export.
Added strict command grammar and usage validation, the pinned JSON error
envelope, update result fields, actor/evidence handling, authored view
output, and the plan's store-root selection seam. Added eight
SurfaceCatalog rows with GraphQL blocked pending ds179-05. Existing
riela workflow update remains unchanged.

Added app-level tests for seeded/unchanged/differs/forceUpdated imports,
prompt update audit evidence, restore, authored show, diff, directory and
source export, JSON Patch and from-file updates, stale versions,
unregistered workflows, usage errors, no-write row counts, and all eight
surface routes.

## Files

- Sources/RielaCLI/RielaClientFamilyArguments.swift
- Sources/RielaCLI/WorkflowDefinitionArguments.swift
- Sources/RielaCLI/RielaArgumentParser+WorkflowAndMemory.swift
- Sources/RielaCLI/RielaCLIApplication.swift
- Sources/RielaCLI/CLISurfaceEnumeration.swift
- Sources/RielaCLI/WorkflowDefinitionCommand.swift
- Sources/RielaCLI/RielaCommand.swift (shared with ds179-03; read fresh before editing)
- Sources/RielaCLI/WorkflowDefinitionStoreSelection.swift (shared with ds179-03; read fresh before editing)
- Sources/RielaCore/SurfaceCatalog+Rows.swift
- Tests/RielaCLITests/WorkflowDefinitionCommandTests.swift

Per-edit intent records and pre-edit hashes are under
tmp/ds179/ds179-04-cli-definition-commands/attempt-001/. Final changed-source
identity is recorded in
tmp/ds179/ds179-04-cli-definition-commands/attempt-003/pre-verification-sha256.txt.

## Verification

| Command | Exit | Tests | Failures | Evidence |
| --- | ---: | ---: | ---: | --- |
| arch -arm64 /bin/zsh -lc 'swift build > tmp/ds179/ds179-04-cli-definition-commands/attempt-003/build.log 2>&1; exit_status=$?; print -r -- EXIT_STATUS=$exit_status; exit $exit_status' | 0 | 0 | 0 | tmp/ds179/ds179-04-cli-definition-commands/attempt-003/build.log |
| arch -arm64 /bin/zsh -lc "swift test --filter 'WorkflowDefinitionCommandTests|SurfaceParityCLITests|SurfaceCatalogTests|WorkflowVersionCommandsTests|WorkflowMutableRegistryTests|WorkflowRegistryEvolutionTests' > tmp/ds179/ds179-04-cli-definition-commands/attempt-003/focused-tests.log 2>&1; exit_status=\$?; print -r -- EXIT_STATUS=\$exit_status; exit \$exit_status" | 0 | 39 | 0 | tmp/ds179/ds179-04-cli-definition-commands/attempt-003/focused-tests.log |
| arch -arm64 /bin/zsh -lc 'swift test --filter SurfaceParity > tmp/ds179/ds179-04-cli-definition-commands/attempt-003/surface-parity.log 2>&1; exit_status=$?; print -r -- EXIT_STATUS=$exit_status; exit $exit_status' | 1 | 48 | 2 | tmp/ds179/ds179-04-cli-definition-commands/attempt-003/surface-parity.log |
| arch -arm64 /bin/zsh -lc 'xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/ds179/ds179-04-cli-definition-commands/attempt-003/changed-swift-files.nul > tmp/ds179/ds179-04-cli-definition-commands/attempt-003/lint.log 2>&1' | 0 | 0 | 0 | tmp/ds179/ds179-04-cli-definition-commands/attempt-003/lint.log |
| arch -arm64 /bin/zsh -lc 'git diff --check > tmp/ds179/ds179-04-cli-definition-commands/attempt-003/diff-check.log 2>&1' | 0 | 0 | 0 | tmp/ds179/ds179-04-cli-definition-commands/attempt-003/diff-check.log |
| arch -arm64 /bin/zsh -lc 'git diff --quiet -- Sources/RielaCLI/WorkflowRegistryCLICommand.swift' | 0 | 0 | 0 | tmp/ds179/ds179-04-cli-definition-commands/attempt-003/registry-update-unchanged.log |
| Assigned catalog/help grep checks | 0 | 0 | 0 | tmp/ds179/ds179-04-cli-definition-commands/attempt-003/done-greps.log |

The focused suite passes, including SurfaceParityCLITests. The wider
SurfaceParity command has two current failures in
SurfaceParitySkillTests.testGeneratedCommandBlocksMatchTheCatalog: the
repository skill command block omits the eight new CLI entries and the
existing session reconcile entry. The failing owner path,
Resources/skills/riela-workflow-run/SKILL.md, is outside this plan's
writePaths. No source-level or CLI catalog parity failure was reported by
SurfaceParityCLITests. This check requires a later authorized skill-doc
reconciliation and a rerun before the chain can claim aggregate parity.

## Per-edit evidence

attempt-001/edit-intent-001.md through edit-intent-013.md preserve exact
intent for each edit, with pre-edit hashes in attempt-001/pre-edit-sha256.txt
and attempt-002/pre-verification-sha256.txt. Lint repair intent and updated
source identity are recorded in attempt-002/attempt-003 evidence manifests.

## Remaining handoff

- Downstream work: reconcile Resources/skills/riela-workflow-run/SKILL.md
  with the catalog's workflow definition commands and existing session
  reconcile row, then rerun the exact SurfaceParity command.
- Formal integration review, later-plan documentation, exact-file staging,
  commit, and push remain owned by subsequent workflow steps.

## Final-source verification (attempt-004)

The attempt-003 table above is superseded by this final-source run, which also
checks that export JSON returns paths only.

| Command | Exit | Tests | Failures | Evidence |
| --- | ---: | ---: | ---: | --- |
| arch -arm64 /bin/zsh -lc 'swift build > tmp/ds179/ds179-04-cli-definition-commands/attempt-004/build.log 2>&1; exit_status=$?; print -r -- EXIT_STATUS=$exit_status; exit $exit_status' | 0 | 0 | 0 | tmp/ds179/ds179-04-cli-definition-commands/attempt-004/build.log |
| arch -arm64 /bin/zsh -lc "swift test --filter 'WorkflowDefinitionCommandTests|SurfaceParityCLITests|SurfaceCatalogTests|WorkflowVersionCommandsTests|WorkflowMutableRegistryTests|WorkflowRegistryEvolutionTests' > tmp/ds179/ds179-04-cli-definition-commands/attempt-004/focused-tests.log 2>&1; exit_status=\$?; print -r -- EXIT_STATUS=\$exit_status; exit \$exit_status" | 0 | 39 | 0 | tmp/ds179/ds179-04-cli-definition-commands/attempt-004/focused-tests.log |
| arch -arm64 /bin/zsh -lc 'swift test --filter SurfaceParity > tmp/ds179/ds179-04-cli-definition-commands/attempt-004/surface-parity.log 2>&1; exit_status=$?; print -r -- EXIT_STATUS=$exit_status; exit $exit_status' | 1 | 48 | 2 | tmp/ds179/ds179-04-cli-definition-commands/attempt-004/surface-parity.log |
| xargs -0 swiftlint lint --strict --quiet --no-cache with the attempt-004 changed-file manifest | 0 | 0 | 0 | tmp/ds179/ds179-04-cli-definition-commands/attempt-004/lint.log |

The same two SurfaceParitySkillTests failures remain on final source; the
focused CLI parity tests pass. Final source hashes are in
tmp/ds179/ds179-04-cli-definition-commands/attempt-004/pre-verification-sha256.txt.

## Final-source verification (attempt-005, 2026-10-26)

Before verification, source hashes and the repository status were recorded in
`attempt-005/pre-verification-sha256.txt` and
`attempt-005/pre-verification-status.txt`. The source files were unchanged
during this verification run. The skill command blocks are now synchronized;
the previous SurfaceParity handoff is resolved.

| Command | Exit | Tests | Failures | Evidence |
| --- | ---: | ---: | ---: | --- |
| `arch -arm64 /bin/zsh -lc 'swift build > tmp/ds179/ds179-04-cli-definition-commands/attempt-005/build.log 2>&1; result=$?; print -r -- EXIT_STATUS=$result; exit $result'` | 0 | 0 | 0 | `tmp/ds179/ds179-04-cli-definition-commands/attempt-005/build.log` |
| `arch -arm64 /bin/zsh -lc "swift test --filter 'WorkflowDefinitionCommandTests|SurfaceParityCLITests|SurfaceCatalogTests|WorkflowVersionCommandsTests|WorkflowMutableRegistryTests|WorkflowRegistryEvolutionTests' > tmp/ds179/ds179-04-cli-definition-commands/attempt-005/focused-tests.log 2>&1; result=\$?; print -r -- EXIT_STATUS=\$result; exit \$result"` | 0 | 39 | 0 | `tmp/ds179/ds179-04-cli-definition-commands/attempt-005/focused-tests.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter SurfaceParity > tmp/ds179/ds179-04-cli-definition-commands/attempt-005/surface-parity.log 2>&1; result=$?; print -r -- EXIT_STATUS=$result; exit $result'` | 0 | 48 (1 skipped) | 0 | `tmp/ds179/ds179-04-cli-definition-commands/attempt-005/surface-parity.log` |
| `arch -arm64 /bin/zsh -lc 'if [ -s tmp/ds179/ds179-04-cli-definition-commands/attempt-005/changed-swift-files.nul ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/ds179/ds179-04-cli-definition-commands/attempt-005/changed-swift-files.nul > tmp/ds179/ds179-04-cli-definition-commands/attempt-005/lint.log 2>&1; result=$?; else printf "%s\\n" "No Swift files changed; selected-file SwiftLint not run." > tmp/ds179/ds179-04-cli-definition-commands/attempt-005/lint.log; result=0; fi; print -r -- EXIT_STATUS=$result; exit $result'` | 0 | 0 | 0 | `tmp/ds179/ds179-04-cli-definition-commands/attempt-005/lint.log` |

The focused CLI suite exercised the eight operations, pinned usage and JSON
shapes, audit metadata, no-write errors, import/force/restore, export, and
unchanged registry behavior. The earlier attempt-004 parity failure remains
in its original log and is superseded by attempt-005's passing run.

The previously reported `INT-02-002` JSON Patch visibility finding is resolved
in accepted dependency commit `695c0af9`: `WorkflowDefinitionJSONPatch`,
`apply`, and `pointer` are public. This plan does not modify that file.
