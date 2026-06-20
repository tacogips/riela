# Expected Results

- The workflow validates as a simple step-addressed Telegram trio chat bundle.
- Persona and reply nodes use `inputFilters` with Telegram JavaScript
  expressions. Filters are OR-able per node; non-matching nodes are skipped
  without failing the workflow.
- Mika and Rina answer only when `telegram.message.text` explicitly mentions
  their display name or Telegram bot username, such as `Mika`,
  `@mikatrend0529bot`, `Rina`, or `@rinacursor0529bot`.
- Yui answers when explicitly mentioned as `Yui` or `@YuiCodexF0529Bot`, and
  also acts as the default responder when the message does not mention Mika or
  Rina.
- Mention matching uses token-style boundaries, so concatenated strings such as
  `Mikausersidecheck` do not count as a Mika mention.
- Each persona prompt repeats the same mention policy so the LLM has the same
  routing condition as the node-level filter.
- `yui-codex-sdk` uses `riela/codex-sdk-worker`, which resolves to
  `official/openai-sdk` and requires `OPENAI_API_KEY` for live execution.
- `mika-claude-sdk` uses `riela/claude-sdk-worker`, which resolves to
  `official/anthropic-sdk` and requires `ANTHROPIC_API_KEY` for live execution.
- `rina-cursor-sdk` uses `riela/cursor-sdk-worker`, which resolves to
  `official/cursor-sdk`, runs model `gpt-5.5`, and requires `CURSOR_API_KEY`
  for live execution.
- Each SDK worker returns visible reply text in `payload.text`; the bundled
  mock path uses each worker's `mockResponseTemplate` so local runs do not need
  live SDK API keys.
- `riela/chat-reply-worker` sends the selected persona reply to the same
  Telegram conversation and thread from the SDK worker's `payload.text`,
  dry-running when a local run has no chat target.
- The bundled mock scenario passes Telegram event variables with an explicit
  Rina mention and completes without requiring live API keys.
