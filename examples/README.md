# Examples

This directory contains reference workflow bundles that can be validated or run
without copying them into `./.riela`.

Each workflow example directory also includes `EXPECTED_RESULTS.md`, which
records the stable assertions used for deterministic verification. Support
directories such as `task-repair-loop/`, `task-agent-director/`,
`default-supervisor-dispatcher/`, and
`event-sources/` document cross-workflow demos and fixtures.

Shipped reference bundles use the step-addressed authored shape; repository
tests may still construct legacy fixtures under explicit non-strict validation.

- most bundles use `workflow -> steps[] + nodes[]`, where `entryStepId`
  names the authored entry step and `nodes[]` is a reusable registry
- `workflow-call-simple` is fully step-addressed; cross-workflow invocation is
  authored as a `steps[].transitions[]` entry with `toWorkflowId` and
  `resumeStepId` (executed as a derived cross-workflow dispatch at runtime; not stored on `workflow.workflowCalls`)
- shipped workflow bundles omit structural `subWorkflows` and
  `subWorkflowConversations`; multi-round demos use explicit steps (for example a
  judge step with labeled `transitions`, as in `codex-codex-topic-debate` and
  the foreach lane in `node-combinations-showcase`)
- node payload files live under `nodes/` by default
- grouped lane payloads may live under `workflows/*/nodes/`
- `worker-only-single-step/EXPECTED_RESULTS.md` includes a named-instance demo
  that runs the same workflow with two saved execution configurations
- `open-model-provider-codex/` demonstrates canonical `provider` and
  `providerProxy` routing to a loopback OpenAI-compatible endpoint
- `monja-typescript-sdk/` installs a locally packed `@monja/client` into an
  isolated Node ESM consumer and proves typed REST plus arbitrary GraphQL
  execution through Riela's command-node JSONL boundary

## Split Document Index

This document was split into topic files so each tracked text file stays below 1000 lines.

- [Chat, Persona, and Agent Trio Examples](catalog/chat-persona-and-agent-trio.md)
- [Digest, Gateway, and Reply Examples](catalog/digest-gateway-and-reply.md)
- [Workflow Composition and Coding Examples](catalog/workflow-composition-and-coding.md)
- [Showcase and Utility Examples](catalog/showcase-and-utility-examples.md)
- `definition-store-self-improvement` demonstrates a bounded previous-run digest and audited prompt update through the builtin improvement node.

## Voice assistant (issue #185)

- `voice-assistant/` — `riela voice listen` WAV inbox → `file-change` source →
  multi-vendor `riela/speech-to-text` → `riela/utterance-match` wake phrase and
  intent table → allowlisted `riela/home-assistant-write` fast path or an agent
  that answers / registers a routine → `riela/text-to-speech`.
- `voice-routine-runner/` — presence-gated routine tick: speak, defer to a
  per-room `riela/durable-queue`, or skip.
- `announcement-deliver/` — Home Assistant presence trigger drains a room's
  deferred announcements, skipping expired ones.
