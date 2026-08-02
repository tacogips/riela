# Expected Results

- The workflow validates as a single worker add-on bundle.
- `ask-gemini` uses `riela/gemini-sdk-worker`, which resolves to
  `official/gemini-sdk`.
- The example uses the stable `gemini-3.5-flash-lite` model so local smoke
  checks use Gemini's current low-latency, cost-efficient API model.
- Live execution requires `addon.env.GEMINI_API_KEY` or
  `addon.env.GOOGLE_API_KEY` to map from a runtime environment variable that
  contains a Gemini API key.
- The worker returns visible reply text in `payload.text`.
