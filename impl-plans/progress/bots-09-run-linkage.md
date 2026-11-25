# bots-09-run-linkage progress

Status: Implementation verified at checkpoint 31f978b2. Formal review pending.

## Prior Step 6 attempts

Status: BLOCKED at Step 6

## Implemented

The dispatch admits `bots-01-contracts`. Design §5.1–5.2 and the committed plan were checked against the current runtime entry points. No implementation or test source was edited.

## Per-edit hashes

The progress record was absent before creation. Its SHA-256 is in `tmp/bots-overview/bots-09-run-linkage/edit-intentions.md`.

## Verification

The committed scope lookup and transport symbol search exited 0. See `tmp/bots-overview/bots-09-run-linkage/remote-scope-check.log` and `tmp/bots-overview/bots-09-run-linkage/write-scope.log`. This was a read-only scope check with zero tests run. Swift tests, lint and SDL regeneration are pending.

## Deviations

The committed scope includes `Sources/RielaCLI/WorkflowRunCommand+Remote.swift`, which constructs the transport request. The request DTO and the production encoder that selects the executeWorkflow input fields are both in `Sources/RielaCLI/WorkflowCommands.swift`. That file is absent from the runtime and committed write scopes. A call-site change alone cannot send the top-level `botId` field.

## Open items

- Amend the checkpoint plan and dispatch manifest to authorize `Sources/RielaCLI/WorkflowCommands.swift`, then redispatch with that path in the runtime write scope.
- Implement and verify local, remote GraphQL and routine linkage and paused gating. Regenerate the SDL twice, confirm all three schema fields and generator idempotence, and run the exact focused test filter and selected-file SwiftLint.

## Redispatch

The pre-node snapshot and checkpoint manifest still exclude `Sources/RielaCLI/WorkflowCommands.swift`. Its transport request and top-level GraphQL input encoder match the checkpoint. The read-only scope check exited 0 with zero tests. Evidence is in `tmp/bots-overview/bots-09-run-linkage/remote-scope-redispatch.log`. The write-scope blocker and the verification items above remain open.

Step 6 redispatch `7ff6689a` confirmed the same scope gap against its own pre-node snapshot. The review payload contained no repair findings, and the dispatch still admits `bots-01-contracts`. The scope check exited 0 with zero tests. See `tmp/bots-overview/bots-09-run-linkage/remote-scope-7ff6689a.log`. The completion criteria above remain open.

### Amended checkpoint c1f25362

The current dispatch has no active prerequisites. The checkpoint records `bots-01-contracts` under accepted dependencies, and the signed-off amendment grants `WorkflowCommands.swift` request and encoding ownership. The earlier request-encoding scope blocker is resolved.

Status: BLOCKED on additional GraphQL write ownership. `GraphQLWorkflowExecutionValidation.swift:17` rejects `botId` before DTO decoding. `WorkflowExecutionGraphQL.swift:125` replaces provider errors with `WORKFLOW_EXECUTION_FAILED`. Neither file is in the checkpoint or pre-node write scope. The amended plan also expressly excludes `WorkflowCommands.swift:451`, where the HTTP client drops GraphQL errors required by the remote run contract. The GraphQL routine existence requirement in design §5.2 additionally needs assigned ownership for routing the host-selected session store into `FileRoutineGraphQLProvider`. The active constructors in `RielaLibrary.swift`, `ScopedParityCommands+GraphQLDocument.swift`, and `RielaAppWebGraphQL.swift` omit that context and are outside this plan.

Read-only scope checks exited 0, with zero behavioral tests. Complete logs are `tmp/bots-overview/bots-09-run-linkage/amended-scope-c1f25362.log` and `tmp/bots-overview/bots-09-run-linkage/graphql-gate-scope-final-c1f25362.log`. Swift sources and tests were left pending at the scope boundary. Both SDL passes, the schema field and idempotence checks, the focused tests, and changed-file SwiftLint remain open.

Resume after amending the checkpoint and redispatching with ownership of the validator, executor, and narrow client error-forwarding hunk, and resolving which plan owns canonical GraphQL routine bot validation.

## Amended checkpoint 31f978b2

Step 6 implementation verified. The current dispatch has no unaccepted predecessors. The round-two checkpoint authorizes execution input validation, typed error forwarding, and the three GraphQL routine-store bindings.

### Implemented

- Local workflow runs validate the bot before session creation and link the canonical root session before its first step. Cross-workflow and same-workflow child sessions inherit attribution through runtime lineage.
- GraphQL and endpoint execution pass the bot ID to the host. Missing and paused bot rejections retain their typed codes and CLI diagnostics. Unrelated GraphQL errors retain the existing generic text.
- Routine creation validates and persists the bot against the selected store. Initial and deferred cron starts check pause state and record routine provenance when linking. A missing bot produces one warning and the routine runs without a link.
- CLI help and SurfaceCatalog expose the flag. The generated SDL carries nullable `botId` in `ExecuteWorkflowInput`, `CreateRoutineInput`, and `Routine`.

### Per-edit hashes

The pre-node snapshot and exact hunks are recorded with pre/post SHA-256 in `tmp/bots-overview/bots-09-run-linkage/edit-intentions.md`, `edit-intentions-routines.md`, and `bot-run-tests-edit-intentions.md` in that directory. `changed-swift.nul` lists the 29 changed Swift files. The existing `botFamilyRows` catalog registration was preserved.

### Verification

All log paths below are relative to `tmp/bots-overview/bots-09-run-linkage/`.

| Command | Exit | Evidence |
| --- | ---: | --- |
| `scripts/surface-parity/generate-sdl.sh` (two passes) | 0, 0 | `sdl.log`, `sdl-second.log` |
| `cmp tmp/bots-overview/bots-09-run-linkage/sdl-stat-first.log tmp/bots-overview/bots-09-run-linkage/sdl-stat-second.log` | 0 | `sdl-stat-idempotence.log`; unchanged SDL diff statistics |
| `cmp tmp/bots-overview/bots-09-run-linkage/sdl-before-2.swift Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift` | 0 | `sdl-byte-idempotence.log`; identical generated bytes |
| `grep -n "botId" Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift` | 0 | `sdl-fields.log`; three declarations |
| `grep -n "botId" Sources/RielaCLI/WorkflowCommands.swift` | 0 | `endpoint-fields.log`; property, initializer and encoder |
| `grep -n '"botId"' Sources/RielaGraphQL/GraphQLWorkflowExecutionValidation.swift` | 0 | `execution-validator.log`; allowlist and validation |
| `grep -c "botExists:" Sources/RielaCLI/RielaLibrary.swift Sources/RielaCLI/ScopedParityCommands+GraphQLDocument.swift Sources/RielaApp/RielaAppWebGraphQL.swift` | 0 | `routine-store-wiring.log`; one binding per host |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "BotRunLinkageTests\|BotRoutineLinkageTests\|RoutineCommandTests\|RoutineGraphQLTests\|WorkflowExecutionGraphQLTests\|SurfaceParityGraphQLTests\|SurfaceParityDTOSchemaTests\|SurfaceParitySkillTests"'` | 0 | `test.log`; 58 selected, 57 passed, one generator-only skip, zero failures. Both generator runs passed separately. |
| `arch -arm64 /bin/zsh -lc 'swift test --skip-build --filter "EventCronOverlapTests/(testQueuedRoutineIsRecheckedAfterRunningFireCompletes\|testQueueStartsDeferredFireInFIFOOrder\|testCancelRunningWaitsForSessionAndStartsLatestFire)\|WorkflowRunHelpTests"'` | 0 | `cron-help-tests.log`; seven passed, zero failures |
| `arch -arm64 /bin/zsh -lc 'swift build'` | 0 | `build.log`; RielaApp and CLI built |
| Selected-file `swiftlint lint --strict --quiet --no-cache` via `xargs -0` | 0 | `swiftlint.log`; all 29 files |
| `git diff --check` | 0 | `diff-check-final.log` |
| `cmp tmp/bots-overview/bots-09-run-linkage/test-source-before-compilation.sha256 tmp/bots-overview/bots-09-run-linkage/test-source-after.sha256` | 0 | `source-stability.log`; source manifests matched |

### Deviations

Routine and CreateRoutineInput now render from descriptors so the generated Swift source contains all three required fields. The remaining routine SDL stays in the existing hand-written block. The first two strict lint attempts identified size and tuple diagnostics. Focused code moves and two-element test values resolved them, and final-source lint passed.

### Open items

The assigned completion criteria are met. Test-integrity, adversarial and integration reviews, the cumulative wave gate, and commit finalization remain with the downstream workflow steps.

