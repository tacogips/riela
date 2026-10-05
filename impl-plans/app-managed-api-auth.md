# App-managed API keys and worker authentication

Implement design-app-managed-api-auth.md. Replace the server's ambient manager
shared secret with keys issued by the local Mac administration screen. Preserve
browser Host/Origin/CSRF and native IPC authority independently of machine keys.

## Ownership and changes

- RielaServer owns the app-global API key hash store, locking, atomic private
  persistence, client requirement policy, purpose/worker binding, expiry and
  revocation. Configuration failures reject requests. Raw keys exist only in
  issuance responses and the client credential reference.
- RielaApp owns native-only key-management IPC and settings UI integration.
  Worker issuance verifies the active profile and configured worker identity.
  Native GraphQL admission authenticates before local execution authority.
- RielaCLI reads RIELA_API_KEY (or explicit existing auth options), uses the same
  persistent store for serve and does not use RIELA_MANAGER_AUTH_TOKEN.
- Worker controller policy retains IDs/groups/capacity but no plaintext secrets;
  each worker request resolves its key through the persistent hash store.
- Solid Settings adds issuance, optional expiry date, one-time disclosure, copy,
  revoke and require-client-key toggle; worker settings no longer edit secrets.

## Acceptance evidence

Focused arm64 Swift tests cover hash-only durable storage, concurrent writes,
corruption, exact expiry, revocation, disabled client policy, worker isolation,
configured IDs, private worker credential files, native management, profile
conflicts, all native GraphQL admission and live HTTP workflow execution.
Build current RielaApp executable and inspect current Settings screenshot with
isolated tmp roots. Run web typecheck/lint/unit/build and browser UI tests for
key controls. Run SwiftLint and git diff --check, then independently review the
combined change and refresh README and worker/client authentication docs.

No provider credential issuance or Passkey redesign is included. No publishing
or repository push is part of this request.

## Completion evidence (2026-10-05)

Implemented and independently reviewed with no remaining material findings.
The additional UI request replaced the header's letter R with the existing rail
silhouette shared by Riela's app icon and favicon.

The current `.build/arm64-apple-macosx/debug/RielaApp` was launched directly with
isolated repository tmp roots and `--open-worker-settings`; no `.app` bundle was
used. Its rebuilt `web/src-tauri/target/debug/riela-desktop` displayed API Keys
and the rail mark. Current screenshots captured by CGWindow ID were inspected.
Temporary GUI roots and screenshots were removed after verification.

All Swift commands ran through `/usr/bin/arch -arm64` with the Xcode toolchain
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift`:

```sh
swift build --product RielaApp
swift test --filter 'APIKey|DistributedWorker|DistributedControllerSettingsTests|DistributedConfigurationTransactionTests|ServeHTTPCommandTests|RielaDesktopRequestTests|RielaAppWebAPIRouteTests|TaskHandoverGraphQLProviderTests|WorkflowCommandInspectionTests|ServeWebHostTests|RielaWebRequestSecurityTests'
```

Result: 95 tests passed, zero failures. This includes a real HTTP worker exchange
using persisted issued keys through register/claim/renew/events/complete, followed
by expiry, rotation and revocation. Mac inherited-IPC management tests cover
issuance/expiry/policy/revocation, configured worker binding, stale profile
rejection and HTTP clients being denied key administration. Live workflow HTTP
execution and native task/session routing are covered.

Web commands (under `web/`) passed:

```sh
bun run typecheck
bun run lint
bun run test
bun run desktop:build:debug
bunx playwright test e2e/api-key-settings.spec.ts e2e/desktop-connection.spec.ts e2e/server-authentication.spec.ts e2e/workflow-studio.spec.ts
```

Result: 103 unit tests and 12 browser tests passed. The key-settings browser
test drives the real component with a mocked native transport, including expiry,
one-time disclosure, clearing on dismissal, worker purpose, revocation and policy.
It also checks cancellation without mutation, centered confirmation dialogs,
visible operation captions, a red revoke control beneath the selected-key list,
automatic updates without a refresh button and a 390px layout without overflow.
The Passkey test uses a real isolated `riela serve` and virtual authenticator.
Existing connection/Passkey tests had stale UI selectors; selectors now match
the current summary and workflow list without weakening authentication assertions.
Nine workflow studio browser tests cover the shared button changes outside Settings.

Settings uses a cog icon and navigation retains visible labels. Shared actions
show meaningful icons with their operation names; unmapped actions show their
name without an unrelated fallback arrow. Issuance, client-policy changes and
revocation disclose their effects in confirmation dialogs. The static API Keys
intro and its ineffective refresh control were removed. Dialog screenshots were
inspected for readable content, centered placement and red destructive actions.

Repository-wide SwiftLint exited successfully with unchanged baseline warnings;
changed Swift files have no diagnostics. Exact invocation:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint --quiet
```

`git diff --check` passed. No release, install, commit or push was performed.
