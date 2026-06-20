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
- Rina's prompt keeps her persona cool-headed and analytical: short, precise,
  low-temperature replies without bubbly enthusiasm or filler.
- `yui-codex-sdk`, `mika-claude-sdk`, and `rina-cursor-sdk` use
  `riela/codex-sdk-worker`, which resolves to `official/openai-sdk`, runs
  model `gpt-5-nano`, and requires `OPENAI_API_KEY` for live execution.
- Each SDK worker returns visible reply text in `payload.text`; the bundled
  mock path uses each worker's `mockResponseTemplate` so local runs do not need
  live SDK API keys.
- `riela/chat-reply-worker` sends the selected persona reply to the same
  Telegram conversation and thread from the SDK worker's `payload.text`,
  dry-running when a local run has no chat target.
- The selected `send-*-reply` step is the root output for that run. Non-selected
  reply steps advance only through `input_filter_skipped` transitions, so Yui
  and Mika replies are not overwritten by later skipped nodes.
- The bundled mock scenario passes Telegram event variables with an explicit
  Rina mention and completes without requiring live API keys.
