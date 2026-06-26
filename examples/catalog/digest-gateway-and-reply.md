# Examples: Digest, Gateway, and Reply Examples

### `x-follower-ai-business-digest`

Hourly X follower-post digest for Telegram:

- receives `cron.tick` events from `x-follower-ai-business-hourly-cron`
- uses the built-in `riela/x-digest` add-on to read
  `.riela-data/x-follower-ai-business-digest/state.json` by default and keep
  the saved post id for dedupe/accounting
- runs `riela/x-gateway-read` in Docker with
  `ghcr.io/tacogips/x-gateway:latest`
- queries the stable x-gateway `followingTimeline` field for followed-account posts
- maps X credentials from environment variables only; do not put token values
  in workflow files
- uses a Codex worker prompt that treats fetched posts as untrusted data and
  proposes event/topic digests rather than per-user post summaries, then a
  deterministic `riela/x-digest` validation step drops any source id that is not one of the
  normalized selected posts and rebuilds Telegram text from validated
  post/user links and metrics
- reports each topic with aggregate views, posting-user count, and up to three
  linked posting users so the digest explains what happened before who posted it
- posts through the existing `telegram-gateway-persona-replies` destination
  only when the digest is non-empty
- disables automatic event final/error replies so workflow failures are not
  posted to Telegram
- never writes fetched post bodies to the workflow bundle; `riela/x-digest`
  persists only the newest post id and requires the cursor file to live under
  an ignored/private runtime path such as `.riela-data/`
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
  to fetch Gmail thread edges for `accountId: "gmail"` through the stable
  `threads(input:)` GraphQL field
- requests message metadata plus `textBody`/`htmlBody` from the live Gmail read
  surface; the digest add-on materializes body text under the ignored
  `.riela-data/gmail-latest-mail-digest-telegram/messages/` runtime directory
- treats attachment records as metadata unless they include a gateway
  `downloadKey` or local path, so large file payloads are downloaded only
  through a later `riela/gmail-digest` add-on operation when available
- uses the built-in `riela/gmail-digest` add-on for deterministic state reads,
  mail normalization, attachment inspection, LLM output validation, cursor
  persistence, and no-mail output
- downloads selected attachments out-of-band in `inspect-attachments` through
  the add-on's gateway boundary, previews text-compatible files, and uses
  Gemini OCR/classification for PDF attachments when `GOOGLE_API_KEY` or
  `GEMINI_API_KEY` is available
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
- never writes email bodies to the workflow bundle; body fallback files are
  materialized under `.riela-data/gmail-latest-mail-digest-telegram/messages/`

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

- Yui, Mika, and Rina persona nodes are shared through
  `shared-agent-trio-personas` and referenced with `workflow.nodes[].nodeRef`
- receives normalized Matrix `m.room.message` events from the `team-matrix`
  event source
- routes replies as Yui, Mika, or Rina through `riela/chat-persona-router`
- can select separate Matrix access tokens with `replyAsTemplate` and
  `team-matrix.replyBots`
- each persona reads and writes only its own records in the
  `persona-chat-memory` SQLite database before and after replying. Set
  `workflowInput.memoryRoot` or `RIELA_MEMORY_ROOT` to choose the storage root
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

### `shared-agent-trio-personas`

Shared persona node workflow for the provider-neutral trio chat examples:

- owns the single source of truth for `Yui Codex`, `Mika Trend`, and
  `Rina Cursor` node payloads and prompts
- is referenced by `telegram-agent-trio-chat`, `discord-agent-trio-chat`, and
  `matrix-agent-trio-chat` through `workflow.nodes[].nodeRef`
- declares the inherited `persona-chat-memory` contract as cross-workflow
  memory so vendor workflows can keep using shared persona memory behavior

Validate it:

```bash
riela workflow validate shared-agent-trio-personas --workflow-definition-dir ./examples
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

### `slack-codex-chat`

Slack Gateway worker-only workflow using riela-owned Slack Web API ingestion:

- receives normalized Slack `chat.message` events from the
  `slack-gateway-codex` event source
- includes bounded persisted Slack thread history in `event.input.payload.history`
- answers with `codex-agent` model `gpt-5.4-mini`
- sends replies through `riela/chat-reply-worker` and the
  `slack-gateway-codex-replies` chat destination
- replies in the same Slack thread timestamp carried by the normalized event

Validate it:

```bash
riela workflow validate slack-codex-chat --workflow-definition-dir ./examples
```

Run it through the deterministic Slack Gateway fixture without contacting
Slack:

```bash
riela events emit slack-gateway-codex \
  --workflow-definition-dir ./examples \
  --event-root ./examples/event-sources/.riela-events \
  --artifact-root ./tmp/event-source-demo/workflow-artifacts \
  --event-file ./examples/event-sources/payloads/slack-gateway-message-with-history.json \
  --mock-scenario ./examples/slack-codex-chat/mock-scenario.json \
  --output json
```

### `slack-agent-trio-chat`

Slack Gateway persona workflow using riela-owned Slack Web API ingestion:

- receives normalized Slack `chat.message` events from the
  `slack-gateway-personas` event source
- includes bounded persisted Slack thread history in `event.input.payload.history`
- lets Yui, Mika, and Rina hand off the discussion through the same persona
  memory pattern as the Discord and Telegram trio examples
- sends persona replies through `riela/chat-reply-worker` and the
  `slack-gateway-persona-replies` chat destination
- selects separate Slack bot tokens from `RIELA_SLACK_YUI_BOT_TOKEN`,
  `RIELA_SLACK_MIKA_BOT_TOKEN`, and `RIELA_SLACK_RINA_BOT_TOKEN` so the Slack
  UI can show distinct Yui, Mika, and Rina bot identities while preserving each
  logical `replyAs` identity in workflow output and chat history

Validate it:

```bash
riela workflow validate slack-agent-trio-chat --workflow-definition-dir ./examples
```

Run it through the deterministic Slack Gateway fixture without contacting
Slack:

```bash
riela events emit slack-gateway-personas \
  --workflow-definition-dir ./examples \
  --event-root ./examples/event-sources/.riela-events \
  --artifact-root ./tmp/event-source-demo/workflow-artifacts \
  --event-file ./examples/event-sources/payloads/slack-gateway-persona-message-with-history.json \
  --mock-scenario ./examples/slack-agent-trio-chat/mock-scenario.json \
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
