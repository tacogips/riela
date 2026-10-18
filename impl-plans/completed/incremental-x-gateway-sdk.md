# Incremental X gateway acquisition

Upstream issue: https://github.com/tacogips/x-gateway/issues/2
Released SDK: https://github.com/tacogips/x-gateway/releases/tag/v0.1.8

The caller requires persistent per-query watermarks to avoid reacquiring old
posts. Upgrade both native XGatewayCore and the official X reader/writer image
to release commit 9421ddcc264d7692e6f6135445f42993b854a334. The SDK adds optional
recent `searchPosts` sinceId and nextToken, mapping directly to X request
parameters. The caller owns watermark persistence and completion semantics.

Validation: 12 GatewayCommandTests/PasskeyCommandTests passed against exact
0.1.8. The official Docker image rebuilt successfully. All four opt-in
GatewayContainerImageIntegrationTests passed, including a credential-free,
network-denied schema check for the new arguments; Gmail read-only credential
lock and mutation restrictions remain covered. Changed Swift file passed lint.

X release gates: 20 SDK tests, full lint, mise CI, both architecture and role
archive checks, both Homebrew strict audits/fetch/upgrade/tests, and metadata
workflow/public raw JSON version/checksum validation passed. Nix unavailable
(no Nix executable or flake files in the SDK checkout).
