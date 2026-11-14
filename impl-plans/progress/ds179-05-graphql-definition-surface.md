# DS179-05 Progress

**Plan**: `ds179-05-graphql-definition-surface`  
**Issue**: `tacogips/riela#179`  
**Workflow mode**: `issue-resolution`  
**Status**: Implementation complete; pending integration review

## Implemented

- Added the definition GraphQL DTOs, protocol, executor, schema fields, and
  CLI-side provider. The provider applies store selection, defaults the
  actor to `api`, accepts `user`, rejects unsupported actors before store
  access, requires reasons for writes, maps stale versions, and limits
  export writes to the registered source.
- Added the executor to HTTP, web host, RielaApp, scoped parity, and
  RielaLibrary chains; bound all eight SurfaceCatalog rows and regenerated
  the SDL from the generator.
- Added executor coverage and GraphQL contract tests. The real composite
  test covers import/no-op/diff, prompt and whole-workflow updates, audit
  reason/evidence/actor, restore, safe export, invalid/missing inputs,
  stale versions, and a service execution whose persisted input snapshot
  contains the newly stored prompt.
- A failed service-path assertion exposed a test-fixture issue: its
  `codex-agent` node omitted the required sandbox. The fixture now declares
  `agentSandbox: "read-only"`; no production behavior was changed for this
  correction.

## Final-source verification

All commands ran in the foreground from the repository root using the
arm64 shell where required. Logs are complete under
`tmp/ds179/ds179-05-graphql-definition-surface/attempt-018/` unless listed
otherwise.

| Command | Exit | Tests | Failures | Log |
|---|---:|---:|---:|---|
| `arch -arm64 /bin/zsh -lc 'swift build > tmp/ds179/ds179-05-graphql-definition-surface/attempt-021/build.log 2>&1'` | 0 | 0 | 0 | `attempt-021/build.log` |
| `arch -arm64 /bin/zsh -lc 'scripts/surface-parity/generate-sdl.sh > tmp/ds179/ds179-05-graphql-definition-surface/attempt-018/sdl.log 2>&1'` | 0 | 1 | 0 | `attempt-018/sdl.log` |
| `arch -arm64 /bin/zsh -lc "swift test --filter 'WorkflowDefinitionGraphQLTests|WorkflowDefinitionGraphQLContractTests' > tmp/ds179/ds179-05-graphql-definition-surface/attempt-021/focused.log 2>&1"` | 0 | 3 | 0 | `attempt-021/focused.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter SurfaceParity > tmp/ds179/ds179-05-graphql-definition-surface/attempt-023/parity.log 2>&1'` | 0 | 48 | 0 | `attempt-023/parity.log` (1 opt-in skip) |
| `arch -arm64 /bin/zsh -lc "swift test --filter 'WorkflowExecutionGraphQLTests|RoutineGraphQLTests|WorkflowExecutionProviderTests' > tmp/ds179/ds179-05-graphql-definition-surface/attempt-023/regression.log 2>&1"` | 0 | 27 | 0 | `attempt-023/regression.log` |
| `arch -arm64 /bin/zsh -lc 'if [ -s tmp/ds179/ds179-05-graphql-definition-surface/attempt-006/changed-swift-files.nul ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/ds179/ds179-05-graphql-definition-surface/attempt-006/changed-swift-files.nul; else printf "%s\\n" "No Swift files changed; selected-file SwiftLint not run."; fi'` | 0 | 0 | 0 | `attempt-021/lint.log` |

The contract test sets `actorKind: "user"` and asserts `user` in the audit;
the whole-workflow mutation omits `actorKind` and asserts the default `api`.

SDL generation runs the opt-in byte-identity test and then regenerates
`Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift`; SurfaceParity
then passed against that generated SDL. The lint manifest contains the exact
changed Swift set, including the generated schema file.

SDL source diff stat: `1 file changed, 9 insertions(+)`; captured by
`git diff --stat -- Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift`
in `tmp/ds179/ds179-05-graphql-definition-surface/attempt-020/sdl-diff-stat.log`.

`git diff --check` exited 0; its complete log is
`tmp/ds179/ds179-05-graphql-definition-surface/attempt-022/diff-check.log`.

## Earlier attempts

- `attempt-013/focused.log` and `attempt-014/focused.log` failed while adding
  the service-run assertion. Attempt 013 lacked a test import; attempt 014
  showed the fixture's missing `agentSandbox`. They are superseded by the
  passing source-matched `attempt-017/focused.log` after the fixture fix.
- `attempt-016/focused.log` confirmed the JSON enum spelling must be
  `read-only`; that correction is included in the passing attempt 017.

Earlier unrelated implementation iterations and their logs remain in their
original attempt directories and are not current-source verification.

## Source identity and handoff

Pre-edit plan SHA-256 is recorded in
`tmp/ds179/ds179-05-graphql-definition-surface/attempt-018/pre-edit-plan-sha256.txt`.
Pre-edit plan SHA-256 before the final verification-section refresh is recorded in
`tmp/ds179/ds179-05-graphql-definition-surface/attempt-020/pre-edit-plan-sha256.txt`.
Pre-edit plan/progress hashes before the final test evidence refresh are recorded
in `tmp/ds179/ds179-05-graphql-definition-surface/attempt-022/`.
Pre-edit progress-log SHA-256 is recorded in
`tmp/ds179/ds179-05-graphql-definition-surface/attempt-019/pre-edit-progress-sha256.txt`.
Pre-edit progress-log SHA-256 before this source-identity refresh is recorded in
`tmp/ds179/ds179-05-graphql-definition-surface/attempt-020/pre-edit-progress-sha256.txt`.
Pre-edit progress-log SHA-256 before this final verification refresh is recorded in
`tmp/ds179/ds179-05-graphql-definition-surface/attempt-023/pre-edit-progress-sha256.txt`.
Final source SHA-256 values for the plan-owned code and shared catalog/SDL
paths are recorded in `tmp/ds179/ds179-05-graphql-definition-surface/attempt-023/final-source-sha256.txt`.

The accepted dependency `ds179-04-cli-definition-commands` was admitted by
the dispatch runtime's `acceptedPlanIds`. The earlier mid review finding
`INT-02-002` on `WorkflowDefinitionJSONPatch` visibility is resolved upstream
and outside this plan's write paths. The combined-tree integration review
and any later workflow-owned documentation/staging/commit steps remain
downstream.
