# Delegated builtin gateway CLI

Issue: https://github.com/tacogips/riela/issues/141

User requirement: builtin gateway commands must be recognizably gateway-owned,
with authentication available through Riela instead of standalone binaries.

- [x] Add `riela gateway list [--json]` and
  `riela gateway NAME [--role ROLE] <native gateway arguments...>`.
- [x] Dispatch original CLI/library surfaces in-process for Gmail, X, Apple,
  Wrike, Google Service, Analytics, Docs, Sheets, and Drive. Preserve native
  Google credential bootstrap and provider-specific roles/help/operations.
- [x] Add public, resolvable X SDK dependency after a minimal upstream Swift
  Crypto compatibility fix; retain Riela's existing Swift Crypto requirement.
- [x] Keep `riela auth` passkeys and workflow add-on restrictions unchanged.
- [x] Cover parser routing, catalog parity, role validation, all-provider
  dispatch, and synthetic/isolated native help/status without destructive auth
  actions or unrequested interactive logins. Document canonical commands.

Validation: arm64 `swift test --filter 'GatewayCommandTests|PasskeyCommandTests'`
passed 12 tests with zero failures against released X SDK 0.1.7. Changed Swift
files passed SwiftLint; native build passed. Parent independently checked all
nine provider help routes, Gmail auth status, Apple permissions status, X auth
scopes, and reviewed bootstrap/dispatch boundaries. No interactive OAuth or
credential revocation was performed.

The broad pre-existing SurfaceParityCLITests gate still reports missing catalog
rows for `memory history`, `memory show-version`, and `memory restore-version`.
The new gateway-only catalog parity test passes; unrelated memory rows remain
outside this change.

X release: https://github.com/tacogips/x-gateway/releases/tag/v0.1.7
Source commit: 4eb610a0b53f517572851b4a96494b0e5ad92e9c. Swift Crypto remains
4.5.2. Subsequent incremental-source support is tracked separately.
