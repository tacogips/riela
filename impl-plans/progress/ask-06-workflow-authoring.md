# ask-06-workflow-authoring

**Status**: Implementation complete at checkpoint `6d981f1ecb64368b5fadca302954e83d117fcd6c`. Ready for independent review.

## Implemented

- Added the shared `propose_workflow` descriptor and executor for rounds and MCP. The executor checks proposal size and definition validity, returns bounded issues, rejects immutable bases, and records the mutable base revision when supplied.
- The runtime store replaces previous workflow proposals for the same turn in the insert transaction. Draft context is private to the running turn and is cleared on settlement. The prompt preserves retain handles and filters raw protected fields.
- Confirming a draft revalidates the stored definition and returns it to the editor without a registry mutation. Confirming a store proposal uses the Ask authoring provider and records the workflow ID and revision directly from the mutation payload.
- Coordinated registry writes return their persisted definition SHA-256 through the existing GraphQL field. The registry result's CLI JSON encoding still uses its five existing keys. Plain updates check the expected revision under the workflow locks.
- The host and tool server use the same per-store, mode-0600 retain key. A malformed key fails closed. Tests cover protected-field retention and matching handles from independently constructed providers.
- Removed the three legacy workflow generation routes, the dispatch and generation stores, desktop forwarding, catalog bindings, Swift tests, and the obsolete browser fixture.

## Per-edit hashes

See `edit-intentions.md` and `amendment-web-edit-intentions.md` in the plan evidence directory for the before/after SHA-256 values and intended hunks. Amendment round 1 continued the preserved Step 6 working tree with no unaccepted dependencies. `amendment-snapshot-drift.log` compares tracked content with the runtime-owned pre-node snapshot. `amendment-protected-files.log` confirms an empty protected-file diff at the current checkpoint. The earlier package resource removal is part of the accepted `7855cf90` commit.

## Verification

Commands ran in the checkout in the foreground. Logs are under `tmp/ask-riela/ask-06-workflow-authoring/`.

| Check | Command | Exit | Evidence |
| --- | --- | ---: | --- |
| Evidence directory | `mkdir -p tmp/ask-riela/ask-06-workflow-authoring` | 0 | `amendment-mkdir.log` |
| SDL regeneration | `scripts/surface-parity/generate-sdl.sh` | 0 | `amendment-sdl.log`. One test passed and `amendment-sdl-cmp.log` records byte equality. |
| Build | `arch -arm64 /bin/zsh -lc 'swift build'` | 0 | `amendment-build-final.log` |
| Focused Swift suites | Amended `swift test --filter` command in the active plan | 0 | `amendment-test-3.log`. 202 passed, one skipped, zero failures. The SDL script ran the skipped regeneration test. |
| Selected SwiftLint | `xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/ask-riela/ask-06-workflow-authoring/amendment-changed-swift.nul` in the arm64 shell | 0 | `amendment-lint-3.log` |
| Acceptance searches | Four searches in the active plan | 1 each | `amendment-legacy-generation.log`, `amendment-no-overwrite.log`, `e2e-fixture.log`, `no-refusal.log`. Each found zero matches. |
| Web type check, unit tests, lint, build | `bun run typecheck`, `bun test src`, `bun run lint`, `bun run build` in `web` | 0 each | `amendment-web-typecheck.log`, `amendment-web-test.log` (163 passed), `amendment-web-lint.log`, `amendment-web-build.log`. The amendment relies on the fixture search and excludes Playwright execution. |
| Whitespace | `git diff --check` | 0 | `amendment-diff-check.log` |

Earlier amendment logs record a changed-file lint diagnostic and test fixture errors in the target type, registry root, and exact origin. The final commands above reran after those corrections.

## Adversarial review repair

Addressed `ASK-06-RETAIN-HANDLE-VALIDATION` from `comm-000430`. Ask uses neutral placeholders for retain handles in display-text fields and array elements, and omits other handle-valued fields from its validation copy. Action targets keep the submitted definition intact. The registry still authenticates and expands store-mode handles before publication.

- The new store and draft regressions reproduced two `workflow_invalid` failures before the fix. `repair-reproduction.log` records exit 1 and the diagnostics for `defaults.agentPromptMaxBytes` and node `inputFilters`.
- The amended Swift test filter passed with 204 passes, one skipped SDL regeneration test, and zero failures. `repair-test.log` verifies that store confirmation writes the edit and preserves both typed fields. Draft confirmation returns the submitted definition, calls no mutation, and leaves the registry bytes intact. Existing invalid-definition, description-retain, stale-revision, and malformed-target regressions also passed.
- The arm64 build and strict SwiftLint exited 0 in `repair-build.log` and `repair-lint.log`. Each of the four acceptance searches exited 1 with an empty `repair-*.log` for that search.
- The SDL regeneration test passed separately in `repair-sdl.log`. The regenerated schema was byte-identical to the reviewed source (`repair-sdl-cmp.log`).
- `repair-edit-intentions.md` records exact hunks and per-edit SHA-256 values. `repair-source-identity.log` compares the final repair against the native pre-node snapshot and the reviewed source identity.

## Deviations

- Design §7.3 assigns the definition audit reason `ask:<conversationId>/<actionId>`. Registry mutation inputs have no reason field. The accepted Ask-side audit design links the confirmed row to the workflow id and exact resulting definition revision.
- Closed `ASK-06-REGISTRY-RESULT-REVISION` under the approved amendment. `amendment-test-3.log` covers registration, duplicate rejection with the existing registry error `REGISTRY_IO_FAILURE`, a revision-guarded update, stale revision rejection with `REGISTRY_CONFLICT`, and retained values.

## Open items

- Formal integrity, adversarial and integration review remain downstream.
