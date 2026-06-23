# Matrix Local Verification

Use local Matrix verification when live homeserver credentials are unavailable or when a deterministic regression is required.

Start from the Matrix example files and prefer committed scripts already owned by the example. Do not create scratch files outside `tmp/`.

Useful checks:

```bash
find examples/matrix-chat-reply examples/matrix-agent-trio-chat -maxdepth 4 -type f | sort
rg -n 'local-synapse|matrix|homeserver|accessTokenEnv|replyBots' examples/matrix-chat-reply examples/matrix-agent-trio-chat
```

If `examples/matrix-chat-reply/local-synapse/run-local-matrix-sample.sh` is present, use it as the deterministic smoke path. A live Element/browser check is optional unless the user specifically asks for a visible chat UI proof.

For persona memory regression, verify:

- The incoming message reaches the Matrix source binding.
- Persona memory read nodes run before reply generation.
- Persona memory write/update nodes persist after reply generation.
- Rina can refer to context produced by Mika or the shared chat history.
