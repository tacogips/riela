# bots-15-memory-surfaces progress

**Status** Ready for Step 7 review. Step 6 ran in issue-resolution mode from
checkpoint `fcd006da53cf39864b7ea9ef948a7e30a8222715` on `feat/bots-overview`.
The checkpoint includes the accepted 01–14 implementation at `73674ceb`. This
plan has no pending predecessors. Design acceptance is `comm-000004` and plan
acceptance is `comm-000008` in
`fable-sol-design-and-implement-review-loop-session-1`. There is no GitHub issue.

## Implemented

- Added `riela bot memory show|export|edit|history|diff|undo`, `riela bot feedback`,
  and a memory summary in `riela bot show`. GraphQL exposes `botMemory`,
  `updateBotMemory`, `undoBotMemoryChange`, and `captureBotFeedback`.
- Feedback validates the selected finished session or task and stores one
  audited change set with correction and review provenance. Memory writes use
  the existing writer and handover redaction rules. History, diff, and undo
  select audit records for the resolved memory root.
- Linked runs, resume, and rerun resolve memory from the selected working
  directory and environment. A shared append function applies the same
  memory block during initial composition and after spill recomposition.
- Added regression coverage for Markdown round trips, export overwrite
  protection, redaction, audit root isolation, feedback validation, typed
  GraphQL fields, linked mock runs, resume, rerun, and prompt overflow.

## Per-edit hashes

`tmp/bots-overview/bots-15-memory-surfaces/edit-intentions.md` records each
source path, pre-edit SHA-256, intended hunk, and post-edit SHA-256. The
generated SDL diff is in `tmp/bots-overview/bots-15-memory-surfaces/schema.diff`.
The final scope and file hashes are in
`tmp/bots-overview/bots-15-memory-surfaces/scope-final.log`.

## Verification

Logs are under `tmp/bots-overview/bots-15-memory-surfaces/`.

| Command | Exit | Log | Evidence |
| --- | --- | --- | --- |
| `scripts/surface-parity/generate-sdl.sh` | 0 | `sdl-current.log` | Regeneration test passed |
| `cmp Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift tmp/bots-overview/bots-15-memory-surfaces/schema-before-current.swift` | 0 | `sdl-stability-current.log` | Byte-identical SDL |
| `arch -arm64 /bin/zsh -lc 'swift build'` | 0 | `build.log` | Debug build succeeded |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "BotMemoryCommandTests\|BotMemoryInjectionTests\|BotMemoryPromptInjectionTests\|BotMemoryGraphQLTests\|BotMemoryWriterTests\|BotCommandTests\|DeterministicWorkflowRunnerTests\|SurfaceCatalogTests\|SurfaceParityCLITests\|SurfaceParityGraphQLTests\|SurfaceParityExecutorCoverageTests\|SurfaceParityDTOSchemaTests\|SurfaceParitySkillTests"'` | 0 | `test-final.log` | 97 selected, 96 passed, 1 generation-only skip, 0 failures |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "BotMemoryMarkdownTests\|BotMemoryUndoTests\|BotRunLinkageTests\|BotActivityRuntimeTests\|BotsGraphQLTests\|SurfaceParityConsoleReadTests\|SurfaceParityLibraryTests\|SurfaceParityWebAPITests" --skip "SurfaceParityWebAPITests/testNoSourceServesAnUndeclaredAPIPath"'` | 0 | `recovery-parity.log` | 45 passed, 0 failures |
| `arch -arm64 /bin/zsh -lc 'changed_swift_manifest=tmp/bots-overview/bots-15-memory-surfaces/changed-swift.nul; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\n" "No Swift files changed; selected-file SwiftLint not run."; fi'` | 0 | `swiftlint-final.log` | 36 changed Swift files |
| `git status --short Packages/RielaMemory` | 0 | `memory-package-status-final.log` | Empty output |
| `git diff --check` | 0 | `diff-check-final.log` | Empty output |

## Completion criteria

- [x] CLI and GraphQL memory edits are audited and undoable. CLI and GraphQL
  feedback share the write path.
- [x] Memory appears only in bot-linked prompts. Successful spill coverage
  asserts the block survives and contributes its UTF-8 bytes to the
  initial and final measurements.
- [x] Mock linked run, resume, and rerun use the selected memory root.
- [x] The focused suite, supplemental parity, SDL regeneration, build, and
  selected-file SwiftLint passed. The memory package has a clean Git status.

## Deviations

- Export and history share the `Query.botMemory` contract. The surface
  catalog declares the binding once because GraphQL root bindings are unique.
- The supplemental parity run excluded the one pairing route assertion
  assigned to `bots-18-pairing-surfaces` by the operator. Finding
  `W6-U1-undeclared-redeem-literal` remains pending there.

## Open items

Independent integrity, adversarial and integration review, cumulative wave
verification, and Git finalization follow the workflow's later steps.
