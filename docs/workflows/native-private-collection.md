# Native private collection (in progress)

The ART migration still needs a whole-workflow guest boundary. Per-agent
isolation cannot protect raw gateway results already stored by a host workflow.

## Embedded X reader (0.2.39)

`riela/x-gateway-reader` calls the pinned XGatewayCore read surface in process on
macOS and Linux. It launches neither a gateway executable nor a second container.
Its queryTemplate / selectFirst / whenFlags / payloadExtras use the common
local gateway contract. GraphQL variables are unsupported by the pinned X CLI
surface; render values in the authored document. Mutation operations are refused.

```json
{
  "id": "account",
  "addon": {
    "name": "riela/x-gateway-reader",
    "version": "1",
    "config": {"queryTemplate": "query { accountMe { id username } }"},
    "env": {"X_GW_TOKEN": {"fromEnv": "SOURCE_X_TOKEN"}}
  }
}
```

Only the six X token/OAuth1 credential names may be env binding targets. The SDK
gets one HTTP attempt with a timeout bounded by the node deadline and 30 seconds;
the workflow owns pagination, retry and partial-result decisions. Provider error
bodies are replaced by fixed messages. Its raw output remains in the calling
runtime: use the private workflow boundary for ART acquisition before making it
an active source node.

## Required next runtime boundary

- An authored private-workflow add-on must run a complete static workflow inside
  the owned container via embedded Riela, with no Python process/CLI coordinator.
- Reuse the ephemeral detached-init/attached-exec lifecycle. No writable host
  shares, provider/tool events, raw inner session records or secret environment
  values may leave guest tmpfs. Only an explicit validated root schema crosses.
- Project selected runtime environment bindings on stdin, never container argv
  or client environment. Model auth files are created only in guest HOME.
- Verify read-only root, non-root identity, capability removal, no-new-privileges
  and bounded nosuid/nodev/noexec tmpfs before reading private input.
- Root output gets guest and controller validation. Failures are finite fixed
  errors. Deadline/cancellation reaps the exact owned container.
- Run generic builtins, static agent nodes, source pagination/fanout and small ART
  domain format/validation nodes inside this boundary. Keep controller-owned
  durable checkpoints and cache reference protection as explicit builtin steps.
- GmailGatewayCore's Linux support must be adapted before moving Gmail's read
  node into this graph. Preserve its token/auth lifecycle and read-only tier.

This foundation is not an ART deployment or completion of Python minimization.
