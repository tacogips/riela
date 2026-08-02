# Matrix Local Verification

Use local Matrix verification when live homeserver credentials are unavailable or when a deterministic regression is required.

Start from the Matrix example files and prefer committed scripts already owned by the example. Do not create scratch files outside `tmp/`.

Useful checks:

```bash
find examples/matrix-chat-reply examples/matrix-agent-trio-chat -maxdepth 4 -type f | sort
rg -n 'local-synapse|matrix|homeserver|accessTokenEnv|replyBots' examples/matrix-chat-reply examples/matrix-agent-trio-chat
```

If `examples/matrix-chat-reply/local-synapse/run-local-matrix-sample.sh` is present, use it as the deterministic smoke path. A live Element/browser check is optional unless the user specifically asks for a visible chat UI proof.

For the Note-backed persona-context regression, set an isolated
`RIELA_NOTE_ROOT` and verify:

- The incoming message reaches the Matrix source binding.
- `riela/note-persona-context-read` nodes run before reply generation.
- `riela/note-persona-context-write` nodes persist notes after reply generation.
- Stored notes belong to the `notebook-kind:system-memory` notebook and carry
  the expected `persona:<id>` tag.
- Rina can refer to context produced by Mika or the shared chat history.
