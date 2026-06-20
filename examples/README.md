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

- `Yui Codex` runs on `codex-agent` and is the default responder when no bot is named
- `Mika Trend` runs on `claude-code-agent` and covers entertainment, trends, and gyaru-style audience sense
- `Rina Cursor` runs on `cursor-cli-agent` and covers intellectual otaku and technical analysis
- persona icons are checked in under `assets/icons/`
- initial persona selection uses the provider-neutral `riela/chat-persona-router` add-on, so the workflow does not need a Discord-specific routing prompt
- a selected persona can set handoff flags such as `handoff_mika` when the user explicitly asks to hear another persona too
- each persona reads and writes only its own local markdown memory before and
  after replying. Set `workflowInput.memoryRoot` or `RIELA_TRIO_MEMORY_ROOT` to
  choose the storage root; examples default to `/tmp/riflow-tribot`
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

- receives normalized Telegram messages from the `telegram-gateway-personas`
  event source
- includes persisted bounded chat history in `event.input.history`
- preserves Telegram photo metadata in `event.input.attachments`
- routes replies as Yui, Mika, or Rina through the provider-neutral
  `riela/chat-persona-router` add-on with the same persona specs as the
  Discord trio
- each persona reads and writes only its own local markdown memory before and
  after replying. Set `workflowInput.memoryRoot` or `RIELA_TRIO_MEMORY_ROOT` to
  choose the storage root; examples default to `/tmp/riflow-tribot`
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

- routes normalized Telegram messages through `riela/chat-persona-router`
- `Yui Codex SDK` uses `riela/codex-sdk-worker`
- `Mika Claude SDK` uses `riela/claude-sdk-worker`
- `Rina Cursor SDK` uses `riela/cursor-sdk-worker` with model `gpt-5.5`
- replies use `riela/chat-reply-worker` and dry-run when a local run has no
  Telegram chat target
- the deterministic mock scenario exercises the routing and reply path without
  requiring live SDK API keys

Validate it:

```bash
riela workflow validate telegram-sdk-trio-chat --workflow-definition-dir ./examples
```

Run the bundled deterministic Rina scenario:

```bash
riela workflow run telegram-sdk-trio-chat \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/telegram-sdk-trio-chat/mock-scenario.json \
  --input '{"request":"Rina, explain the SDK trio setup"}'
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
- sends a Yui time-signal reply only when the scheduled Asia/Tokyo local time
  is on a five-minute boundary
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

### `x-follower-ai-business-digest`

Hourly X follower-post digest for Telegram:

- receives `cron.tick` events from `x-follower-ai-business-hourly-cron`
- reads `.riela-data/x-follower-ai-business-digest/state.json` by default
  and keeps the saved post id for dedupe/accounting
- runs `riela/x-gateway-read` in Docker with
  `ghcr.io/tacogips/x-gateway:latest`
- queries the stable x-gateway `followingTimeline` field for followed-account posts
- maps X credentials from environment variables only; do not put token values
  in workflow files
- uses a Codex worker prompt that treats fetched posts as untrusted data and
  proposes event/topic digests rather than per-user post summaries, then a
  deterministic validation step drops any source id that is not one of the
  normalized selected posts and rebuilds Telegram text from validated
  post/user links and metrics
- reports each topic with aggregate views, posting-user count, and up to three
  linked posting users so the digest explains what happened before who posted it
- posts through the existing `telegram-gateway-persona-replies` destination
  only when the digest is non-empty
- disables automatic event final/error replies so workflow failures are not
  posted to Telegram
- never writes fetched post bodies to the workflow bundle; the cursor file keeps
  only the newest post id and must live under an ignored/private runtime path
  such as `.riela-data/`
- raw fetched posts can still appear in riela runtime artifacts, so live runs
  must use an ignored artifact root such as
  `.riela-artifact/x-follower-ai-business-digest`

Required live-run environment variables:

```bash
export X_GW_ACCOUNT_USERNAME=@yu_kawa_taco
export X_GW_AUTH_MODE=oauth1
export X_GW_ACCESS_TOKEN=<x-access-token>
export X_GW_ACCESS_TOKEN_SECRET=<x-access-token-secret>
export X_GW_CONSUMER_KEY=<x-consumer-key>
export X_GW_CONSUMER_SECRET=<x-consumer-secret>
export RIELA_TELEGRAM_CHAT_ID=<telegram-chat-id>
```

Validate it:

```bash
riela workflow validate x-follower-ai-business-digest --workflow-definition-dir ./examples
```

Run the deterministic cron fixture:

```bash
riela events emit x-follower-ai-business-hourly-cron \
  --workflow-definition-dir ./examples \
  --event-root ./examples/event-sources/.riela-events \
  --artifact-root ./.riela-artifact/x-follower-ai-business-digest \
  --event-file ./examples/event-sources/payloads/x-follower-ai-business-hourly-cron.json \
  --output json
```

### `gmail-latest-mail-digest-telegram`

Scheduled Gmail digest for Telegram:

- receives `cron.tick` events from `gmail-latest-mail-hourly-cron`
- reads `.riela-data/gmail-latest-mail-digest-telegram/state.json` by default
  and keeps fetched Gmail message ids for first-time-seen dedupe
- runs `riela/mail-gateway-read` in Docker with
  `ghcr.io/tacogips/mail-gateway:latest`
- uses the read-only `mail-gateway-reader` client through the built-in add-on
  to fetch the latest 10 Gmail messages for `accountId: "gmail"`
- requests vendor-neutral file metadata and `downloadKey` values instead of
  raw body or file payloads, so large mail content is downloaded only through a
  later gateway command when needed
- downloads selected attachments out-of-band in `inspect-attachments`, previews
  text-compatible files, and uses Gemini OCR/classification for PDF attachments
  when `GOOGLE_API_KEY` or `GEMINI_API_KEY` is available
- maps Gmail mail-gateway credentials from `GMAIL_MAIL_GATEWAY_CONFIG` only;
  do not put credential values in workflow files
- summarizes only newly seen messages in a separate Codex worker prompt that
  treats email metadata, attachment OCR text, and file references as untrusted
  data
- validates LLM-selected message ids against the normalized selected messages
  before rebuilding Telegram text
- persists fetched message ids before Telegram delivery so the first run can
  notify about the latest 10 messages and later runs notify only about messages
  first seen in that run
- posts through the existing `telegram-gateway-persona-replies` destination
  only when a non-empty digest exists
- disables automatic event final/error replies so Telegram output comes only
  from the explicit `send-telegram-digest` chat-reply step
- never writes email bodies to the workflow bundle; GraphQL file payloads should
  not enter riela runtime artifacts, and any legacy body fallback is materialized
  under `.riela-data/gmail-latest-mail-digest-telegram/messages/`

Required live-run environment variables:

```bash
export GMAIL_MAIL_GATEWAY_CONFIG=<mail-gateway-gmail-config-json-or-path>
export RIELA_TELEGRAM_CHAT_ID=<telegram-chat-id>
```

Optional for PDF attachment OCR:

```bash
export GEMINI_API_KEY=<gemini-api-key-for-pdf-ocr>
```

Validate it:

```bash
riela workflow validate gmail-latest-mail-digest-telegram --workflow-definition-dir ./examples
```

Run the deterministic cron fixture:

```bash
riela events emit gmail-latest-mail-hourly-cron \
  --workflow-definition-dir ./examples \
  --event-root ./examples/event-sources/.riela-events \
  --artifact-root ./.riela-artifact/gmail-latest-mail-digest-telegram \
  --event-file ./examples/event-sources/payloads/gmail-latest-mail-hourly-cron.json \
  --output json
```

### `matrix-agent-trio-chat`

Matrix persona workflow using the same provider-neutral trio authoring shape as
the Discord and Telegram examples:

- receives normalized Matrix `m.room.message` events from the `team-matrix`
  event source
- routes replies as Yui, Mika, or Rina through `riela/chat-persona-router`
- can select separate Matrix access tokens with `replyAsTemplate` and
  `team-matrix.replyBots`
- each persona reads and writes only its own local markdown memory before and
  after replying. Set `workflowInput.memoryRoot` or `RIELA_TRIO_MEMORY_ROOT` to
  choose the storage root; examples default to `/tmp/riflow-tribot`
- sends replies through `riela/chat-reply-worker` and the
  `matrix-persona-replies` chat destination

Validate it:

```bash
riela workflow validate matrix-agent-trio-chat --workflow-definition-dir ./examples
```

Run the bundled deterministic handoff scenario:

```bash
riela workflow run matrix-agent-trio-chat \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/matrix-agent-trio-chat/mock-scenario.json \
  --input '{"request":"Yui, give your opinion and ask Mika too"}'
```

### `discord-persona-chat`

Discord Gateway persona workflow using riela-owned Gateway ingestion:

- receives normalized Discord Gateway `MESSAGE_CREATE` events from the
  `discord-gateway-personas` event source
- includes bounded channel or thread history in `event.input.history`
- routes replies as Yui, Mika, or Rina with `codex-agent` model `gpt-5.4-mini`
- sends replies through `riela/chat-reply-worker` and the
  `discord-gateway-persona-replies` chat destination

Validate it:

```bash
riela workflow validate discord-persona-chat --workflow-definition-dir ./examples
```

Run it through the deterministic Discord Gateway fixture without contacting
Discord:

```bash
riela events emit discord-gateway-personas \
  --workflow-definition-dir ./examples \
  --event-root ./examples/event-sources/.riela-events \
  --artifact-root ./tmp/event-source-demo/workflow-artifacts \
  --event-file ./examples/event-sources/payloads/discord-gateway-message-with-history.json \
  --read-only \
  --output json
```

### `matrix-chat-reply`

Element/Matrix worker-only workflow showing the same built-in reply add-on
through a real Matrix receive/send path:

- receives text-like Matrix `m.room.message` events from the `matrix` event
  source
- renders a reply from `runtimeVariables.event`
- sends the reply back to the configured Matrix room through a chat destination
- includes a Docker Compose Synapse harness under `local-synapse/`

Validate it:

```bash
riela workflow validate matrix-chat-reply --workflow-definition-dir ./examples
```

Run the local Matrix verification:

```bash
./examples/matrix-chat-reply/local-synapse/run-local-matrix-sample.sh
```

### `chat-supervisor-collaboration`

Chat-triggered supervisor collaboration reference:

- event binding emits natural chat lifecycle replies: received, plan or clarification, then starting
- Workflow A and Workflow B brainstorm as separate personas
- Workflow C turns their outputs into a specification and requests review through chat destinations
- external event/output destinations stay separate from internal workflow mail

Validate the workflow and event binding:

```bash
riela workflow validate chat-supervisor-collaboration --workflow-definition-dir ./examples
riela events validate \
  --workflow-definition-dir ./examples \
  --event-root ./examples/chat-supervisor-collaboration/.riela-events
```

Run the deterministic workflow scenario:

```bash
riela workflow run chat-supervisor-collaboration \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/chat-supervisor-collaboration/mock-scenario.json \
  --output json
```

### `workflow-call-simple`

Managed parent workflow reference for cross-workflow invocation in the
step-addressed authored shape:

- `riela-manager` stays on `claude-code-agent`
- `draft-write` and `apply-review` stay on `codex-agent`
- explicit `managerStepId: "riela-manager"` and `entryStepId:
"riela-manager"` define the parent entry
- `steps[]` carries the authored manager-to-draft progression directly
- `draft-write` declares a cross-workflow transition targeting
  `workflow-call-review-target` (`toStepId: "reviewer"`) with
  `resumeStepId: "apply-review"`
- the engine executes that transition using the deterministic runtime workflow-call id
  `__cw:draft-write`; session communications use
  `transitionWhen = "workflow-call:__cw:draft-write"`
- the bundled deterministic mock scenario covers both the parent and callee
  node ids so the full call chain can be run from one command

Validate it:

```bash
riela workflow validate workflow-call-simple --workflow-definition-dir ./examples
```

Inspect it:

```bash
riela workflow inspect workflow-call-simple --workflow-definition-dir ./examples --output json
```

Run it with the bundled deterministic scenario:

```bash
riela workflow run workflow-call-simple \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/workflow-call-simple/mock-scenario.json \
  --output json
```

### `workflow-call-review-target`

Worker-only callee bundle used by `workflow-call-simple`:

- no authored `managerStepId`
- explicit `entryStepId: "reviewer"`
- returns its latest succeeded worker result to the caller workflow-call
  contract
- can also be validated, inspected, and run standalone

Validate it:

```bash
riela workflow validate workflow-call-review-target --workflow-definition-dir ./examples
```

Inspect it:

```bash
riela workflow inspect workflow-call-review-target --workflow-definition-dir ./examples --output json
```

Run it standalone with the bundled deterministic scenario:

```bash
riela workflow run workflow-call-review-target \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/workflow-call-review-target/mock-scenario.json \
  --output json
```

### `design-and-implement-review-loop`

Real development workflow sample adapted from the project-local workflow catalog:

- starts with issue intake and design-document update
- can call `design-and-implement-review-loop-feature-plan` for bounded
  feature-plan fanout
- runs self-review and independent review gates before implementation
- creates and reviews an implementation plan before coding
- delegates implementation to `codex-agent`
- refreshes documentation, prepares a commit message, then uses the built-in
  `riela/git-commit` and `riela/git-push` add-ons
- includes deterministic mock scenarios for full issue resolution and
  planning-only execution

Validate it:

```bash
riela workflow validate design-and-implement-review-loop --workflow-definition-dir ./examples
```

Run the full deterministic scenario:

```bash
riela workflow run design-and-implement-review-loop \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/design-and-implement-review-loop/mock-scenario.json \
  --output json
```

Live execution note:

- this workflow can create commits and push them when run with live backends;
  use the bundled mock scenarios for deterministic sample verification

### `design-and-implement-review-loop-feature-plan`

Worker-only companion workflow used by the bounded fanout path in
`design-and-implement-review-loop`:

- no authored manager step
- starts at `step2-design-doc-update`
- loops through design self-review, independent design review, implementation
  plan creation, plan self-review, and independent plan review
- returns a feature-local design and implementation-plan result to the caller

Validate it:

```bash
riela workflow validate design-and-implement-review-loop-feature-plan --workflow-definition-dir ./examples
```

### `recent-change-quality-loop`

Real development workflow sample for reviewing recent repository changes:

- reviews committed changes from a configurable recent time window plus
  uncommitted changes
- routes through an exit gate that detects high or mid severity findings
- delegates blocking findings to `design-and-implement-review-loop` through a
  cross-workflow transition
- resumes after the delegated fix, then re-runs review until no blocking
  finding remains

Validate it:

```bash
riela workflow validate recent-change-quality-loop --workflow-definition-dir ./examples
```

Run it with the bundled deterministic scenario:

```bash
riela workflow run recent-change-quality-loop \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/recent-change-quality-loop/mock-scenario.json \
  --output json
```

Live execution note:

- because this workflow delegates to `design-and-implement-review-loop`, live
  execution can also create commits and push them through that delegated
  workflow

### `subworkflow-chained-simple`

Minimal runnable reference for two sequential grouped lanes in the
step-addressed authored shape. The directory name is historical; this is not
the structural sub-workflow compatibility reference.

- explicit `managerStepId: "riela-manager"` and `entryStepId: "riela-manager"`
- `steps[]` carries the alpha-to-beta execution order directly
- grouped lane payloads live under `workflows/alpha/` and `workflows/beta/`

Validate it:

```bash
riela workflow validate subworkflow-chained-simple --workflow-definition-dir ./examples
```

Inspect it:

```bash
riela workflow inspect subworkflow-chained-simple --workflow-definition-dir ./examples --output json
```

Run it with the bundled deterministic scenario:

```bash
riela workflow run subworkflow-chained-simple \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/subworkflow-chained-simple/mock-scenario.json \
  --output json
```

### `claude-riela-codex-coding`

Recommended mixed-backend reference:

- explicit `managerStepId: "riela-manager"` and `entryStepId: "riela-manager"`
- `steps[]` expresses the execution order directly while `nodes[]` stays a reusable registry
- `riela` manager nodes use `claude-code-agent`
- implementation planning/finalization stays on `claude-code`
- the actual coding node uses `codex-agent`
- the workflow-level `rielaPromptTemplate` explicitly prefers `riela graphql`
- node prompt templates can read resolved upstream workflow message data through
  `{{inbox.*}}`
- long node prompts live in `prompts/*.md` and are referenced by
  `node-{id}.json.promptTemplateFile`

Validate it:

```bash
riela workflow validate claude-riela-codex-coding --workflow-definition-dir ./examples
```

Inspect it:

```bash
riela workflow inspect claude-riela-codex-coding --workflow-definition-dir ./examples --output json
```

Run it with the bundled deterministic scenario:

```bash
riela workflow run claude-riela-codex-coding \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/claude-riela-codex-coding/mock-scenario.json \
  --output json
```

### `node-combinations-showcase`

Validation-oriented reference bundle in the step-addressed authored shape:

- `managerStepId` / `entryStepId` plus explicit `steps[]` transitions (the
  foreach lane uses two labeled transitions from the judge step:
  `continue_items` back to `foreach-manager` and `!(continue_items)` forward to
  `foreach-output`, matching the former repeat-edge semantics)
- one task uses `nodeType: "command"`
- one task uses `nodeType: "container"`
- workflow-relative support assets are included for the command script and
  container build context
- node payload files live under `nodes/`

Execution notes:

- live `workflow run` can execute the authored `command` and `container` nodes
  when the local runtime prerequisites are available
- inspect or validate the workflow first to confirm runner readiness in the
  current environment before relying on a live run
- the bundled deterministic mock scenario remains the stable demo path when you
  want reproducible results without depending on local shell or container
  tooling

Validate it:

```bash
riela workflow validate node-combinations-showcase --workflow-definition-dir ./examples
```

Inspect it:

```bash
riela workflow inspect node-combinations-showcase --workflow-definition-dir ./examples --output json
```

Run it with the bundled deterministic scenario:

```bash
riela workflow run node-combinations-showcase \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/node-combinations-showcase/mock-scenario.json \
  --output json
```

### `scheduled-sleep`

Minimal scheduled continuation workflow:

- `wait` uses `nodeType: "sleep"` with `sleep.durationMs`
- the runtime records a pending `workflow-sleep` scheduled event and returns
  while the workflow session is paused
- when the shared scheduled event manager fires the event, the session resumes
  and runs `worker`
- cancellation only applies to pending scheduled events, so firing, fired,
  failed, and already-cancelled event states remain visible for inspection

Run it with the bundled deterministic scenario:

```bash
riela workflow run scheduled-sleep \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/scheduled-sleep/mock-scenario.json \
  --output json
```

### `first-four-arithmetic-pipeline`

Validation-oriented arithmetic pipeline reference:

- explicit `managerStepId: "riela-manager"` and `entryStepId: "riela-manager"`
- `steps[]` carries the add, multiply, and divide stages directly
- accepts a human input string containing at least four space-separated numbers
- uses only the first four numbers from that input
- stage 1 uses an `agent` worker to add the first two numbers
- stage 2 uses a `container` worker configured for `podman` to multiply the
  stage 1 result by the third number
- stage 3 uses a `command` worker to divide the stage 2 result by the fourth
  number
- managers treat each stage as an opaque grouped lane and only move scoped
  payloads forward
- stage payloads live under `workflows/add`, `workflows/multiply`, and
  `workflows/divide`
- those nested stage payloads reuse the parent-level `prompts/stage-manager.md`,
  which demonstrates workflow-local asset
  reuse across nested directories

Execution notes:

- live `workflow run` can execute the authored `command` and `container`
  workers when the required local shell and container runner tooling is
  available
- inspect or validate the workflow first to confirm runner readiness in the
  current environment before relying on a live run
- the bundled deterministic mock scenario remains the stable verification path
  when you want reproducible arithmetic results without depending on local
  toolchain availability

Validate it:

```bash
riela workflow validate first-four-arithmetic-pipeline --workflow-definition-dir ./examples
```

Inspect it:

```bash
riela workflow inspect first-four-arithmetic-pipeline --workflow-definition-dir ./examples --output json
```

Run it with the bundled deterministic scenario:

```bash
riela workflow run first-four-arithmetic-pipeline \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/first-four-arithmetic-pipeline/mock-scenario.json \
  --output json
```

### `claude-riela-claude-worker`

Reference workflow for the case where a regular task node also uses
`claude-code-agent`:

- explicit `managerStepId: "riela-manager"` and `entryStepId: "riela-manager"`
- `steps[]` expresses the manager-to-worker handoff directly while `nodes[]` stays reusable
- `riela` manager nodes use `claude-code-agent`
- the task node `claude-task` also uses `claude-code-agent`
- the bundle includes a deterministic mock scenario for validate/run demos

Validate it:

```bash
riela workflow validate claude-riela-claude-worker --workflow-definition-dir ./examples
```

Inspect it:

```bash
riela workflow inspect claude-riela-claude-worker --workflow-definition-dir ./examples --output json
```

Run it with the bundled deterministic scenario:

```bash
riela workflow run claude-riela-claude-worker \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/claude-riela-claude-worker/mock-scenario.json \
  --output json
```

### `same-node-session-echo`

Reference workflow for the case where one worker node should run twice:

- explicit `managerStepId: "riela-manager"` and `entryStepId: "riela-manager"`
- `steps[]` revisits the shared node-registry entry `echo-session` through
  two distinct steps: `echo-request` and `answer-request`
- `nodes/node-echo-session.json` opts into `sessionPolicy.mode = "reuse"`
- the `answer-request` step explicitly inherits that reusable backend session
  from `echo-request`
- the `answer-request` step also switches to the `answer` prompt variant for
  the second visit
- the first visit echoes the normalized request
- the second visit answers using that earlier echo
- the prompt also reads resolved upstream data through
  `{{inbox.latest.output.echoText}}` so the earlier echo is
  available explicitly in workflow data, not only via backend memory

Validate it:

```bash
riela workflow validate same-node-session-echo --workflow-definition-dir ./examples
```

Inspect it:

```bash
riela workflow inspect same-node-session-echo --workflow-definition-dir ./examples --output json
```

Run it with the bundled deterministic scenario:

```bash
riela workflow run same-node-session-echo \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/same-node-session-echo/mock-scenario.json \
  --output json
```

Live execution note:

- the bundled mock scenario demonstrates the repeated same-node control flow
- actual backend session continuation still depends on the configured
  `claude-code-agent` or `codex-agent` backend returning a reusable session id

### `codex-codex-topic-debate`

Live-agent topic debate bundle for runtime-provided debate prompts. This is the
canonical debate example and replaces the older hard-coded topic variant:

- two `codex-agent` speaker lanes use `gpt-5.3-codex-spark`
- the topic comes from `runtimeVariables.humanInput.request`
- the speaker lanes remain grouped under `workflows/*/nodes/`
- speaker nodes bind `arguments.topic` from the normalized input step
- speakers use node-local `systemPromptTemplateFile` and
  `sessionStartPromptTemplateFile` prompt assets
- output contracts force debate handoff payloads into structured JSON
- `debate-judge` returns business JSON with `continue_debate`; branch routing
  falls back to payload booleans when no adapter `when` flag is present

Validate it:

```bash
riela workflow validate codex-codex-topic-debate --workflow-definition-dir ./examples
```

Run it with live backend execution:

```bash
riela workflow run codex-codex-topic-debate \
  --workflow-definition-dir ./examples \
  --variables '{"humanInput":{"request":"Debate immigration policy. The affirmative side should argue for more open immigration with managed legal pathways, and the negative side should argue for stricter border and asylum controls."}}' \
  --output json
```

Live execution note:

- this bundle depends on the configured `codex-agent` backend honoring the remote request body fields sent by this repository, including `systemPromptText`
