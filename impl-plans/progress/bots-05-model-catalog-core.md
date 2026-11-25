# bots-05-model-catalog-core progress

## Implemented

- Bundled model manifests for all seven drivers, using repository model IDs and existing reasoning efforts.
- Built-in provider instances and SQLite-backed user instances and reports through the runtime's BotStore. Provider removal deletes its report in the same transaction.
- ACP model and option updates retain independently received fields, including options received before the first model. Recording passive probe results preserves model observations.
- The pure catalog merges manifest, reported and custom entries per instance with sorted provenance and a protected leading `default` sentinel. Unknown models produce `model_unknown` warnings. Authored workflow policy constraints continue to produce errors.

## Per-edit hashes

The pre-edit content and intended hunks are recorded in `tmp/bots-overview/bots-05-model-catalog-core/edit-intentions.md`.

| Path | Pre-edit SHA-256 | Post-edit SHA-256 |
| --- | --- | --- |
| `Sources/RielaCore/ModelCatalog/ModelManifest.swift` | `absent` | `78f3e3f173976d15e2b58aca09d60bbed0c712f8f8dc04cab2f4cfdb76535e99` |
| `Sources/RielaCore/ModelCatalog/ProviderInstance.swift` | `absent` | `b141904d10971cca99c15517c1c2e141dae85e03ecf9fd7688d315879a63ff6c` |
| `Sources/RielaCore/ModelCatalog/ProviderStore.swift` | `absent` | `b8d046c71793ec8c9da4f3958c96bd19435b30f9aa5e18117292789254eb79af` |
| `Sources/RielaCore/ModelCatalog/ReportedProviderConfig.swift` | `absent` | `1cde73f7cc5adceffa5dbd4fa77c5f9fe15f12be400c0b7f94561a06c53ba0a6` |
| `Sources/RielaCore/ModelCatalog/ModelCatalog.swift` | `absent` | `c0d120ff22655a512e459294aab6b76fdf7ca56eee1fb4b05fa8bd55c3b2b0c3` |
| `Tests/RielaCoreTests/ModelCatalog/ModelCatalogTests.swift` | `absent` | `5532369bc8908c9bcb5a9b7be53b8f638a75c0002694eba7a063db245a5ee4c2` |
| `Tests/RielaCoreTests/ModelCatalog/ProviderStoreTests.swift` | `absent` | `ceb4010f5292640eab3466a30485ca96e0356531c45344ce2b439ca28f489634` |
| `Tests/RielaCoreTests/ModelCatalog/WorkflowBackendPolicyWarningTests.swift` | `absent` | `218247167b78c9877e436f4e8a88219c9456e948a8e0507e50bbe1021ca74c61` |
| `Sources/RielaCore/WorkflowBackendPolicy.swift` | `d6c1d15153c57164852cf8e4f0d12b61de21b05ff4cfebf7c362cfef0e7a07d9` | `efccfc30e9ed422d36339558a9267a3b1e76a070cbf85896ab571b316767c0dd` |
| `Sources/RielaCore/ModelCatalog/ModelCatalog.swift` | `c0d120ff22655a512e459294aab6b76fdf7ca56eee1fb4b05fa8bd55c3b2b0c3` | `b94bbee492a97e2ce50c362d87539de7b9052a48c476d817f8faed83ee1ee08a` |
| `Sources/RielaCore/ModelCatalog/ProviderStore.swift` | `b8d046c71793ec8c9da4f3958c96bd19435b30f9aa5e18117292789254eb79af` | `538294edbf9edbb6930c412ca716a49113b5f0122dd7a957fa46e3708e4e1b4d` |
| `Sources/RielaCore/ModelCatalog/ReportedProviderConfig.swift` | `1cde73f7cc5adceffa5dbd4fa77c5f9fe15f12be400c0b7f94561a06c53ba0a6` | `1f8983d28ebb6a335a906b9b9d9af2742125d1d14c7d6671b79d14d1bdb5076a` |
| `Tests/RielaCoreTests/ModelCatalog/ModelCatalogTests.swift` | `5532369bc8908c9bcb5a9b7be53b8f638a75c0002694eba7a063db245a5ee4c2` | `4e975f9682638d9aa62ae138c6c67a8bf12e8e38af8acfb7c6af52d887b90436` |
| `Tests/RielaCoreTests/ModelCatalog/ProviderStoreTests.swift` | `ceb4010f5292640eab3466a30485ca96e0356531c45344ce2b439ca28f489634` | `838a444f932377afe4c40b2636014c060223980259ea6b829bec00c92956981e` |
| `Sources/RielaCore/ModelCatalog/ProviderInstance.swift` | `b141904d10971cca99c15517c1c2e141dae85e03ecf9fd7688d315879a63ff6c` | `1430e8b287c0a55d0ce6729c810674013e3055a8576f5550d58bbf153e5e8ab8` |
| `Sources/RielaCore/ModelCatalog/ReportedProviderConfig.swift` | `1f8983d28ebb6a335a906b9b9d9af2742125d1d14c7d6671b79d14d1bdb5076a` | `4c252c943bfdfec9602d9a3d812fac7808188a09f8b39283429dd726fb1f5de8` |
| `Tests/RielaCoreTests/ModelCatalog/ProviderStoreTests.swift` | `838a444f932377afe4c40b2636014c060223980259ea6b829bec00c92956981e` | `615a2ccf362a606e19cd8762033c63b92f46000f8380d61ede3186414123011d` |

This progress record's pre-edit and post-edit values are in `tmp/bots-overview/bots-05-model-catalog-core/edit-hashes.tsv`.

## Verification

- `arch -arm64 /bin/zsh -lc 'swift test --filter "ModelCatalogTests|ProviderStoreTests|WorkflowBackendPolicyWarningTests|WorkflowBackendPolicyTests"'` exited 0. The complete `tmp/bots-overview/bots-05-model-catalog-core/test.log` reports 34 tests with 0 failures. All four named suites passed. The filter also matched nine existing assistant catalog tests.
- `arch -arm64 /bin/zsh -lc 'xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/bots-overview/bots-05-model-catalog-core/changed-swift.nul'` exited 0 on the nine Swift files. Complete log at `tmp/bots-overview/bots-05-model-catalog-core/swiftlint.log`. The manifest was checked for nonempty content before linting.
- `grep -rn "URLSession\|Process()" Sources/RielaCore/ModelCatalog` exited 1 with zero matches, as expected. Complete log at `tmp/bots-overview/bots-05-model-catalog-core/passive-catalog.log`.
- `git diff --check -- Sources/RielaCore/WorkflowBackendPolicy.swift Sources/RielaCore/ModelCatalog Tests/RielaCoreTests/ModelCatalog` exited 0. Complete log at `tmp/bots-overview/bots-05-model-catalog-core/diff-check.log`.
- The nine plan-owned Swift SHA-256 hashes matched before and after the passing run on the shared tree. Scope and per-edit hashes were checked against the pre-node snapshot. The serial wave gate will verify the integrated tree.
- `test-attempt-{1,2,3,4}.log` retain earlier shared-tree compile failures in sibling activity, memory, jobs and ACP adapter paths. Those runs exited 1 before testing. `swiftlint-attempt-1.log` retains the initial lint diagnostics addressed before the final run.

- [x] Runtime-owned catalog data and merge with warning-only unknown model diagnostics.
- [x] Passive catalog source check.
- [x] Focused suites, strict lint and tracked progress record.

## Deviations

- `ModelCatalog.diagnostics(nodeModels:catalog:)` accepts the three requested fields through `ModelCatalog.NodeModelReference`. SwiftLint rejects the plan's three-element tuple under `large_tuple`.
- The accepted plan remains at `impl-plans/active/bots-05-model-catalog-core.md`. This progress record tracks implementation completion.

## Open items

Formal test-integrity and adversarial reviews, the serial integration gate, and workflow finalization are pending.
