# Node Add-on Catalog and Built-in Workers: Responsibilities, Security, and Tests

## Event Layer Responsibilities

The event layer owns provider reply dispatch.

Required service boundary:

```typescript
interface EventReplyDispatcher {
  dispatchChatReply(
    request: ChatReplyRequest,
  ): Promise<ChatReplyDispatchResult>;
}
```

Responsibilities:

- route by `target.sourceId` to the configured event source adapter
- enforce source adapter capabilities
- apply credentials and provider-specific endpoint details from event source
  configuration, not workflow JSON
- persist reply receipts for audit and idempotency
- normalize provider response metadata into `ChatReplyDispatchResult`

The chat reply worker add-on consumes that interface. It does not import Slack,
Discord, Telegram, or web-chat SDKs directly.

## Security and Supply Chain

Current rules:

- built-in `riela/*` add-ons resolve through the installed runtime catalog
- non-`riela/` add-ons resolve only when the host process explicitly provides
  resolver functions
- no network access occurs during workflow load or validation
- unknown or unhandled add-on names fail validation
- add-on descriptors are part of the installed runtime and are covered by the
  same release integrity model as the rest of `riela`
- external add-on registries, package downloads, and lockfiles are future work

Future distributed add-on support must require:

- an explicit add-on lockfile with resolved package identity and integrity
- no install scripts by default
- a local cache populated by an explicit operator command
- descriptor schema validation before any executable payload is trusted

## Compatibility

Existing workflows using `nodeFile` continue unchanged.

Add-on nodes are additive:

- authored `nodeFile` nodes remain the default
- normalized runtime payloads can use the same execution, output validation, and
  artifact publication paths as ordinary nodes
- GraphQL and TUI surfaces should display add-on provenance alongside node type
  and role
- examples can introduce add-on usage without changing existing bundle layout

## Test Expectations

The implementation should cover:

- validation rejects a node reference with both `nodeFile` and `addon`
- validation rejects a node reference with neither `nodeFile` nor `addon`
- validation rejects unknown built-in add-on names and unsupported versions
- validation rejects invalid chat reply add-on config
- validation rejects `addon.env` for descriptors that do not consume explicit
  environment bindings
- validation accepts `addon.inputs` and materializes them as resolved payload
  `variables`
- validation rejects workflow-local node payload files that author runtime-only
  `nodeType: "addon"` instead of using `workflow.json.nodes[].addon`
- validation accepts the built-in agent worker add-ons, both x-gateway add-ons,
  both mail-gateway add-ons, `riela/apple-notes-list`, and the Apple Notes CRUD
  add-ons `riela/apple-note-get`, `riela/apple-note-create`,
  `riela/apple-note-update-body`, `riela/apple-note-delete`, and
  `riela/apple-note-move`
- loader materializes an effective payload with the authored node id
- workflow save/edit preserves the authored `addon` reference
- chat reply worker renders text from upstream output
- chat reply worker fails when no reply target exists and `onMissingTarget` is
  `fail`
- chat reply worker emits `intent-only` or `dry-run` output when configured
- reply dispatch is idempotent across node retry/resume
- provider-specific adapter code stays outside `src/workflow/`
- local CLI gateway add-on tests use fake executables and cover argument
  construction, executable resolution precedence, provider error envelopes,
  malformed JSON, non-zero exits, and missing binary behavior without live
  Apple app access
- local CLI gateway add-on tests prove executable selection cannot be driven by
  workflow input, upstream payloads, or `addon.inputs`, and that secret-like
  runtime environment variables are not forwarded to fake executables
- Apple Notes CRUD add-on tests cover fixed GraphQL operation dispatch,
  `--variables` transport for user-controlled values, bodyFile materialization
  through a private download root, mutation output flags, unsupported versions,
  rejected `addon.env`, timeout handling, malformed envelopes, missing mutation
  fields, `NOTE_LOCKED`, and permission-denied errors without live Apple app
  access

## References

- `design-docs/specs/design-event-listener-workflow-trigger.md`
- `design-docs/specs/design-node-execution-inbox-contract.md`
- `design-docs/specs/design-node-output-contract.md`
- `design-docs/specs/design-workflow-json.md`
