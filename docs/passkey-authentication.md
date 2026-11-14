# Console Passkey authentication

Local Tauri requests use inherited IPC and need no authentication. A public
`riela serve` console requires `RIELA_WEB_ORIGIN` and registered Passkeys. Both
browser and desktop users authenticate at that server's origin. RielaApp's
optional loopback web server retains its local access policy.

The server pins [swift-server/swift-webauthn](https://github.com/swift-server/swift-webauthn/tree/1.0.0-beta.1) 1.0.0-beta.1 for WebAuthn signature,
RP ID hash, origin, challenge, presence, verification and sign-counter checks.
Riela additionally checks credential ID binding, discoverable user-handle
binding, cross-origin client data, backup eligibility/state, invitation scope,
credential uniqueness, account/key revocation and ceremony purpose. Registration
uses `attestation: none`, discoverable credentials and required user verification.
No private keys are uploaded or persisted by the server.

## Protocol

All authentication JSON endpoints live under `/api/v1/auth/`. Except GET
`status`, they require POST, the configured Host and Origin, JSON content type
and a body of at most 64 KiB. Login and registration do not require an existing
session or the console CSRF value; their one-use ceremonies provide the binding.
Normal console mutations continue to require the console CSRF value.

- `register/options` takes a CLI-issued invitation. `register/finish` verifies
  the resulting WebAuthn credential and atomically consumes the invitation.
- `login/options` creates a discoverable Passkey assertion challenge.
  `login/finish` verifies the assertion and returns an eight-hour session.
- `device/start` returns a browser verification URL, comparison code and a
  separate high-entropy polling secret. The URL contains only the device ID.
- The browser displays the code and explicitly starts `login/options` with
  `deviceID`. Its verified `login/finish` approves that device without returning
  a session to the browser.
- `device/poll` requires both the device ID and polling secret. It consumes the
  approved grant once and returns the session to the initiating desktop window.
  `device/cancel` invalidates the grant with the same secret.
- `logout` deletes the session. Key/user revocation is checked on every request.

Sessions and polling secrets stay in page/process memory. Durable state contains
public credentials, user handles and hashed invitations, protected with a local
cross-process file lock and atomic writes. This store supports one serving
process; it is not a shared session database for multiple replicas. Sessions and
pending ceremonies are lost at restart. Invitation lifetime is 15 minutes;
ceremony and desktop grant lifetimes are five minutes. Pending collections are
bounded, and new ceremony/device starts are limited to 60 per minute per server.

Tauri opens only a validated server-origin login URL using the system browser.
It polls through its native HTTP transport, which refuses redirects and does
not forward local cookies. The bundled webview retains its existing restricted
CSP; no remote script or web page receives native IPC authority.

## Verification

Build the real server and bundled web assets before running browser tests:

```sh
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --product riela
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'RielaPasskeyTests|ServeWebHostTests|PasskeyCommandTests'
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint --quiet
cd web
bun run typecheck
bun run lint
bun test src
bun run build
bunx playwright test e2e/server-authentication.spec.ts e2e/passkey-desktop.spec.ts e2e/desktop-connection.spec.ts
cargo test --locked --manifest-path src-tauri/Cargo.toml
```

On Linux, use the installed Swift toolchain. Browser tests launch isolated real
`riela serve` processes under repository `tmp/`, issue invitations through the
real CLI and use Chromium's virtual CTAP2 authenticator. Desktop browser tests
substitute the IPC bridge with a test binding; they exercise the real remote
HTTP authentication and handoff, while Rust tests cover native request transport
and system-browser URL validation. They do not automate a physical Touch ID,
security-key or OS Passkey-provider prompt.

Verified on macOS on 2026-09-10: `swift build --product riela` using the explicit
Xcode path above; the focused Swift filter
`RielaPasskeyTests|PasskeyCommandTests|ServeWebHostTests|ServeHTTPCommandTests|RielaStaticAssetResolverTests`
passed 18 tests. `bun test src` passed 95 tests and `bun run test:e2e` passed all
42 tests. The three authentication E2E cases were rerun after the authentication
layout changes; the real-server browser test also verified an authenticated
appearance-setting mutation. Rust's locked test run passed nine tests, and the locked debug
desktop build succeeded. TypeScript, ESLint and source audit passed; SwiftLint
reported no new warnings in the changed authentication files. Registration and
desktop approval screenshots were reviewed. Physical Passkey providers, a live
HTTPS reverse proxy and the native Tauri window were not part of this automated
end-to-end verification.
