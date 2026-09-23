# Gateway SDK worktree dependency identities

## Operator decision

Option 2 is selected. Consume all five gateways from their public repositories
at exact released versions, while keeping GatewaySDKKit at exact `0.1.0`:

- `https://github.com/tacogips/wrike-gateway.git`, `0.2.4`
- `https://github.com/tacogips/google-analytics-gateway.git`, `0.1.1`
- `https://github.com/tacogips/gmail-gateway.git`, `0.1.11`
- `https://github.com/tacogips/google-documents-gateway.git`, `0.3.1`
- `https://github.com/tacogips/apple-gateway.git`, `0.1.7`

The operator aligned google-documents-gateway with the public exact
GatewaySDKKit `0.1.0` dependency before publishing `0.3.1`.

## Blocking evidence

The requested paths all end in `gateway-sdk`:

```text
../../wrike-gateway-worktrees/gateway-sdk
../../google-analytics-gateway-worktrees/gateway-sdk
../../gmail-gateway-worktrees/gateway-sdk
../../google-documents-gateway-worktrees/gateway-sdk
../../apple-gateway-worktrees/gateway-sdk
```

SwiftPM derives the identity `gateway-sdk` from each path and rejects multiple
entries. An explicit dependency display name does not change that identity.

The google-documents worktree also currently declares:

```swift
.package(path: "../../gateway-sdk-kit")
```

When Riela declares the required public exact `0.1.0` URL, SwiftPM warns that
the URL and local path share identity `gateway-sdk-kit` and resolves the local
path. That does not prove the accepted exact-version dependency and is expected
to become an error in a future SwiftPM release.

Evidence commands:

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift package show-dependencies --format json
rg -n 'gateway-sdk-kit|GatewaySDKKit' /Users/taco/gits/tacogips/google-documents-gateway-worktrees/gateway-sdk/Package.swift
```

## Options

1. **Operator prepares unique worktree leaf names and aligns the transitive kit
   dependency (recommended).** Recreate or expose the five feature worktrees at
   stable paths ending in distinct package identities such as
   `wrike-gateway`, `google-analytics-gateway`, `gmail-gateway`,
   `google-documents-gateway`, and `apple-gateway`. In the
   google-documents repository, the operator changes its GatewaySDKKit
   requirement to the same public exact `0.1.0` URL. Provide the final paths to
   this workflow and amend the brief's path examples. This workflow still does
   not modify any external checkout.
2. **Use URL and revision pins for the five gateways now.** Supply the five
   revisions and revise the acceptance signal that currently requires path
   dependencies. GatewaySDKKit remains exact `0.1.0`.
3. **Authorize repository-owned local aliases.** Approve committed, stable
   alias paths with distinct leaf names and define their CI setup. This is not
   recommended because symlinks escaping the repository are brittle and do not
   solve google-documents' transitive kit conflict by themselves.

## Recorded response

Option 2 and the exact repository/version pairs above are authoritative. No
worktree path or repository-owned alias is used.

## Readiness gate

After the decision is applied, this command must exit zero without an identity
warning:

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift package show-dependencies --format json
```

The JSON must contain five distinct gateway identities and one
`gateway-sdk-kit` node sourced from
`https://github.com/tacogips/gateway-sdk-kit.git` at version `0.1.0`.
