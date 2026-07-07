# Node Add-on Catalog and Built-in Workers: Gateway Built-ins

## Shared Container Runner Rules

All gateway add-ons use the same container runner contract:

- `runnerKind` accepts only `podman`, `docker`, `nerdctl`, or `container`
- `container` selects the Apple `container` CLI by name
- legacy aliases such as `apple` and `apple-container` are not accepted
- `runnerPath`, when provided, is an explicit executable override and takes
  precedence over `runnerKind`
- after template rendering, `runnerPath` or `runnerKind` must resolve to a
  non-empty executable name; empty or whitespace-only values fail before the
  process is launched
- when both fields are omitted, execution defaults to `docker`

## Shared Local CLI Gateway Rules

Gateway add-ons that bridge to a locally installed CLI use a narrower process
contract than container-backed add-ons:

- the runtime invokes a fixed subcommand and fixed argument shape; workflow
  authors cannot provide an arbitrary command line
- `binaryPath`, when provided in `addon.config`, is an explicit executable
  override and takes precedence over environment and `PATH` lookup; it is read
  as a literal `addon.config` value and is not rendered from workflow input,
  upstream payloads, or `addon.inputs`
- the add-on may define one environment fallback for the executable path; if it
  is unset or empty, the runtime resolves the default executable name through
  `PATH`
- no shell interpolation is used; each process argument is passed as a separate
  argument to the subprocess runner
- the child process receives only a minimal environment allowlist needed for
  local process lookup and macOS automation context, not the full ambient
  runtime environment
- stdout must be valid JSON in the upstream gateway GraphQL envelope
- stderr and process status are captured as diagnostics, but successful node
  output is derived from parsed stdout rather than stderr text

## Built-in `riela/apple-notes-list`

### Purpose

`riela/apple-notes-list` runs a read-only Apple Notes GraphQL query through a
locally installed `apple-gateway` CLI. It is intended for workflow nodes that
need to inspect Apple Notes without vendoring `apple-gateway` source or giving
workflow authors arbitrary process execution.

The add-on is worker-only and resolves to a native add-on payload with
`nodeType: "addon"`. Version `1` always invokes:

```bash
apple-gateway graphql --query <rendered-query>
```

The confirmed upstream envelope is a GraphQL JSON object such as:

```json
{
  "data": {
    "permissions": {
      "notesAutomation": "NOT_DETERMINED"
    }
  },
  "extensions": {
    "requestId": "4024CD0C-FF60-4FF5-9150-B53C5AF1EBDF"
  }
}
```

### Authored Example

```json
{
  "id": "list-apple-notes",
  "role": "worker",
  "addon": {
    "name": "riela/apple-notes-list",
    "version": "1",
    "config": {
      "first": 25,
      "includePlaintext": false,
      "includeBodyHtml": false,
      "includeBodyFiles": false,
      "includeAttachments": false
    },
    "inputs": {
      "accountId": "{{workflowInput.accountId}}",
      "folderId": "{{workflowInput.folderId}}",
      "query": "{{workflowInput.query}}"
    }
  }
}
```

### Configuration

```typescript
interface AppleNotesListAddonConfig {
  readonly binaryPath?: string;
  readonly first?: number;
  readonly accountId?: string;
  readonly folderId?: string;
  readonly query?: string;
  readonly modifiedAfter?: string;
  readonly modifiedBefore?: string;
  readonly after?: string;
  readonly includePlaintext?: boolean;
  readonly includeBodyHtml?: boolean;
  readonly includeBodyFiles?: boolean;
  readonly includeAttachments?: boolean;
}
```

Defaults:

- `binaryPath`: `APPLE_GATEWAY_BIN`, then `apple-gateway` resolved through
  `PATH`
- `first`: `25`
- include flags: `false`

Execution behavior:

1. render supported filter values and `addon.inputs` with the normal node
   template context
2. resolve the executable from literal `config.binaryPath`, then
   `APPLE_GATEWAY_BIN`, then `PATH`; `binaryPath` is never sourced from
   workflow input, upstream payloads, or `addon.inputs`
3. run `apple-gateway graphql --query <rendered-query>` with separate process
   arguments, no shell interpolation, and a minimal child environment allowlist
4. parse JSON stdout into `appleNotes.accounts`, `appleNotes.folders`,
   `appleNotes.notes`, `appleNotes.pageInfo`, `appleNotes.totalCount`, and
   `appleNotes.requestId`
5. expose bounded process provenance under `appleGateway.binary`

Validation and error rules:

- version `1` only
- `addon.env` is rejected; the executable fallback reads `APPLE_GATEWAY_BIN`
  from the runtime environment directly
- ambient runtime environment values such as provider API keys, GitHub tokens,
  and Riela secrets are not forwarded to the `apple-gateway` subprocess
- `first` must be between `1` and `100`
- include flags must be booleans
- missing or non-executable binary maps to policy blocked
- non-zero process exit and GraphQL `errors` map to provider error
- malformed JSON or missing GraphQL `data` maps to invalid output

## Built-in `riela/x-gateway-read`

### Purpose

`riela/x-gateway-read` runs a read-only x-gateway GraphQL query in a
Docker-compatible container runner. It is intended for workflow nodes that need
to inspect X/Twitter state without embedding x-gateway-specific container
plumbing or credential forwarding in each workflow-local node payload.

The add-on is worker-only and resolves to a native add-on payload with
`nodeType: "addon"`. The runtime always invokes the read-only
`x-gateway-reader` binary from the configured container image. Workflow authors
cannot override that binary with the full `x-gateway` client.

### Authored Example

```json
{
  "id": "read-post",
  "role": "worker",
  "addon": {
    "name": "riela/x-gateway-read",
    "version": "1",
    "env": {
      "X_GW_TOKEN": {
        "fromEnv": "ACCOUNT_A_X_GW_TOKEN"
      }
    },
    "config": {
      "queryTemplate": "{ post(id: \"{{postId}}\") { id text } }",
      "image": "ghcr.io/tacogips/x-gateway:latest",
      "runnerKind": "docker"
    },
    "inputs": {
      "postId": "123"
    }
  }
}
```

### Configuration

```typescript
interface XGatewayReadAddonConfig {
  readonly queryTemplate: string;
  readonly image?: string;
  readonly runnerKind?: "podman" | "docker" | "nerdctl" | "container";
  readonly runnerPath?: string;
  readonly networkPolicy?: "disabled" | "egress-allowed";
}
```

Defaults:

- `image`: runtime default x-gateway image
- `runnerKind`: `workflow.defaults.containerRuntime.runnerKind` or `docker`
- `runnerPath`: `workflow.defaults.containerRuntime.runnerPath` or the runner
  kind executable name
- `networkPolicy`: runner default egress behavior

Execution behavior:

1. render `config.queryTemplate` with the normal node template context
2. resolve `addon.env` mappings from the riela runtime environment
3. run `x-gateway-reader graphql query <rendered-query> --json` in the
   configured container image
4. parse JSON stdout into the node payload under `xGateway`
5. attach stdout/stderr as process logs

Environment rules:

- `addon.env` is supported for this add-on because the descriptor consumes it
- target and source environment variable names must be valid environment names
- string shorthand means `{ "fromEnv": "<name>" }`
- object bindings may set `required: false`
- only mapped target environment variable names are passed to the container
  process; ambient host environment variables are not forwarded implicitly
- runtime readiness treats this add-on as a Docker-compatible container runner
  requirement, including inherited workflow-level runner defaults
- runtime readiness also reports each required `addon.env` source variable as an
  environment prerequisite; unset or empty required sources block readiness, and
  optional bindings with `required: false` do not block readiness or execution

Validation rules:

- `queryTemplate` is required and must render to a non-empty string
- `runnerKind` must be `podman`, `docker`, `nerdctl`, or `container`
- `networkPolicy` must be `disabled` or `egress-allowed`
- write and mutation surfaces are intentionally omitted from version `1`

## Built-in `riela/x-gateway`

### Purpose

`riela/x-gateway` runs an x-gateway GraphQL document in a Docker-compatible
container runner. It is intended for workflow nodes that intentionally need the
full x-gateway client surface, including post mutations such as creating X
posts, while still keeping credential forwarding explicit and scoped per add-on
node.

The add-on is worker-only and resolves to a native add-on payload with
`nodeType: "addon"`. The runtime always invokes the full `x-gateway` binary
from the configured container image. Workflow authors cannot override that
binary or supply an arbitrary command.

### Authored Example

```json
{
  "id": "post-to-x",
  "role": "worker",
  "addon": {
    "name": "riela/x-gateway",
    "version": "1",
    "env": {
      "X_GW_CONSUMER_KEY": {
        "fromEnv": "ACCOUNT_A_X_GW_CONSUMER_KEY"
      },
      "X_GW_CONSUMER_SECRET": {
        "fromEnv": "ACCOUNT_A_X_GW_CONSUMER_SECRET"
      },
      "X_GW_ACCESS_TOKEN": {
        "fromEnv": "ACCOUNT_A_X_GW_ACCESS_TOKEN"
      },
      "X_GW_ACCESS_TOKEN_SECRET": {
        "fromEnv": "ACCOUNT_A_X_GW_ACCESS_TOKEN_SECRET"
      }
    },
    "config": {
      "documentTemplate": "mutation { createPost(text: \"{{postText}}\") { id text } }",
      "image": "ghcr.io/tacogips/x-gateway:latest",
      "runnerKind": "docker"
    },
    "inputs": {
      "postText": "Hello from riela"
    }
  }
}
```

### Configuration

```typescript
interface XGatewayAddonConfig {
  readonly documentTemplate: string;
  readonly image?: string;
  readonly runnerKind?: "podman" | "docker" | "nerdctl" | "container";
  readonly runnerPath?: string;
  readonly networkPolicy?: "disabled" | "egress-allowed";
}
```

Defaults:

- `image`: runtime default x-gateway image
- `runnerKind`: `workflow.defaults.containerRuntime.runnerKind` or `docker`
- `runnerPath`: `workflow.defaults.containerRuntime.runnerPath` or the runner
  kind executable name
- `networkPolicy`: runner default egress behavior

Execution behavior:

1. render `config.documentTemplate` with the normal node template context
2. resolve `addon.env` mappings from the riela runtime environment
3. run `x-gateway graphql query <rendered-document> --json` in the configured
   container image
4. parse JSON stdout into the node payload under `xGateway`
5. attach stdout/stderr as process logs

Environment rules match `riela/x-gateway-read`: only explicitly mapped target
environment variable names are exposed to the container, required source
variables are runtime readiness prerequisites, and optional bindings may set
`required: false`.

Validation rules:

- `documentTemplate` is required and must render to a non-empty string
- `runnerKind` must be `podman`, `docker`, `nerdctl`, or `container`
- `networkPolicy` must be `disabled` or `egress-allowed`
- command or binary overrides are rejected; version `1` always runs
  `x-gateway`

## Built-in `riela/mail-gateway-read`

### Purpose

`riela/mail-gateway-read` runs a read-only mail-gateway GraphQL query in a
Docker-compatible container runner. It is intended for workflow nodes that need
to inspect configured mail accounts without embedding mail-gateway-specific
container plumbing or credential path forwarding in each workflow-local node
payload.

The add-on is worker-only and resolves to a native add-on payload with
`nodeType: "addon"`. The runtime always invokes the read-only
`mail-gateway-reader` binary from the configured container image. Workflow
authors cannot override that binary with the full `mail-gateway` client.

### Authored Example

```json
{
  "id": "read-mail",
  "role": "worker",
  "addon": {
    "name": "riela/mail-gateway-read",
    "version": "1",
    "env": {
      "MAIL_GATEWAY_CONFIG": {
        "fromEnv": "ACCOUNT_A_MAIL_GATEWAY_CONFIG"
      }
    },
    "config": {
      "queryTemplate": "{ message(accountId: \"{{accountId}}\", messageId: \"{{messageId}}\") { id subject } }",
      "image": "ghcr.io/tacogips/mail-gateway:latest",
      "runnerKind": "docker"
    },
    "inputs": {
      "accountId": "work",
      "messageId": "msg-123"
    }
  }
}
```

### Configuration

```typescript
interface MailGatewayReadAddonConfig {
  readonly queryTemplate: string;
  readonly image?: string;
  readonly runnerKind?: "podman" | "docker" | "nerdctl" | "container";
  readonly runnerPath?: string;
  readonly networkPolicy?: "disabled" | "egress-allowed";
}
```

Defaults:

- `image`: runtime default mail-gateway image
- `runnerKind`: `workflow.defaults.containerRuntime.runnerKind` or `docker`
- `runnerPath`: `workflow.defaults.containerRuntime.runnerPath` or the runner
  kind executable name
- `networkPolicy`: runner default egress behavior

Execution behavior:

1. render `config.queryTemplate` with the normal node template context
2. resolve `addon.env` mappings from the riela runtime environment
3. run `mail-gateway-reader graphql --query <rendered-query>` in the configured
   container image
4. parse JSON stdout into the node payload under `mailGateway`
5. attach stdout/stderr as process logs

Environment rules match the gateway add-ons above: only explicitly mapped target
environment variable names are exposed to the container, required source
variables are runtime readiness prerequisites, and optional bindings may set
`required: false`.

Validation rules:

- `queryTemplate` is required and must render to a non-empty string
- `runnerKind` must be `podman`, `docker`, `nerdctl`, or `container`
- `networkPolicy` must be `disabled` or `egress-allowed`
- send and mutation surfaces are intentionally omitted from version `1`

## Built-in `riela/mail-gateway`

### Purpose

`riela/mail-gateway` runs a mail-gateway GraphQL document in a
Docker-compatible container runner. It is intended for workflow nodes that
intentionally need the full mail-gateway client surface, including send
mutations such as `sendMessage`, while still keeping credential forwarding
explicit and scoped per add-on node.

The add-on is worker-only and resolves to a native add-on payload with
`nodeType: "addon"`. The runtime always invokes the full `mail-gateway` binary
from the configured container image. Workflow authors cannot override that
binary or supply an arbitrary command.

### Authored Example

```json
{
  "id": "send-mail",
  "role": "worker",
  "addon": {
    "name": "riela/mail-gateway",
    "version": "1",
    "env": {
      "MAIL_GATEWAY_CONFIG": {
        "fromEnv": "ACCOUNT_A_MAIL_GATEWAY_CONFIG"
      }
    },
    "config": {
      "documentTemplate": "mutation { sendMessage(input: { accountId: \"{{accountId}}\", to: [\"{{to}}\"], subject: \"{{subject}}\", textBody: \"{{body}}\" }) { message { id subject } } }",
      "image": "ghcr.io/tacogips/mail-gateway:latest",
      "runnerKind": "docker"
    },
    "inputs": {
      "accountId": "work",
      "to": "person@example.test",
      "subject": "Hello",
      "body": "Hello from riela"
    }
  }
}
```

### Configuration

```typescript
interface MailGatewayAddonConfig {
  readonly documentTemplate: string;
  readonly image?: string;
  readonly runnerKind?: "podman" | "docker" | "nerdctl" | "container";
  readonly runnerPath?: string;
  readonly networkPolicy?: "disabled" | "egress-allowed";
}
```

Defaults:

- `image`: runtime default mail-gateway image
- `runnerKind`: `workflow.defaults.containerRuntime.runnerKind` or `docker`
- `runnerPath`: `workflow.defaults.containerRuntime.runnerPath` or the runner
  kind executable name
- `networkPolicy`: runner default egress behavior

Execution behavior:

1. render `config.documentTemplate` with the normal node template context
2. resolve `addon.env` mappings from the riela runtime environment
3. run `mail-gateway graphql --query <rendered-document>` in the configured
   container image
4. parse JSON stdout into the node payload under `mailGateway`
5. attach stdout/stderr as process logs

Environment rules match `riela/mail-gateway-read`: only explicitly mapped
target environment variable names are exposed to the container, required source
variables are runtime readiness prerequisites, and optional bindings may set
`required: false`.

Validation rules:

- `documentTemplate` is required and must render to a non-empty string
- `runnerKind` must be `podman`, `docker`, `nerdctl`, or `container`
- `networkPolicy` must be `disabled` or `egress-allowed`
- command or binary overrides are rejected; version `1` always runs
  `mail-gateway`

### Reply Target Metadata

The event trigger layer should expose reply target data in
`runtimeVariables.event`.

Provider-specific event adapters normalize their incoming data into a
provider-neutral shape:

```typescript
interface EventReplyTarget {
  readonly sourceId: string;
  readonly provider: string;
  readonly eventId: string;
  readonly conversationId: string;
  readonly threadId?: string;
  readonly actorId?: string;
  readonly capabilities?: readonly ChatReplyCapability[];
}
```

Rules:

- credentials, channel secrets, and webhook signing data are never copied into
  `runtimeVariables.event`
- adapters may store provider raw payloads as event artifacts and expose only
  stable references
- missing reply target metadata is a configuration/runtime error unless
  `onMissingTarget` allows intent-only or dry-run behavior

### Reply Request

The executor submits this provider-neutral request:

```typescript
interface ChatReplyRequest {
  readonly target: EventReplyTarget;
  readonly message: {
    readonly text: string;
  };
  readonly visibility: "public" | "ephemeral";
  readonly idempotencyKey: string;
  readonly workflowId: string;
  readonly workflowExecutionId: string;
  readonly nodeId: string;
  readonly nodeExecId: string;
}
```

The idempotency key must be stable for the node execution. A retry of the same
node execution must not post duplicate chat messages.

### Output Contract

The add-on publishes an ordinary node output payload:

```json
{
  "reply": {
    "status": "sent",
    "target": {
      "sourceId": "web-chat",
      "provider": "web-chat",
      "conversationId": "thread-123"
    },
    "message": {
      "text": "The workflow result is ready."
    },
    "providerMessageId": "msg-456",
    "dispatchId": "reply-789"
  },
  "when": {
    "replied": true
  }
}
```

Allowed `reply.status` values:

- `sent`: provider dispatch completed successfully
- `queued`: provider adapter accepted the request for asynchronous delivery
- `intent-only`: the node produced a reply intent but did not dispatch it
- `dry-run`: no provider dispatch was attempted

Failure rules:

- provider rejection fails the node unless a future config explicitly allows
  best-effort replies
- an invalid rendered message fails the node
- duplicate dispatch for the same idempotency key must return the original
  dispatch result when the adapter can determine it
