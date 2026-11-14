# Expected Results

- The workflow validates as a single worker add-on bundle.
- `ask-gemini` uses `riela/gemini-sdk-worker`, which resolves to
  `official/gemini-sdk`.
- The example uses `gemini-2.0-flash-lite` so local smoke checks avoid the
  higher-demand Gemini Flash aliases by default.
- Live execution requires `addon.env.GEMINI_API_KEY` or
  `addon.env.GOOGLE_API_KEY` to map from a runtime environment variable that
  contains a Gemini API key.
- The worker returns visible reply text in `payload.text`.
