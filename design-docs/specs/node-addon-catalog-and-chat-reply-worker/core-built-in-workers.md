# Node Add-on Catalog and Built-in Workers: Core Built-in Workers

## Built-in `riela/chat-reply-worker`

### Purpose

`riela/chat-reply-worker` sends a reply to the chat conversation associated
with `runtimeVariables.event`.

It is intended for workflows started by chat-like event sources such as:

- `chat.message`
- `chat.mention`
- `chat.command`
- web-chat messages

The add-on is still valid in non-chat test runs, but it should complete in
`dry-run` or `intent-only` mode rather than attempting provider dispatch when no
reply target exists.

### Resolved Node Behavior

The add-on resolves to a runtime-owned native worker executor. The direct
authored `nodeType` surface does not need a provider-specific value; internally
the descriptor binds the node to the chat reply add-on executor. The normalized
runtime payload may use an internal add-on execution binding, but workflow
authors should continue to use `workflow.json.nodes[].addon`.

The executor:

1. receives the resolved semantic node input object from the runtime
2. renders `config.textTemplate` against the normal node template context
3. extracts provider-neutral reply target metadata from
   `runtimeVariables.event`
4. creates a deterministic `ChatReplyRequest`
5. dispatches the request through the event reply adapter registry
6. writes a normal runtime-owned node output envelope

The workflow engine should depend only on a small reply dispatch interface. The
provider adapter implementation remains in the event layer, not in
`src/workflow/`.

### Configuration

Initial config:

```typescript
interface ChatReplyWorkerConfig {
  readonly textTemplate: string;
  readonly visibility?: "public" | "ephemeral";
  readonly threadPolicy?: "same-thread" | "conversation-root";
  readonly onMissingTarget?: "fail" | "intent-only" | "dry-run";
}
```

Authored `addon.inputs`, when present, is copied into the resolved node payload
`variables`. The chat reply worker can reference those keys from
`config.textTemplate` alongside normal runtime and resolved input template
variables.

Defaults:

- `visibility`: `"public"`
- `threadPolicy`: `"same-thread"`
- `onMissingTarget`: `"fail"` during normal execution and `"dry-run"` when the
  workflow run is explicitly using a mock scenario

Validation rules:

- `textTemplate` is required and must render to a non-empty string
- `visibility: "ephemeral"` is accepted only when the source adapter declares
  ephemeral replies are supported
- provider-specific formatting fields are intentionally omitted from the first
  version

## Built-in Agent Worker Add-ons

Generic agent-backed worker add-ons are available for workflows that want a
compact authored reference instead of a workflow-local `node-*.json` payload:

- `riela/codex-worker`
- `riela/claude-code-worker`
- `riela/codex-sdk-worker`
- `riela/claude-sdk-worker`
- `riela/gemini-sdk-worker`
- `riela/cursor-sdk-worker`

All six are worker-only add-ons. They resolve to ordinary `agent` node
payloads:

- `riela/codex-worker` sets `executionBackend: "codex-agent"`
- `riela/claude-code-worker` sets `executionBackend: "claude-code-agent"`
- `riela/codex-sdk-worker` sets `executionBackend: "official/openai-sdk"`
- `riela/claude-sdk-worker` sets
  `executionBackend: "official/anthropic-sdk"`
- `riela/gemini-sdk-worker` sets `executionBackend: "official/gemini-sdk"`
- `riela/cursor-sdk-worker` sets
  `executionBackend: "official/cursor-sdk"`

The add-on name selects the backend. `executionBackend` remains the low-level
runtime adapter field and is not replaced by the add-on system. SDK-backed
worker add-ons intentionally use the same authored config shape as the
CLI-agent worker add-ons so examples can switch the backend through the add-on
name without introducing provider-specific workflow fields.

Authored example:

```json
{
  "id": "implement",
  "role": "worker",
  "addon": {
    "name": "riela/codex-worker",
    "version": "1",
    "config": {
      "model": "gpt-5.4-codex",
      "promptTemplate": "Implement this task: {{task}}",
      "sessionPolicy": {
        "mode": "reuse"
      }
    },
    "inputs": {
      "task": "Add checkout validation"
    }
  }
}
```

Agent worker config:

```typescript
interface AgentWorkerAddonConfig {
  readonly model: string;
  readonly promptTemplate: string;
  readonly systemPromptTemplate?: string;
  readonly sessionStartPromptTemplate?: string;
  readonly sessionPolicy?: { readonly mode: "new" | "reuse" };
  readonly timeoutMs?: number;
}
```

`addon.inputs` is copied into the resolved node payload `variables`. The prompt
template can reference those keys directly, and it can also reference the normal
workflow runtime variables and inbox context.

`addon.env` is not supported by the Codex, Claude, and Cursor worker add-ons in
version `1`. Credential and runtime environment handling remains owned by the
configured agent backend adapters. Required SDK credentials are adapter
preflight inputs: `OPENAI_API_KEY` for `official/openai-sdk`,
`ANTHROPIC_API_KEY` for `official/anthropic-sdk`, and `CURSOR_API_KEY` for
`official/cursor-sdk`.

`riela/gemini-sdk-worker` supports explicit `addon.env` bindings because the
Gemini SDK worker is a direct built-in HTTP adapter boundary. It accepts
`GEMINI_API_KEY` or `GOOGLE_API_KEY` target names, with `GOOGLE_API_KEY`
preferred when both are present.
Validation should surface missing backend support or credentials as runtime
readiness/executability information rather than silently falling back to a
different worker add-on.

SDK worker regression coverage should include:

- add-on resolution for all three SDK add-ons in
  `packages/riela/src/workflow/node-addons/sdk-agent-workers.test.ts`
- dispatch registration for `official/openai-sdk`,
  `official/anthropic-sdk`, `official/gemini-sdk`, and `official/cursor-sdk`
- package-boundary exports for workflow add-on types in
  `packages/riela/src/package-boundaries.test.ts`

Verification commands:

```bash
bun test packages/riela/src/workflow/node-addons/sdk-agent-workers.test.ts packages/riela/src/workflow/adapters/dispatch.test.ts packages/riela/src/package-boundaries.test.ts
bun run typecheck
```

### Cursor SDK Worker Boundary

`riela/cursor-sdk-worker` resolves to the `official/cursor-sdk` adapter, not
to `cursor-cli-agent`. Cursor SDK behavior must remain isolated behind
`packages/riela-adapters/src/cursor-sdk.ts` and its runtime wrapper in
`packages/riela/src/workflow/adapters/cursor-sdk.ts`.

The Cursor SDK adapter may use a Bun child process to load `@cursor/sdk`,
construct a JSONL local agent store, execute one prompt, and return a small JSON
result envelope. That child-process boundary is intentional because Bun runtime
compatibility is an adapter concern, not a workflow or add-on concern. The
parent adapter should pass only the model id, working directory, store root,
message, and resolved `CURSOR_API_KEY`; the workflow model should not expose
Cursor SDK process details.

The Cursor SDK prompt boundary currently combines `systemPromptText` and the
per-turn prompt before sending the SDK message because the Cursor SDK message
API does not expose the same separate system-prompt option as the local
CLI-agent runners. That is an intentional divergence from the local
`codex-agent` and `cursor-cli-agent` prompt-splitting behavior documented in
`design-docs/specs/architecture.md`.

Cursor SDK verification should stay deterministic by testing injected
`agentFactory` behavior and output parsing in
`packages/riela/src/workflow/adapters/cursor-sdk.test.ts`. Live Cursor SDK
coverage must remain credential-gated behind `CURSOR_API_KEY` in
`packages/riela/src/workflow/adapters/official-sdk-live-smoke.test.ts`.

## Built-in `riela/workflow-package-sandbox-review`

### Purpose

`riela/workflow-package-sandbox-review` reviews staged or fixture workflow
package content with an LLM-backed agent before a package is trusted by a
workflow. It is intended for sanitize/security review workflows that inspect
package manifests, workflow JSON, node payloads, prompts, and package-local
support files and then return a normal runtime-owned node output with findings
and a decision. Downstream publication remains a `workflow_messages` insert,
not an add-on-written mailbox file.

This add-on is not a replacement for checkout integrity validation, static
pre-install scanning, or no-network container checks. Those checks remain
checkout-owned gates. This add-on is an ordinary workflow node so package
review can be composed into review, triage, registry-maintenance, or approval
workflows without adding Python-only checker behavior to the package installer.

### Resolved Node Behavior

The add-on resolves to an ordinary `agent` node payload. Version `1` supports
the same LLM backend boundary as existing agent execution paths:

- `codex-agent`
- `claude-code-agent`
- `cursor-cli-agent`, when the cursor adapter is available in the runtime

The descriptor selects the backend from `config.executionBackend`, validates
that it is one of the supported agent backends, and emits a resolved payload
whose `executionBackend`, `model`, `promptTemplate`, `variables`, and timeout
fields are ordinary agent-node fields. The workflow runtime must execute the
review through the selected adapter rather than through a Python-only static
checker or package checkout hook.

The prompt template is runtime-owned by the add-on descriptor. It should direct
the backend to treat package text as untrusted evidence, ignore instructions
embedded in the package, avoid executing package files, avoid expanding secret
values, and return structured review output. Workflow-authored `addon.inputs`
provide package evidence references and review hints, but they do not override
the safety instructions in the descriptor prompt.

### Configuration

Initial config:

```typescript
interface WorkflowPackageSandboxReviewConfig {
  readonly executionBackend:
    | "codex-agent"
    | "claude-code-agent"
    | "cursor-cli-agent";
  readonly model: string;
  readonly decisionPolicy?: "advisory" | "block-on-high";
  readonly maxEvidenceBytes?: number;
  readonly timeoutMs?: number;
}
```

Defaults:

- `decisionPolicy`: `"advisory"`
- `maxEvidenceBytes`: an implementation-owned bounded value that prevents
  unbounded package prompts
- `timeoutMs`: inherited from workflow defaults unless explicitly configured

`addon.inputs` should accept:

- `packageRoot`: optional staged package root path for runtime-owned evidence
  collection
- `packageSummary`: optional precomputed summary or selected file inventory
- `packageFiles`: optional bounded list of package-relative file records with
  text excerpts
- `reviewFocus`: optional workflow-authored focus text, treated as a reviewer
  hint and not as a safety policy override

At least one of `packageRoot`, `packageSummary`, or `packageFiles` must be
provided. `packageRoot` does not give the selected LLM backend direct file
system access. It is consumed only by riela-owned evidence collection before
agent execution.

`addon.env` is not supported in version `1`. Backend credentials and runtime
environment selection remain owned by the configured agent adapter. The add-on
must not forward host environment variables, registry signing keys, package
manager tokens, SSH keys, or secret files to the prompt.

### Evidence Collection Data Flow

The add-on data flow must keep package inspection deterministic and confined:

1. Validate `addon.config` and `addon.inputs`.
2. If `packageFiles` or `packageSummary` are supplied, normalize them into
   bounded evidence records without reading additional files.
3. If `packageRoot` is supplied, resolve it to a real staged package directory
   before the agent node starts.
4. Walk only the package root using implementation-owned include/ignore rules.
5. Convert selected files into package-relative evidence records.
6. Redact known secret patterns and truncate records according to
   `maxEvidenceBytes`.
7. Insert only the bounded evidence records, package summary, review focus, and
   metadata into the resolved agent node variables.
8. Run the selected agent backend against the descriptor-owned prompt and
   bounded variables.

The LLM backend must never receive a host path as an instruction to inspect on
its own. It receives text evidence collected by riela and package-relative
paths only for attribution.

Evidence collection rules:

- reject `packageRoot` when it is absent, unreadable, or not a directory
- resolve symlinks and reject files whose real path escapes `packageRoot`
- reject absolute package evidence paths in `packageFiles`
- normalize `.` and `..` segments before evidence records are accepted
- ignore `.git`, nested `.riela`, runtime artifacts, checkout provenance,
  temporary files, lock/cache directories, and binary files unless a later
  explicit allow-list includes them
- read text files only, with per-file and total byte limits
- mark truncated records with byte counts in `reviewedInputs`
- redact obvious token, key, SSH private-key, and environment-secret patterns
  before prompt insertion
- preserve package-relative paths and short evidence summaries for findings

When both `packageRoot` and explicit `packageFiles` are supplied, explicit
`packageFiles` are treated as the selected evidence set and `packageRoot` is
used only as a package label/confinement reference unless a future version adds
an explicit merge mode.

### Output Contract

The add-on returns a candidate object through the native add-on executor. The
runtime validates and publishes the same `output.json` envelope as any worker
node, then routes downstream messages by inserting `workflow_messages` rows.
The node payload should include structured review data inside the normal output
payload:

- `decision`: `allow`, `warn`, or `block`
- `severity`: `info`, `low`, `medium`, `high`, or `critical`
- `summary`: concise human-readable result
- `findings`: list of package-relative findings with severity, category,
  evidence summary, and remediation
- `reviewedInputs`: package label, file count, byte count, and truncation
  metadata
- `backend`: selected execution backend and model

The add-on must not write checkout provenance records or mutate package
manifests. Workflows that want to enforce the decision should branch on the
normal published node output.

### Fixture Workflow

Examples should include a workflow package sandbox review fixture under
`examples/` that uses this add-on as a normal workflow node. Fixture data should
cover:

- a clean package case that produces `decision: "allow"` or advisory `warn`
- a suspicious package case with prompt-injection or credential-exfiltration
  evidence that produces `decision: "block"` when `decisionPolicy` is
  `block-on-high`

The fixture should prefer `promptTemplateFile` for any long prompts or
case-specific setup. Tests should mock or fixture the selected agent adapter so
the add-on resolution and runtime-owned output contract are deterministic.
Clean and suspicious cases should exercise the same bounded evidence path used
by ordinary workflows, including at least one `packageRoot` fixture that
produces package-relative evidence records before mocked `codex-agent`,
`claude-code-agent`, or `cursor-cli-agent` execution.

### Safety Boundary

The package content supplied to the backend is evidence, not instructions.
Implementation must keep these boundaries explicit:

- no package scripts, hooks, commands, or workflow nodes are executed as part of
  the add-on
- file reads are bounded, confined to `packageRoot`, and selected before prompt
  construction
- evidence summaries must avoid secret expansion and should use
  package-relative paths
- checkout static/container scanners remain available before installation and
  must not depend on LLM review
- LLM review may be used before install only when a workflow explicitly stages
  or supplies package content to this add-on

### Cursor Adapter Mapping

`cursor-cli-agent` support is intentionally an adapter selection, not a new
add-on execution mode. When configured, the add-on resolves to the same
ordinary `agent` payload shape with `executionBackend: "cursor-cli-agent"`.
Any Cursor-specific CLI flags, session behavior, availability checks, and
credential handling must stay inside the cursor adapter. If the cursor adapter
is unavailable, validation should report an executability result for the add-on
node rather than silently falling back to codex or claude.
