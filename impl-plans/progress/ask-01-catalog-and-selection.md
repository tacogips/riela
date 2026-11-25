# ask-01-catalog-and-selection

## Implemented

- Extended `ModelManifest` in the accepted order and moved assistant suggestions to it. Removed the duplicate resource, bundle lookup, and live loader.
- Both GraphQL configuration hosts read model IDs from their profile's built-in provider instances. Configuration accepts Automatic, reports its empty model, and preserves stored choices.
- `AskModelSelection` resolves vendor and provider overrides, availability, effort, and model warnings. It forwards the Anthropic credential alias when that is the available key.
- Bot mutation rows end with a newline. Text warnings use their own stderr lines and JSON includes `warnings`.

## Completion criteria

- [x] Model IDs, existing entries, and reasoning metadata are in the manifest.
- [x] Automatic settings and Ask model selection are implemented.
- [x] Text and JSON warning regression coverage is in place.
- [x] Duplicate assistant catalog, loader, and resource directory are removed. The Package.swift change is limited to the removed resource setting and adjacent comma.
- [x] Required focused Swift test command passed on matching pre-run and post-run source inventories.

## Per-edit hashes

Pre-edit and post-edit SHA-256 values and intended hunks are in `tmp/ask-riela/ask-01-catalog-and-selection/edit-intentions.md`. The native input snapshot was `tmp/riela-fanout/C40DE5D6-BBF3-45F9-BBEA-CB0CC9FB8A23/9C32E9E7-1E6A-4EA3-AB17-72279FA9EC31.json`.

## Verification

All log names below are relative to `tmp/ask-riela/ask-01-catalog-and-selection/`.

- `mkdir -p tmp/ask-riela/ask-01-catalog-and-selection` exited 0 (`evidence-directory.log`).
- Strict SwiftLint exited 0 using the Xcode toolchain environment and `xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"` (`swiftlint-xcode.log`, `changed-swift-paths.nul`).
- `arch -arm64 /bin/zsh -lc 'swift test --filter "ModelManifestTests|ModelCatalogTests|ProviderStoreTests|RielaAppAssistantModelCatalogTests|RielaWebAssistantConfigurationTests|ConfigurationGraphQLTests|DaemonWorkflowNodePatchTests|AskModelSelectionTests|BotCommandTests|ModelCatalogCommandTests"'` exited 0. Executed 61 tests with 0 failures (`test.log`, `test.exit`). Ran with Xcode and plan-local `TMPDIR`. `test-source-before.txt` and `test-source-after.txt` both hash to `7b9eb4d4062808e711a1adcf21dc0ca8a6c8b858bc75f9eddc0a61983931b302`.
- `bash -n scripts/lib/riela-web-packaging.sh` exited 0. Evidence: `tmp/ask-riela/ask-01-catalog-and-selection/packaging-syntax.log`.
- Legacy references, AppSupport resource removal, Package.swift diff, and whitespace checks passed. Evidence: `tmp/ask-riela/ask-01-catalog-and-selection/catalog-removal.log`.
- Earlier attempts are retained with their original source inventories and exit files. Attempt 1 exited 1 before running tests because ask-02's action sources lacked read-surface and store dependencies at compile time. Attempt 2 passed 61 tests while sibling source changed. Attempt 3 exited 1 before running tests because the shared SwiftPM build database was locked. Attempt 4 passed 61 tests with matching inventories. The final run repeated the same result after ask-02 updated a test fixture and finished its test process.

## Deviations

- The Bot render change is in `BotCommands.swift`. A small change in `BotsService.swift` exposes the existing warning formatter for Ask while preserving the existing Bots warning logic.
- Settings catalogs exclude the leading Bots default sentinel so model suggestions retain manifest-first ordering. An explicitly selected provider without a model uses that sentinel to defer the choice to the backend.

## Open items

- Formal integrity, adversarial, and integration review, the serial wave build, and final commit are downstream. The package plan's accepted completion criteria are met.
