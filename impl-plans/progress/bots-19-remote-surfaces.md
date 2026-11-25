# bots-19-remote-surfaces progress

Workflow mode: issue-resolution. Checkpoint: fcd006da53cf39864b7ea9ef948a7e30a8222715.
Issue reference: fable-sol-design-and-implement-review-loop-session-1, design comm-000004 and plans comm-000008.
Dependency: bots-18-pairing-surfaces, accepted by dispatch.

## Implemented

- Added client-side pairing and the remote registry under the credential directory. Registry metadata, per-remote tokens, active selection and cached overview data persist with owner-only permissions.
- Added `riela remote add|list|show|remove|use` and the four credential-free GraphQL registry responses.
- Forwarded bot records, list state, activity, permissions, memory, jobs, suggestions and the provider/model catalog through typed GraphQL operations. Selection sets use schema descriptors. Responses retain verified, unverified and disconnected origin states.
- Added named workflow and routine routing through the existing server mutations. Machine routine creation uses server-selected stores. Scoped credentials and grant revocation are exercised through the real serve composite.
- Updated the surface catalog, CLI help and generated SDL.

## Per-edit hashes

The per-edit SHA-256 hashes and intentions are in `tmp/bots-overview/bots-19-remote-surfaces/edit-intentions*.md`.
`authored-hunks.diff` preserves the source changes relative to the runtime-owned before-step snapshot.
`scope.log` records the final hashes. `source-identity.sha256` includes the tested tree and SwiftLint configuration.

## Verification


- `scripts/surface-parity/generate-sdl.sh > tmp/bots-overview/bots-19-remote-surfaces/sdl.log 2>&1`
  Exit 0. Regeneration test passed and emitted the canonical control-plane schema. 1 run, 1 passed, 0 skipped, 0 failed. Log `tmp/bots-overview/bots-19-remote-surfaces/sdl.log`.

- `shasum -a 256 -c tmp/bots-overview/bots-19-remote-surfaces/sdl-before.sha > tmp/bots-overview/bots-19-remote-surfaces/sdl-stable.log 2>&1`
  Exit 0. The SDL source is byte-identical after regeneration. Log `tmp/bots-overview/bots-19-remote-surfaces/sdl-stable.log`.

- `arch -arm64 /bin/zsh -lc 'swift test --filter "RemoteRegistryTests|RemotePairingClientTests|RemoteForwardingTests|RemotesGraphQLTests|GraphQLSelectionBuilderTests|PairingScopeEnforcementTests|BotCommandTests|BotRunLinkageTests|SurfaceCatalogTests|SurfaceParityCLITests|SurfaceParityGraphQLTests|SurfaceParityExecutorCoverageTests|SurfaceParityDTOSchemaTests|SurfaceParitySkillTests"' > tmp/bots-overview/bots-19-remote-surfaces/test.log 2>&1`
  Exit 0. Assigned remote and parity suites passed. 77 run, 76 passed, 1 skipped, 0 failed. Log `tmp/bots-overview/bots-19-remote-surfaces/test.log`.

- `arch -arm64 /bin/zsh -lc 'swift test --filter "BotStoreTests|BotStoreMigrationTests|ActivityContractTests|SQLiteRuntimeSchemaMigrationTests|SQLiteRuntimeExecutionRowsTests|WorkflowDefinitionStoreTests|WorkflowDefinitionRetentionTests|SQLiteWorkflowMessageLogTests|RoutineStoreTests|WorkStoreTests|SurfaceCatalogTests|BotBoardProjectorTests|BotListProjectionTests|BotListStateStoreTests|ActivityReducerTests|ActivityRecorderTests|ActivityPermissionTests|ActivitySettlementRunnerTests|ActivityWaitTests|DeterministicWorkflowRunnerTests|ActivityNormalizationTests|GatewayScriptedAgentTests|GatewayModelSentinelTests|AgentGatewayACPV2Tests|AgentGatewayNodeAdapterTests|AgentGatewayCancellationTests|BackendWaitSignalClassifierTests|GatewayTurnLifetimeTests|ModelCatalogTests|ProviderStoreTests|WorkflowBackendPolicyWarningTests|WorkflowBackendPolicyTests|BotMemoryWriterTests|BotMemoryMarkdownTests|BotMemoryUndoTests|BotJobDueTests|BotJobLedgerTests|BotSuggestionStoreTests|LookAroundPolicyTests|PairingCodeTests|PairingAddressTests|PairingHTTPTests|APIScopePolicyTests|ServerIdentityTests|RielaAPIKeyStoreTests|DistributedWorkerAPIKeyTests|BotRunLinkageTests|BotRoutineLinkageTests|RoutineCommandTests|RoutineGraphQLTests|WorkflowExecutionGraphQLTests|SurfaceParityGraphQLTests|SurfaceParityDTOSchemaTests|SurfaceParitySkillTests|BotCommandTests|BotsGraphQLTests|BotActivityRuntimeTests|SessionReconcileCommandTests|SessionAbandonedInvocationTests|TerminalRetentionTests|TerminalRetentionPolicyTests|SurfaceParityCLITests|SurfaceParityExecutorCoverageTests|SurfaceParityWebAPITests|SurfaceParityConsoleReadTests|SurfaceParityLibraryTests|BotActivityCommandTests|BotActivityGraphQLTests|ModelCatalogCommandTests|ModelCatalogGraphQLTests|ActivityCatalogReportTests|BotMemoryCommandTests|BotMemoryInjectionTests|BotMemoryPromptInjectionTests|BotMemoryGraphQLTests|BotJobRunnerTests|LookAroundReadOnlyTests|ForcedReadOnlySandboxRunnerTests|BotJobSchedulerTests|BotJobsGraphQLTests|BotExampleWalkthroughTests|RielaExampleParityTests|PairingServeTests|PairingScopeEnforcementTests|PairingGraphQLTests|RemoteRegistryTests|RemotePairingClientTests|RemoteForwardingTests|RemotesGraphQLTests|GraphQLSelectionBuilderTests"' > tmp/bots-overview/bots-19-remote-surfaces/cumulative.log 2>&1`
  Exit 0. C9 cumulative wave suites on the combined tree. 612 run, 611 passed, 1 skipped, 0 failed. Log `tmp/bots-overview/bots-19-remote-surfaces/cumulative.log`.

- `arch -arm64 /bin/zsh -lc 'swift build' > tmp/bots-overview/bots-19-remote-surfaces/build.log 2>&1`
  Exit 0. Swift build completed. Log `tmp/bots-overview/bots-19-remote-surfaces/build.log`.

- `arch -arm64 /bin/zsh -lc 'changed_swift_manifest=tmp/bots-overview/bots-19-remote-surfaces/changed-swift.nul; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\n" "No Swift files changed; selected-file SwiftLint not run."; fi' > tmp/bots-overview/bots-19-remote-surfaces/swiftlint.log 2>&1`
  Exit 0. Strict lint on all authored Swift paths passed. Log `tmp/bots-overview/bots-19-remote-surfaces/swiftlint.log`.

- `python3 tmp/bots-overview/bots-19-remote-surfaces/scope-check.py > tmp/bots-overview/bots-19-remote-surfaces/scope.log 2>&1`
  Exit 0. Authored paths and SHA-256 digests match the committed scope and pre-node snapshot. Log `tmp/bots-overview/bots-19-remote-surfaces/scope.log`.

- `git diff --check > tmp/bots-overview/bots-19-remote-surfaces/diff-check.log 2>&1`
  Exit 0. Whitespace check passed. Log `tmp/bots-overview/bots-19-remote-surfaces/diff-check.log`.

- `{ rc=0; grep -rn "remote_not_configured" Sources || rc=$?; [ "$rc" -eq 1 ]; } > tmp/bots-overview/bots-19-remote-surfaces/stub-scan.log 2>&1`
  Exit 0. No source continues to return the previous remote stub error. Log `tmp/bots-overview/bots-19-remote-surfaces/stub-scan.log`.

- `{ rc=0; grep -rn "\.config" Sources/RielaCLI/Remotes || rc=$?; [ "$rc" -eq 1 ]; } > tmp/bots-overview/bots-19-remote-surfaces/credential-path-scan.log 2>&1`
  Exit 0. No config-directory path appears in the client registry. Log `tmp/bots-overview/bots-19-remote-surfaces/credential-path-scan.log`.

- `grep -n "/api/v1/pairing/redeem" Sources/RielaCLI/ServeWebHost.swift Sources/RielaAppSupport/RielaWebAPIRouteTable.swift Sources/RielaServer/RielaPairingHTTP.swift > tmp/bots-overview/bots-19-remote-surfaces/redeem-route.log 2>&1`
  Exit 0. The prerequisite pairing route remains declared and handled by the real serve host. Log `tmp/bots-overview/bots-19-remote-surfaces/redeem-route.log`.


The initial SDL compile, focused test and strict lint failures are retained in the numbered attempt logs. Final gates reran on current sources.

## Deviations

- The paired workflow linkage test uses a deterministic server workflow. The existing executeWorkflow endpoint keeps the local-file `--mock-scenario` option local. The test verifies server session and bot ownership with an empty client session store.
- Audited memory history, memory diff and job history use typed read fields, preserving the full CLI reads through a named remote.

## Open items

- Independent test-integrity, adversarial and integration reviews and Git finalization are downstream workflow steps.
