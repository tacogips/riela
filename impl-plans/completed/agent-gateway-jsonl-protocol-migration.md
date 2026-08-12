# Agent Gateway JSONL Protocol Migration

Status: Completed

## Objective

Move Riela's production Claude Code, Codex, Cursor, direct AI API, and
OpenRouter execution behind a vendor-selectable `agent-gateway server` with a
versioned JSONL stdio protocol and streaming stdout events.

## Implemented work

- Added the independent `agent-gateway` JSONL protocol, server, client, CLI
  vendor executors, direct streaming API executors, and protocol tests.
- Added `AgentGatewayNodeAdapter` as Riela's client and registered it for all
  seven production backend ids.
- Preserved explicit provider name, Base URL, credential environment name,
  model, prompt, working directory, and vendor arguments across the boundary.
- Preserved Riela output-contract normalization and backend-event streaming.
- Kept legacy Riela adapters as compatibility products; they are no longer the
  production dispatcher registrations.

## Verification

- `mise exec -- swift test` in `agent-gateway`
- `mise exec -- swiftlint lint --strict` in `agent-gateway`
- `mise exec -- swift test --filter AgentGatewayNodeAdapterTests` in Riela
- focused Riela provider-routing and adapter tests
- deterministic client/server subprocess smoke with a fake Codex JSONL client
- `git diff --check` in both repositories
