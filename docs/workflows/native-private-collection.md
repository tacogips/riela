# Native private collection (in progress)

The ART migration still needs a whole-workflow guest boundary. Per-agent
isolation cannot protect raw gateway results already stored by a host workflow.

## Embedded X reader (0.2.39)

`riela/x-gateway-reader` calls the pinned XGatewayCore read surface in process on
macOS and Linux. It launches neither a gateway executable nor a second container.
Its queryTemplate / selectFirst / whenFlags / payloadExtras use the common
local gateway contract. Prefer `operation`, JSON `arguments`, and a `select`
field tree for typed requests; see [JSON data processing](json-data-processing.md)
for inline `postprocess` and standalone transform nodes. GraphQL variables are
unsupported by the pinned X CLI surface. Mutation operations are refused.

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

## Whole-workflow boundary (0.2.39)

The `riela/private-workflow` add-on invokes a static workflow through embedded
Riela inside an owned Linux container. The outer workflow declares the guest
image, credential bindings, inner workflow and export schema. No Python or nested
Riela CLI process constructs or coordinates the graph.

```json
{
  "id": "private-collection",
  "addon": {
    "name": "riela/private-workflow",
    "version": "1",
    "config": {
      "workflowId": "collect-and-screen",
      "definitionRoot": "/app/workflows",
      "variables": {"window": "{{input.window}}"},
      "maxConcurrency": 4,
      "maxSteps": 1000,
      "timeoutSeconds": 600,
      "outputSchema": {
        "type": "object",
        "required": ["checkedItems"],
        "properties": {"checkedItems": {"type": "array", "items": {"type": "object"}}},
        "additionalProperties": false
      }
    },
    "env": {"X_GW_TOKEN": {"fromEnv": "SOURCE_X_TOKEN"}},
    "sandbox": {
      "backend": "container",
      "networkPolicy": "egress-allowed",
      "ephemeralHome": true,
      "credentialEnvironment": {"MODEL_AUTH_JSON": ".codex/auth.json"},
      "container": {"runtime": "apple-container", "image": "your-private-workflow-image:version"}
    }
  }
}
```

Package definitions and required executables in the image. Inner agent nodes use
the guest environment directly and do not declare another container. Their model,
prompt, output contract and tool policy remain ordinary authored node settings.
Gateway and deterministic data nodes run within the same guest runtime.

Only the inner root output is returned. Every intermediate step's session,
artifact, working directory and memory reside under a private guest tmpfs root.
The export schema is checked in the guest and controller. It establishes a
structural contract; the authored screening/normalization graph must establish
the semantic boundary for source content.

The worker requires Linux, non-root identity, no capabilities, no-new-privileges
on every current thread, a read-only root and a 256 MiB nosuid/nodev/noexec `/tmp`
tmpfs. A pre-main native initialization sets privilege and process/core limits
before Swift creates threads. The host refuses unsupported configuration and
reserved environment names before launching; there is no host execution fallback.
Selected secrets travel on attached stdin only. Failures use finite fixed text;
provider events, prompt text, usage and vendor session IDs are not exported.
The owned container is removed after completion, deadline or cancellation.

Focused unit coverage exercises builtin dispatch, actual embedded graph execution,
strict final output, metadata rejection, configuration validation, selected-secret
transport and cancellation cleanup. `PrivateWorkflowLiveTests`, enabled with
`RIELA_PRIVATE_WORKFLOW_IMAGE`, checks the real Linux boundary and an inner fake
vendor against synthetic source/auth. It requires a matching 0.2.39 image and
does not contact an account or inference provider. An opt-in test skip is not
evidence that the OS boundary passed.

## ART migration requirements

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
