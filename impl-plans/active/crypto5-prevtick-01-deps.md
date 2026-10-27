# c5pt-01-deps: swift-crypto 5.x, swift-webauthn revision, gateway/kaiba pins

Status: **completed** (2026-10-27). Landed on `main` as `35a910d5`, with
progress in `impl-plans/progress/c5pt-01-deps.md` (`c14c3b30`). Opus-luna
session 519 does not dispatch this plan again. It is an accepted dependency
of the remaining crypto5-prevtick plans.

```json
{
  "planId": "c5pt-01-deps",
  "planPath": "impl-plans/active/crypto5-prevtick-01-deps.md",
  "dependsOn": [],
  "wave": 1,
  "writePaths": [
    "Package.swift",
    "Package.resolved",
    "Packages/RielaMemory/Package.swift",
    "Packages/RielaMemory/Package.resolved",
    "Packages/RielaMemory/Sources/RielaMemory/CacheExchange.swift",
    "Packages/RielaMemory/Sources/RielaMemory/EvolutionReverseDelta.swift",
    "Packages/RielaMemory/Sources/RielaMemory/MemoryEvolutionAttachments.swift",
    "Packages/RielaMemory/Sources/RielaMemory/MemorySnapshot.swift",
    "Packages/RielaMemory/Sources/RielaMemory/RielaCacheStore.swift",
    "Packages/RielaMemory/Sources/RielaMemory/WriteIntentStore.swift",
    "Sources/RielaServer/RielaPasskeyService+Ceremonies.swift",
    "Sources/RielaServer/RielaPasskeyService.swift",
    "Sources/RielaServer/RielaPasskeyConfiguration.swift",
    "Sources/RielaServer/RielaAPIKeyStore.swift",
    "Sources/RielaKaibaAddons",
    "Sources/RielaKaibaSupport",
    "Sources/RielaAdapters/AgentGatewayNodeAdapter.swift",
    "Sources/RielaAdapters/BackendWaitSignalClassifier.swift",
    "Sources/RielaAdapters/GatewayTurnLifetime.swift",
    "Sources/RielaAdapters/NativeStructuredOutputFile.swift",
    "Sources/RielaAppSupport/RielaAppAssistantModelLoader.swift",
    "Sources/RielaCore/AgentEnvironment.swift",
    "Sources/RielaCore/AgentProviderConfiguration.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner+History.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner+NestedReservations.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner+PromptGuard.swift",
    "Sources/RielaCore/DistributedArtifact.swift",
    "Sources/RielaCore/JSONCanonical.swift",
    "Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+NestedInvocations.swift",
    "Sources/RielaCore/SpecialistSupervisor.swift",
    "Sources/RielaCore/SpecialistSupervisorStore+MonitorControl.swift",
    "Sources/RielaCore/SpecialistSupervisorStore+StatusReplies.swift",
    "Sources/RielaCore/WorkflowAddonExecution.swift",
    "Sources/RielaCore/WorkflowFanoutChangeEvidence.swift",
    "Sources/RielaCore/WorkflowHistoryCanonicalCoding.swift",
    "Sources/RielaCore/WorkflowRegistryModels.swift",
    "Sources/RielaAddons/NativeBundleAddonResolver.swift",
    "Sources/RielaAddons/WorkflowPackageChecksum.swift",
    "Sources/RielaHook/HookContracts.swift",
    "Sources/RielaWork/WorkStore+Reservation.swift",
    "Sources/RielaWorkflowRegistry/WorkflowCompactCatalog.swift",
    "Sources/RielaWorkflowRegistry/WorkflowRegistryGraphQLProvider.swift",
    "Sources/RielaCLI/AppleGatewayContainerCapability.swift",
    "Sources/RielaCLI/BuiltinGatewayRequestChecks.swift",
    "Sources/RielaCLI/GatewayNativeCommands.swift",
    "Sources/RielaCLI/NativeAppleGatewayConfiguration.swift",
    "Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayAdminAddons.swift",
    "Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift",
    "Sources/RielaCLI/ProductionNodeAdapter+GmailDigest.swift",
    "Sources/RielaCLI/ProductionNodeAdapter+GmailGatewayCLIAddons.swift",
    "Sources/RielaCLI/ProductionNodeAdapter+GoogleAnalyticsGatewayAddons.swift",
    "Sources/RielaCLI/ProductionNodeAdapter+GoogleDocumentsGatewayAddons.swift",
    "Sources/RielaCLI/ProductionNodeAdapter+GoogleServiceGatewayAddons.swift",
    "Sources/RielaCLI/ProductionNodeAdapter+LocalGatewaySupport.swift",
    "Sources/RielaCLI/ProductionNodeAdapter+NotionGatewayAddons.swift",
    "Sources/RielaCLI/ProductionNodeAdapter+WrikeGatewayAddons.swift",
    "Sources/RielaCLI/ProductionNodeAdapter+XGatewaySDKAddon.swift",
    "Sources/RielaCLI/ProductionNodeAdapter.swift",
    "Sources/RielaCLI/SpecialistWrikeGatewayAdapter.swift",
    "Sources/RielaCLI/WorkflowValidationContext+Production.swift",
    "Sources/RielaCLI/XGatewayOperationCatalog.swift",
    "Sources/RielaCLI/EventLiveServe+Webhooky.swift",
    "Sources/RielaCLI/EventReadOnly.swift",
    "Sources/RielaCLI/ProductionNodeAdapter+GitFinalizationRecordReads.swift",
    "Sources/RielaCLI/ProductionNodeAdapter+PersonaMemory.swift",
    "Sources/RielaCLI/ProductionNodeAdapter+WorkflowTaskAddon.swift",
    "Sources/RielaCLI/ScopedParityCommands+EventRecords.swift",
    "Sources/RielaCLI/SpecialistCommandRunner+Service.swift",
    "Sources/RielaCLI/SpecialistCommands.swift",
    "Sources/RielaCLI/WorkflowPackageLockFile.swift",
    "Tests/RielaKaibaAddonsTests",
    "Tests/RielaKaibaSupportTests",
    "Tests/RielaCLITests/KaibaGatewayPostprocessTests.swift",
    "Tests/RielaAdaptersTests/AgentGatewayCancellationTests.swift",
    "Tests/RielaAdaptersTests/AgentGatewayNodeAdapterTests.swift",
    "Tests/RielaAdaptersTests/BackendWaitSignalClassifierTests.swift",
    "Tests/RielaAdaptersTests/GatewayTurnLifetimeTests.swift",
    "Tests/RielaAppSupportTests/RielaAppAssistantModelCatalogTests.swift",
    "Tests/RielaCLITests/AppleGatewayLinkedDeadlineTests.swift",
    "Tests/RielaCLITests/BuiltinGatewayJSONBehaviorTests.swift",
    "Tests/RielaCLITests/CatalogWorkflowGatewayValidationTests.swift",
    "Tests/RielaCLITests/CollectionGatewayWorkflowTests.swift",
    "Tests/RielaCLITests/GoogleAnalyticsGatewayAddonTests.swift",
    "Tests/RielaCLITests/GoogleServiceGatewayAddonTests.swift",
    "Tests/RielaCLITests/LegacyWorkflowGatewayValidationTests.swift",
    "Tests/RielaCLITests/SpecialistTransportBoundaryTests.swift",
    "Tests/RielaCLITests/SpecialistWrikeReaderTests.swift",
    "Tests/RielaCLITests/SpecialistClassificationReplayTests.swift",
    "Tests/RielaCLITests/SpecialistServiceResponsivenessTests.swift",
    "Tests/RielaAddonsTests/NativeBundleAddonResolverTests.swift",
    "Tests/RielaCoreTests/AgentPromptGuardTests.swift",
    "Tests/RielaCoreTests/PromptOverflowGuardIntegrationTests.swift",
    "Tests/RielaCoreTests/WorkflowFanoutMapReduceTests.swift",
    "Tests/RielaServerTests/PasskeyTestAuthenticator.swift",
    "Tests/RielaServerTests/RielaPasskeyTests.swift",
    "impl-plans/progress/c5pt-01-deps.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

The owner instruction is "swift-crypto 5.xにせよ, 全gatewayもupdate,
kaibaもupdateしていい". The root package and `Packages/RielaMemory` move to
swift-crypto 5.x. Every gateway and kaiba moves to its latest release (design
§1.1 to §1.3).

Most `writePaths` are only *candidate* adaptation sites. They are every file
that imports a bumped module (`Crypto`, `_CryptoExtras`, `WebAuthn`,
`AgentGateway*`, `ACP`, `AppleGatewayCore`, `NotionGatewayCore`,
`GmailGatewayCore`, `GoogleServiceGatewayCore`, `XGatewayCore`,
`KaibaClient`), found with `git grep "import …"` on `0b25d5b2`. Edit a
candidate file only when the compiler requires it.

Current pins:

| Pin | Location |
|---|---|
| notion `15e7cbf7…` | `Package.swift:31` |
| x-gateway `exact: "0.1.26"` | `Package.swift:66` |
| agent-gateway | about `Package.swift:71` |
| swift-crypto `from: "4.5.2"` | `Package.swift:74` |
| swift-webauthn `exact: "1.0.0-beta.1"` | `Package.swift:75` |
| kaiba | about `Package.swift:80` |
| google-service-gateway | about `Package.swift:84` |
| gmail-gateway | about `Package.swift:92` |
| apple-gateway | about `Package.swift:100` |
| RielaMemory swift-crypto `from: "4.5.2"` | `Packages/RielaMemory/Package.swift:14` |

`Package.resolved` currently resolves swift-crypto to 4.5.2
(`da9d28d6…`).

## Non-goals

- Do not touch the pins of gateway-sdk-kit (0.1.1), google-gateway-auth
  (`48e0112`), wrike-gateway, google-analytics-gateway,
  google-documents-gateway, anydoc-swift or web-hooky.
- No refactors. Do not take up new upstream features beyond compile fixes.
  The Notion operations come in through the catalog automatically, and
  c5pt-04 tests them.
- Do not edit `Sources/RielaCore/CronSchedule.swift`,
  `Sources/RielaCLI/EventLiveServe+Cron.swift`,
  `Sources/RielaWorkflowRegistry/RoutineService.swift`, docs or examples.
  Other plans own those files.

## Tasks

0. **Baseline before any edit.** Run the baseline full suite on the untouched
   tree, which equals `0b25d5b2`:
   `swift test > tmp/crypto5-prevtick/c5pt-01/baseline-full-test.log`. Record
   the exit status and the list of failing test names in the progress log. The
   final gate uses this to separate pre-existing failures. Also run the
   baseline focused suites (the command list below) into
   `baseline-focused.log`.
1. **Edit the pins.** Keep each pin style.
   - swift-crypto: `from: "5.0.3"` in both manifests.
   - swift-webauthn: `revision: "030acd1eedaa835958ae3fcc0e491bec03b2abf1"`.
     This changes the style from exact to revision, which the owner
     directed.
   - agent-gateway `8282152f29679625fee58729543094961adca633`
   - apple-gateway `a57de9d6ea2658dce731067e837b0987ceb1e962`
   - notion-gateway `0f16afb306f28506ec50c78483e101694315facc`
   - gmail-gateway `ca29da81d8cdb7da40cb6ef6739cd824376bfcdd`
   - google-service-gateway `ed020e4a8f45a0acedaf46334e2a67677e3c3e63`
   - kaiba `41cbf6bf06e6ab18e7b8e72007e96230e0ea8ad5`
   - x-gateway `exact: "0.1.27"`

   Preserve the comment and condition lines next to each pin. One example is
   the macOS-only condition on the notion and apple products.
2. **Resolve.** Run `swift package resolve` in the root and
   `swift package --package-path Packages/RielaMemory resolve`. Let SwiftPM
   regenerate both `Package.resolved` files; never hand-edit them.
   - If resolution fails because a target pin caps swift-crypto below 5:
     1. Record the exact SwiftPM error.
     2. Record the offending package and its range, read from
        `.build/checkouts/<pkg>/Package.swift`.
     3. Mark the plan `blocked: upstream-crypto-cap`.

     Do not downgrade, fork or override (design §1.2, D6).
3. **Read the upstream diffs.** After the resolve, run
   `git -C .build/checkouts/<pkg> log --oneline <oldRev>..<newRev>` and
   `git diff --stat` for each bumped package. Take each old revision from the
   pre-edit `Package.swift`/`Package.resolved` (pre-hash snapshot). Note any
   public API renames or removals in the progress log. Write output to
   `tmp/crypto5-prevtick/c5pt-01/upstream-<pkg>.log`.
4. **Build and adapt.** Run `swift build`, then fix every compile error inside
   `writePaths` with the minimum change. Log each adaptation as
   `file:line → upstream change`. Rules:
   - **WebAuthn**
     (`Sources/RielaServer/RielaPasskeyService+Ceremonies.swift:20`,
     `beginRegistration(user:)`): upstream made `AuthenticatorSelection`
     optional. If the new default no longer emits the old
     `authenticatorSelection` value, pass the previous effective value
     explicitly. Read beta.1's default in the old checkout diff. The
     registration options JSON must stay equivalent.
     `beginAuthentication(userVerification: .required)` and
     `finishAuthentication` keep their exact semantics, including
     `requireUserVerification: true`.
   - **swift-crypto 5:** replace removed or deprecated APIs with their direct
     equivalents. Hash outputs, key formats and encodings must stay
     byte-identical. Existing checksum and canonical-JSON tests guard this.
   - **Gateway/kaiba:** adapt call sites to renamed or changed signatures. If
     an upstream package removed a capability that a Riela add-on exposes, do
     not delete the Riela surface. Record `blocked: upstream-capability-removed`
     with details.
   - Never silence errors with `@preconcurrency`, `try!` or force casts unless
     the surrounding file already uses that idiom for the same API.
5. **Verify** with the commands below.

## Invariants

- `Package.resolved` contains exactly one `"identity" : "swift-crypto"` entry,
  with a `"version" : "5.` prefix. The same holds for
  `Packages/RielaMemory/Package.resolved`.
- There are no behavior changes. Every focused suite that passed in the
  baseline still passes.
- Do not change any public Riela API, GraphQL SDL, add-on name or catalog
  content.

## Test cases

No new tests. If a dependency signature change only affects a test helper (for
example `PasskeyTestAuthenticator.swift`), adapt the helper and keep its
assertions.

## Verification (commands → required evidence)

```
arch -arm64 /bin/zsh -lc 'swift package resolve > tmp/crypto5-prevtick/c5pt-01/resolve.log 2>&1; echo exit=$?'
arch -arm64 /bin/zsh -lc 'swift package --package-path Packages/RielaMemory resolve > tmp/crypto5-prevtick/c5pt-01/resolve-memory.log 2>&1; echo exit=$?'
grep -c '"identity" : "swift-crypto"' Package.resolved Packages/RielaMemory/Package.resolved
grep -A6 '"identity" : "swift-crypto"' Package.resolved Packages/RielaMemory/Package.resolved
arch -arm64 /bin/zsh -lc 'swift build > tmp/crypto5-prevtick/c5pt-01/build.log 2>&1; echo exit=$?'
arch -arm64 /bin/zsh -lc "swift test --filter 'RielaPasskeyTests|PasskeyCommandTests' > tmp/crypto5-prevtick/c5pt-01/test-passkey.log 2>&1; echo exit=\$?"
arch -arm64 /bin/zsh -lc "swift test --filter 'Kaiba' > tmp/crypto5-prevtick/c5pt-01/test-kaiba.log 2>&1; echo exit=\$?"
arch -arm64 /bin/zsh -lc "swift test --filter 'NotionGatewayAddonTests|BuiltinGatewayJSONBehaviorTests|WorkflowGatewayValidationTests|GoogleServiceGatewayAddonTests|GoogleAnalyticsGatewayAddonTests|AgentGateway|AppleGatewayLinkedDeadlineTests|CollectionGatewayWorkflowTests|SpecialistWrikeReaderTests|XGateway|Gmail' > tmp/crypto5-prevtick/c5pt-01/test-gateways.log 2>&1; echo exit=\$?"
arch -arm64 /bin/zsh -lc 'swift test --package-path Packages/RielaMemory > tmp/crypto5-prevtick/c5pt-01/test-memory.log 2>&1; echo exit=$?'
arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet --no-cache <edited Swift files> > tmp/crypto5-prevtick/c5pt-01/lint.log 2>&1; echo exit=$?'
```

Required results:

- Both resolves end with `exit=0`.
- The grep counts are `1` and `1`, with versions `5.x`.
- The build ends with `exit=0`.
- Every test command ends with `exit=0`, has `testsRun > 0` and has
  `failureCount 0`. A failure that is also in `baseline-focused.log` is
  recorded as pre-existing with both log lines.
- Lint ends with `exit=0`.

## Done criteria

- `git diff --stat` shows `Package.swift`, `Package.resolved`, both
  RielaMemory manifest/resolved files, and only those candidate files that
  were actually adapted. Each adapted file has a matching
  `file:line → upstream change` entry.
- `grep -n 'swift-crypto' Package.swift Packages/RielaMemory/Package.swift`
  shows `from: "5.0.3"` twice.
- `grep -n '030acd1eedaa835958ae3fcc0e491bec03b2abf1\|0f16afb306f28506ec50c78483e101694315facc\|exact: "0.1.27"' Package.swift`
  shows 3 lines.
- The progress log contains `baseline-full-test.log` with its exit status and
  failing-test list, plus all verification records.
