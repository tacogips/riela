# Expected Results

- The workflow validates as a step-addressed worker-only bundle.
- The `answer-slack-message` step uses `codex-agent` with `gpt-5.4-mini`.
- The `send-slack-reply` step uses `riela/chat-reply-worker` and renders the
  Slack reply from `inbox.latest.output.payload.replyText`.
- Direct local mock runs without an event reply target complete as a dry run
  instead of attempting to send to Slack.
- When dispatched by the `slack-gateway-codex-to-workflow` event binding,
  replies target the same Slack channel and thread timestamp from the
  normalized chat event.
