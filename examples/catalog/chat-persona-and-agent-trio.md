# Examples: Chat, Persona, and Agent Trio Examples

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

## Available Examples

### `temporary-workflow`

Temporary workflow payload runnable directly from inline JSON or a JSON file
without project or user scope installation:

- stores the complete temporary payload in `temp-workflow.json`
- embeds the node prompt directly in JSON instead of using `prompts/*.md`
- can be run with `--workflow-json-file` or `--workflow-json`
- dry-run commands verify validation, source metadata, and
  `temporary-workflow-payload/` artifact logging without calling an agent backend

Run it from the JSON file:

```bash
riela workflow run \
  --workflow-json-file ./examples/temporary-workflow/temp-workflow.json \
  --dry-run \
  --output json \
  --artifact-root ./tmp/temporary-workflow-example/file-artifacts \
  --session-store ./tmp/temporary-workflow-example/file-sessions
```

See `examples/temporary-workflow/README.md` for the inline JSON command and
payload-log inspection command.

### `worker-only-single-step`

Minimal runnable reference for a manager-less workflow:

- no authored `managerStepId`
- explicit `entryStepId: "main-worker"`
- one `codex-agent` worker node runs directly from workflow start
- includes a deterministic mock scenario for validate/inspect/run demos

Validate it:

```bash
riela workflow validate worker-only-single-step --workflow-definition-dir ./examples
```

Inspect it:

```bash
riela workflow inspect worker-only-single-step --workflow-definition-dir ./examples --output json
```

Run it with the bundled deterministic scenario:

```bash
riela workflow run worker-only-single-step \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/worker-only-single-step/mock-scenario.json \
  --output json
```

### `supervised-mock-retry`

Same shape as `worker-only-single-step`, but the bundled `mock-scenario.json` is
a **two-entry sequence** for the worker: the first entry forces a failure; after
a supervised outer rerun, the second entry returns success. Use with
`--auto-improve` to exercise the failure-to-rerun path without custom adapters.
See `examples/auto-improve/README.md` and `examples/supervised-mock-retry/EXPECTED_RESULTS.md`.

### `default-superviser`

Minimal **phase-2 nested superviser** reference bundle (`workflowId`:
`riela-default-superviser`): one step invokes `riela/start-workflow` so a
nested superviser run can start the paired target when the engine injects
`supervisionRunId`, `targetSessionId`, and `superviserTargetWorkflowId` (see
`examples/auto-improve/README.md` and `examples/default-superviser/EXPECTED_RESULTS.md`). Not
a standalone runnable demo without a supervised target and those variables.

### `default-supervisor-dispatcher` (demo index)

Cross-cutting **supervisor-dispatch** demo documented under
`examples/default-supervisor-dispatcher/`:

- supervisor workflow `riela-default-workflow-supervisor`
- resolver stub `dispatcher-llm-resolver-stub`
- managed catalog entry pointing at `worker-only-single-step`
- profile and binding under `examples/event-sources/.riela-events/`

See that directory's `README.md` for `events validate` / `events emit` examples.

### `riela-default-workflow-supervisor`

Minimal manager workflow bundle matching the design-default supervisor id. Used
by the dispatcher demo and validated like other reference workflows. Local
supervised lifecycle control is deterministic and in-process; this workflow id is
the supervisor identity, not a child `riela` process manager:

```bash
riela workflow validate riela-default-workflow-supervisor --workflow-definition-dir ./examples
```

### `dispatcher-llm-resolver-stub`

Single-worker bundle referenced as the LLM resolver target for
`webhook-supervisor-dispatch-demo`. Pair with mock scenarios under
`default-supervisor-dispatcher/`.

### `chat-reply-webhook`

Minimal worker-only workflow showing the built-in node add-on catalog:

- no authored `managerStepId`
- explicit `entryStepId: "reply-to-chat"`
- `steps[]` contains one worker step that targets a reusable node-registry entry
- no workflow-local worker implementation file is needed
- `nodes[].addon.name` selects `riela/chat-reply-worker`
- the node renders a reply from `runtimeVariables.event`
- when launched through `examples/event-sources`, the webhook source dispatches
  the reply to `RIELA_EXAMPLE_REPLY_ENDPOINT`

Validate it:

```bash
riela workflow validate chat-reply-webhook --workflow-definition-dir ./examples
```

Inspect it:

```bash
riela workflow inspect chat-reply-webhook --workflow-definition-dir ./examples --output json
```

See `examples/event-sources/README.md` for a local webhook event and reply
endpoint demo.

### `discord-codex-chat`

Discord chat workflow using the generic Chat SDK event boundary:

- receives normalized Discord messages from the `chat-sdk-discord` event source
- generates a reply with `codex-agent` model `gpt-5.4-mini`
- sends the generated text back through `riela/chat-reply-worker`
- dry-runs the reply when a direct local mock run has no chat target
- keeps the reply destination external through `chat-sdk-discord-replies`

Validate it:

```bash
riela workflow validate discord-codex-chat --workflow-definition-dir ./examples
```

Run it through the deterministic Discord event fixture:

```bash
riela events emit chat-sdk-discord \
  --workflow-definition-dir ./examples \
  --event-root ./examples/event-sources/.riela-events \
  --artifact-root ./tmp/event-source-demo/workflow-artifacts \
  --event-file ./examples/event-sources/payloads/chat-sdk-discord-message.json \
  --mock-scenario ./examples/discord-codex-chat/mock-scenario.json \
  --output json
```

### `chat-event-attachment-judgement`

Chat SDK attachment judgement workflow using deterministic image and PDF
descriptors:

- receives normalized Slack Chat SDK messages from the `chat-sdk-slack` event
  source
- preserves safe `event.input.attachments[]` descriptor fields for judgement
- uses one `codex-agent` worker to classify image/PDF evidence
- marks unsupported or evidence-free attachments for manual review
- avoids provider downloads, OCR, PDF parsing, and direct `@chat-adapter/*`
  dependencies

Validate it:

```bash
riela workflow validate chat-event-attachment-judgement --workflow-definition-dir ./examples
```

Run it through the deterministic attachment fixture:

```bash
riela events emit chat-sdk-slack \
  --workflow-definition-dir ./examples \
  --event-root ./examples/event-sources/.riela-events \
  --artifact-root ./tmp/event-source-demo/workflow-artifacts \
  --event-file ./examples/event-sources/payloads/chat-sdk-attachment-judgement-message.json \
  --mock-scenario ./examples/chat-event-attachment-judgement/mock-scenario.json \
  --output json
```

### `discord-agent-trio-chat`

Discord chat workflow for three named bot personas in one channel:

- Yui, Mika, and Rina persona nodes are shared through
  `shared-agent-trio-personas` and referenced with `workflow.nodes[].nodeRef`
- `Yui Codex` runs on `codex-agent` and is the default responder when no bot is named
- `Mika Trend` runs on `claude-code-agent` and covers entertainment, trends, and gyaru-style audience sense
- `Rina Cursor` runs on `cursor-cli-agent` and covers intellectual otaku and technical analysis
- persona icons are checked in under `assets/icons/`
- initial persona selection uses the provider-neutral `riela/chat-persona-router` add-on, so the workflow does not need a Discord-specific routing prompt
- a selected persona can set handoff flags such as `handoff_mika` when the user explicitly asks to hear another persona too
- each persona reads and writes only its own records in the
  `persona-chat-memory` SQLite database before and after replying. Set
  `workflowInput.memoryRoot` or `RIELA_MEMORY_ROOT` to choose the storage root
- Discord replies use `riela/chat-reply-worker` and dry-run when a direct local run has no chat target

Validate it:

```bash
riela workflow validate discord-agent-trio-chat --workflow-definition-dir ./examples
```

Run the bundled deterministic handoff scenario:

```bash
riela workflow run discord-agent-trio-chat \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/discord-agent-trio-chat/mock-scenario.json \
  --input '{"request":"Yui, give your opinion and ask Mika too"}'
```

### `telegram-agent-trio-chat`

Telegram Gateway persona workflow using riela-owned Telegram Bot API
ingestion:

- Yui, Mika, and Rina persona nodes are shared through
  `shared-agent-trio-personas` and referenced with `workflow.nodes[].nodeRef`
- receives normalized Telegram messages from the `telegram-gateway-personas`
  event source
- includes persisted bounded chat history in `event.input.history`
- preserves Telegram photo metadata in `event.input.attachments`
- routes replies as Yui, Mika, or Rina through the provider-neutral
  `riela/chat-persona-router` add-on with the same persona specs as the
  Discord trio
- each persona reads and writes only its own records in the
  `persona-chat-memory` SQLite database before and after replying. Set
  `workflowInput.memoryRoot` or `RIELA_MEMORY_ROOT` to choose the storage root
- sends replies through `riela/chat-reply-worker` and the
  `telegram-gateway-persona-replies` chat destination

Validate it:

```bash
riela workflow validate telegram-agent-trio-chat --workflow-definition-dir ./examples
```

Run the bundled deterministic handoff scenario:

```bash
riela workflow run telegram-agent-trio-chat \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/telegram-agent-trio-chat/mock-scenario.json \
  --input '{"request":"Yui, give your opinion and ask Mika too"}'
```

### `telegram-sdk-trio-chat`

Minimal Telegram trio chat workflow using the SDK-backed worker add-ons:

- routes normalized Telegram messages through node-level Telegram
  `inputFilters` evaluated with JavaScriptCore
- `Yui Codex SDK` uses `riela/codex-sdk-worker`
- `Mika Claude SDK` uses `riela/claude-sdk-worker`
- `Rina Cursor SDK` uses `riela/cursor-sdk-worker` with model `gpt-5.5`
- Mika and Rina reply only to explicit self mentions (`Mika`,
  `@mikatrend0529bot`, `Rina`, or `@rinacursor0529bot`)
- Yui replies to explicit Yui mentions and also acts as the default responder
  when no Mika/Rina mention is present
- accepted chat events are persisted through the native `riela/memory-save`
  add-on, and each persona loads recent workflow-scoped `chat-memory` records
  through `riela/memory-load` before replying
- replies use `riela/chat-reply-worker` and dry-run when a local run has no
  Telegram chat target
- the deterministic mock scenario passes Telegram event variables that activate
  Rina's explicit-mention input filter and reply path without requiring live SDK
  API keys by rendering each SDK worker's
  `mockResponseTemplate`

Validate it:

```bash
riela workflow validate telegram-sdk-trio-chat --workflow-definition-dir ./examples
```

Run the bundled deterministic Rina scenario:

```bash
riela workflow run telegram-sdk-trio-chat \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/telegram-sdk-trio-chat/mock-scenario.json \
  --variables '{"workflowInput":{"text":"@rinacursor0529bot explain the SDK trio setup","provider":"telegram"},"event":{"sourceId":"telegram-live","eventId":"mock-1","provider":"telegram","eventType":"chat.message","input":{"text":"@rinacursor0529bot explain the SDK trio setup","provider":"telegram","attachments":[],"imagePaths":[],"attachmentText":""},"conversation":{"id":"100","threadId":"topic-a"},"actor":{"id":"200","displayName":"Mock User"}}}'
```

### `gemini-sdk-worker`

Single-step workflow using the Gemini SDK worker add-on:

- `ask-gemini` uses `riela/gemini-sdk-worker`
- the worker resolves to `official/gemini-sdk`
- live execution requires `addon.env.GEMINI_API_KEY` or
  `addon.env.GOOGLE_API_KEY` to map from a runtime Gemini API key

Validate it:

```bash
riela workflow validate gemini-sdk-worker --workflow-definition-dir ./examples
```

### `gemini-ocr-worker`

Single-step OCR workflow using the Gemini SDK worker add-on:

- `ocr-image` uses `riela/gemini-sdk-worker`
- the worker resolves to `official/gemini-sdk`
- the request includes a small inline JPEG image with visible text
  `OCR SAMPLE 42`
- live execution requires `addon.env.GEMINI_API_KEY` or
  `addon.env.GOOGLE_API_KEY` to map from a runtime Gemini API key

Validate it:

```bash
riela workflow validate gemini-ocr-worker --workflow-definition-dir ./examples
```

Run it live when `GEMINI_API_KEY` is available:

```bash
riela workflow run gemini-ocr-worker --workflow-definition-dir ./examples --output json
```

### `telegram-agent-trio-time-signal`

Scheduled Telegram reply companion for the Telegram trio chat:

- receives `cron.tick` events from `telegram-time-signal-cron`
- uses a six-field cron schedule, `*/30 * * * * *`, to evaluate every 30
  seconds
- uses the built-in `riela/time-signal` add-on to announce only when the
  scheduled Asia/Tokyo local time is on a five-minute boundary
- reuses `telegram-gateway-persona-replies` so delivery stays on the Telegram
  Gateway reply path

Validate it:

```bash
riela workflow validate telegram-agent-trio-time-signal --workflow-definition-dir ./examples
```

Run the deterministic event fixture with stubbed or live Telegram credentials:

```bash
riela events emit telegram-time-signal-cron \
  --workflow-definition-dir ./examples \
  --event-root ./examples/event-sources/.riela-events \
  --event-file ./examples/event-sources/payloads/telegram-time-signal-cron.json \
  --output json
```
