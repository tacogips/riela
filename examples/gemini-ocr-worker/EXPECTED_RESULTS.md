# Expected Results

- The workflow validates as a single worker add-on bundle.
- `ocr-image` uses `riela/gemini-sdk-worker`, which resolves to
  `official/gemini-sdk`.
- The example uses `gemini-3.5-flash`, matching Gemini's current image
  understanding examples.
- The Gemini request includes one inline JPEG image part and one OCR prompt text
  part.
- Live execution requires `addon.env.GEMINI_API_KEY` or
  `addon.env.GOOGLE_API_KEY` to map from a runtime environment variable that
  contains a Gemini API key.
- The worker should return the visible image text, `OCR SAMPLE 42`, in
  `payload.text`.
