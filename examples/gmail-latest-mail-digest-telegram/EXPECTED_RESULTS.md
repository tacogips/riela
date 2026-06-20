# Expected Results

- The workflow validates as a step-addressed scheduled Gmail digest bundle.
- `read-mail-state` reads `.riela-data/gmail-latest-mail-digest-telegram/state.json` by default and emits a max-10 Gmail fetch request.
- `fetch-latest-gmail` runs `riela/mail-gateway-read` in Docker with `ghcr.io/tacogips/mail-gateway:latest`, invokes the read-only `mail-gateway-reader` surface, and maps Gmail mail-gateway credentials from `GMAIL_MAIL_GATEWAY_CONFIG` only.
- `fetch-latest-gmail` does not request raw `textBody`, `htmlBody`, or file payloads in GraphQL; it requests vendor-neutral file metadata plus `downloadKey` values for later out-of-band download.
- `normalize-new-mail` treats the gateway result as untrusted data, keeps only fetched Gmail messages whose ids are not in the persisted state, and lets a first run notify about the latest 10 messages. If legacy gateway output includes body payloads, it writes them under `.riela-data/gmail-latest-mail-digest-telegram/messages/` and passes only file metadata downstream.
- `summarize-new-mail` is a separate LLM worker node that summarizes only `selectedMessages`, uses subject/snippet metadata by default, and ignores instructions embedded in email content. It must not expand `downloadKey` file payloads into the JSON response.
- `validate-summary-output` drops any LLM message id that is not one of the normalized selected message ids and rebuilds Telegram text from validated records.
- `persist-mail-state` stores fetched message ids before Telegram delivery and only routes to Telegram when `when.should_send_telegram` is true.
- The state file stores message ids and metadata only. Raw fetched email content can appear in workflow artifacts, so live runs should use an ignored artifact root such as `.riela-artifact/gmail-latest-mail-digest-telegram`.
- The event binding disables automatic final/error replies; Telegram output should come only from the explicit `send-telegram-digest` chat-reply step.

Validation commands:

```bash
riela workflow validate gmail-latest-mail-digest-telegram --workflow-definition-dir ./examples
riela events validate --workflow-definition-dir ./examples --event-root ./examples/event-sources/.riela-events
```
