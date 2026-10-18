# Gateway reader privacy and credential home

Issue: https://github.com/tacogips/riela/issues/140

Scope: remove caller workarounds required for authenticated Gmail reads and safe
Docker/Podman reader transport. Keep the pinned SDK and existing non-gateway
container launcher contracts intact.

- [x] Give the official Gmail image UID/GID 10001 and a private passwd home under
  writable `/tmp`; wrap reader/draft/sender names so explicit reader entrypoint
  selection initializes the same home.
- [x] Add opt-in name-only environment forwarding and disabled persistent logging
  to the shared runtime driver; enable both in dedicated gateway execution.
- [x] Restrict gateway target names to valid uppercase provider namespaces to
  prevent host runtime/loader/interpreter environment injection. Supply resolved
  values explicitly and retain only host runtime connection/configuration keys.
- [x] Preserve other driver callers' inline-environment behavior and document
  Apple Container/custom runtime logging limitations.
- [x] Verify image locking and permissions with coherent synthetic inline OAuth
  credentials, denied networking, and a read-only root. Correct old offline image
  fixtures to bind persistent credential metadata and select asserted fields.

Validation (macOS arm64, Docker/Colima, 2026-10-18):

- `scripts/build-gateway-container.sh gmail docker` passed.
- `swift build --product riela` passed from an arm64 shell.
- `RIELA_TEST_LIVE_GATEWAY_IMAGES=1 RIELA_TEST_GATEWAY_RUNTIME=docker swift test
  --filter 'BuiltinContainerGatewayAddonTests|GatewayContainerImageIntegrationTests|ContainerWorkflowAddonResolverTests|BuiltinAddonContainerResolverTests'`:
  39 tests, 1 optional Apple live test skipped, 0 failures.
- Changed-file `swiftlint lint --quiet` and `git diff --check` passed.
- ART caller independently passed 37 tests, its privacy capability probe, doctor
  with secret-presence checks, real Gmail profile and X search probes using the
  fixed source CLI and official image without a runtime shim or derived image.

The separate Apple Notes parent-folder defect is recorded at
https://github.com/tacogips/apple-gateway/issues/7. No unpublished SDK pin or
folder-creation API expansion is included in this fix.
