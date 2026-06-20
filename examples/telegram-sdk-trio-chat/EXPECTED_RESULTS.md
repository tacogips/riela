# Expected Results

- The workflow validates as a simple step-addressed Telegram trio chat bundle.
- Persona and reply nodes use `inputFilters` with Telegram JavaScript
  expressions. Filters are OR-able per node; non-matching nodes are skipped
  without failing the workflow.
- The default Yui filter accepts messages that do not name Mika/Rina, while
  Mika and Rina filters activate on their aliases in `telegram.message.text`.
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
- The bundled mock scenario passes Telegram event variables that activate Rina and
  completes without requiring live API keys.
