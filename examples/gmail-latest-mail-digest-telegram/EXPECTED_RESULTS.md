# Expected Results

- The workflow validates as a step-addressed scheduled Gmail digest bundle.
- The built-in `riela/gmail-digest` add-on owns state reads, mail normalization, attachment inspection, LLM output validation, cursor persistence, and no-mail output.
- `read-mail-state` reads `.riela-data/gmail-latest-mail-digest-telegram/state.json` by default and emits a max-10 Gmail fetch request.
- `fetch-latest-gmail` runs `riela/mail-gateway-read` in Docker with `ghcr.io/tacogips/mail-gateway:latest`, invokes the read-only `mail-gateway-reader` surface through `threads(input:)`, and maps Gmail mail-gateway credentials from `GMAIL_MAIL_GATEWAY_CONFIG` only.
- `fetch-latest-gmail` requests live message metadata plus `textBody`/`htmlBody` and attachment metadata. It does not request raw attachment file payloads in GraphQL.
- `normalize-new-mail` treats the gateway result as untrusted data, accepts the current `threads.edges.node.messages` shape, keeps only fetched Gmail messages whose ids are not in the persisted state, and lets a first run notify about the latest 10 messages. When body payloads are present, it writes them under `.riela-data/gmail-latest-mail-digest-telegram/messages/` and passes only file metadata downstream.
- `inspect-attachments` downloads selected attachments through the Gmail digest add-on's gateway boundary, previews text-compatible files, and runs Gemini OCR/classification for PDF attachments when `GOOGLE_API_KEY` or `GEMINI_API_KEY` is available. It returns compact attachment analyses only, not local paths, download keys, or raw file payloads.
- `summarize-new-mail` is a separate LLM worker node that summarizes only `selectedMessages` and compact `attachmentAnalyses`, uses subject/snippet metadata by default, and ignores instructions embedded in email content. It must not expand `downloadKey` file payloads into the JSON response.
- `validate-summary-output` drops any LLM message id that is not one of the normalized selected message ids and rebuilds Telegram text from validated records.
- `persist-mail-state` stores fetched message ids before Telegram delivery and only routes to Telegram when `when.should_send_telegram` is true.
- The state file stores message ids and metadata only. Raw fetched email content can appear in workflow artifacts, so live runs should use an ignored artifact root such as `.riela-artifact/gmail-latest-mail-digest-telegram`.
- The event binding disables automatic final/error replies; Telegram output should come only from the explicit `send-telegram-digest` chat-reply step.

Validation commands:

```bash
riela workflow validate gmail-latest-mail-digest-telegram --workflow-definition-dir ./examples
riela events validate --workflow-definition-dir ./examples --event-root ./examples/event-sources/.riela-events
```
