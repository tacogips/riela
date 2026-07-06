# Examples

This directory contains reference workflow bundles that can be validated or run
without copying them into `./.riela`.

Each workflow example directory also includes `EXPECTED_RESULTS.md`, which
records the stable assertions used for deterministic verification. Support
directories such as `auto-improve/`, `default-supervisor-dispatcher/`, and
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

## Split Document Index

This document was split into topic files so each tracked text file stays below 1000 lines.

- [Chat, Persona, and Agent Trio Examples](catalog/chat-persona-and-agent-trio.md)
- [Digest, Gateway, and Reply Examples](catalog/digest-gateway-and-reply.md)
- [Workflow Composition and Coding Examples](catalog/workflow-composition-and-coding.md)
- [Showcase and Utility Examples](catalog/showcase-and-utility-examples.md)
