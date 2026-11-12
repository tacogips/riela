# stt-06 speech-to-text documentation

```json
{
  "planId": "stt-06-docs",
  "planPath": "impl-plans/active/stt-06-docs.md",
  "dependsOn": ["stt-01-contract"],
  "wave": 2,
  "writePaths": [
    "docs/workflows/speech.md",
    "docs/container-addons.md",
    "impl-plans/progress/stt-06-docs.md"
  ],
  "sharedPaths": [],
  "artifactRoots": []
}
```

Artifacts: none. Evidence goes in `tmp/stt-agent-gateway/stt-06/`.

- Design: the whole of `design-docs/specs/design-speech-to-text-agent-gateway.md`, which is the source of truth for the wording.
- Progress log: `impl-plans/progress/stt-06-docs.md`.

## Intent and context

The user-facing docs must describe the following:
- the providers and models;
- the agent-gateway transport for openai, gemini, and openrouter;
- the retry and non-retry behavior;
- the failure fields;
- whisper-cpp and its host-only rule;
- the fallback chain;
- the cache fingerprint rule.

They also need a whisper-cpp example and an openai → whisper-cpp fallback example that is configured only in node config.

## Amendment 2026-11-12 (session 854)

The wording now follows the amended design (§2.1.1 gateway contract, §2.2 run-time host-only
check, §4 retry and fallback classes). A previous-run docs hunk exists in
`tmp/stt-agent-gateway/partial-wave-001-003.patch` (`docs/workflows/speech.md`,
`docs/container-addons.md`). It may be reused, but it predates these amendments: add the
gateway Retry-After, `rejected`-never-falls-back and templated-provider host-only sentences,
and remove anything that says hosted providers lose Retry-After.

## Non-goals

- Do not edit the `riela/text-to-speech` section, `docs/voice.md`, examples, or design docs.
- Do not document options that the design does not define.

## File-level changes

### `docs/workflows/speech.md` (the `riela/speech-to-text` section only)

- Provider table:
  - openai: via agent-gateway, `OPENAI_API_KEY` (required), `OPENAI_BASE_URL` (with or without `/v1`), default model `gpt-4o-transcribe`.
  - gemini: `GEMINI_API_KEY`, `GEMINI_BASE_URL`, `model` required.
  - openrouter: `OPENROUTER_API_KEY`, `OPENROUTER_BASE_URL`, `model` required.
  - deepgram, elevenlabs, google, apple, command: as today.
  - whisper-cpp: `whisperCpp.{model (required), binary, threads, extraArgs}`. Binary lookup goes through PATH, then `/opt/homebrew/bin/whisper-cli`. argv is `-m … -f … -l <lang|auto> -nt -np [-t N] [extraArgs]`. Plain-text stdout. No `addon.env`. Input formats are whatever the installed whisper-cli accepts.
- Retry and failures:
  - Retried: `rate-limited` (429), `server-error` (5xx), and `transport-error`, up to `maxAttempts`, using Retry-After (also for openai/gemini/openrouter, where agent-gateway reports it) or 1, 2, 4… s (capped at 60 s). One attempt is one vendor request.
  - Not retried: `quota-exhausted` (`insufficient_quota`, `credit_balance_exhausted`, `billing_hard_limit_reached`, `billing_not_active`, HTTP 402, Gemini per-day quota), `unavailable` (missing credential, missing whisper-cli/model, apple unavailable, local process failure), and `rejected` (auth failures 401/403, other 4xx, unsupported audio type such as aiff for gateway providers, unparseable responses). `rejected` never triggers fallback.
  - Show the failure message format `failureClass=… httpStatus=… providerProblem=…`, and state that it never includes secrets.
- Fallback:
  - `fallback` (1–3 entries, allowed keys, shared `path`/`language`/`prompt`, not template-rendered).
  - `fallbackOn` (the five classes, default all). Quota exhaustion moves on immediately.
  - Output `fallbackFrom`, with a JSON example. The output is unchanged when no fallback happens.
- Cache:
  - The fingerprint fields per provider. One entry per audio file.
  - `cacheAcceptsFallback` (default false). With false, a transcript produced by a fallback provider is never reused and the primary is retried. With true, it is reused only if the file records the producer. Legacy files are reused only for the primary.
- Host-only:
  - whisper-cpp with `addon.container` or `addon.sandbox` is rejected by `workflow validate` and at run time. The run-time check uses the rendered options before any container or sandbox starts, so a templated `provider` that resolves to `whisper-cpp` is also rejected (design §2.2).
  - Validation also rejects unknown providers, bad fallback entries, bad `fallbackOn`, and `addon.env` keys outside the chain allowlist.
- Examples:
  - Keep the existing `command` whisper-cli example.
  - Add a whisper-cpp example `{provider:"whisper-cpp", language:"ja", whisperCpp:{model:"/models/ggml-large-v3.bin"}}`.
  - Add an openai → whisper-cpp fallback example with `addon.env` `OPENAI_API_KEY` mapping and `fallbackOn:["quota-exhausted","rate-limited"]`.
- Every JSON block must parse. Keep the style concise, like the existing doc.

### `docs/container-addons.md`

In the paragraph around line 105 that lists speech-to-text providers in containers, add one sentence: `whisper-cpp` runs only on the host and is rejected with `addon.container` or `addon.sandbox`; hosted providers in the media image still need `egress-allowed`.

## Verification (evidence in `tmp/stt-agent-gateway/stt-06/`)

- `mkdir -p tmp/stt-agent-gateway/stt-06`
- `grep -n "whisper-cpp\|fallbackOn\|cacheAcceptsFallback\|providerProblem\|quota-exhausted\|gemini\|openrouter" docs/workflows/speech.md > tmp/stt-agent-gateway/stt-06/grep.log` -> all terms present.
- Extract each fenced JSON block of the speech-to-text section into `tmp/stt-agent-gateway/stt-06/` and run `python3 -I -m json.tool` on each, logging to `json.log` -> every block exits 0. (Blocks that use `…` placeholders in the output examples are listed as excluded, with the reason.)
- `arch -arm64 /bin/zsh -lc "swift test --filter MediaPipelineWorkflowDocumentationTests" > tmp/stt-agent-gateway/stt-06/doctest.log 2>&1` -> exit 0. Run it after the wave-2 build is green. If a parallel wave-2 edit breaks compilation, record that and rerun.
- `git diff --stat -- docs/workflows/speech.md docs/container-addons.md` -> only these two files.

## Done criteria

- Every item above is documented.
- The JSON examples parse.
- `git diff docs/workflows/speech.md` shows no change to the text-to-speech section.
- The progress log has the commands, exit codes, and pre/post hashes.

## Implementation progress (stt-06)

Documentation changes and JSON/TTS-preservation checks are complete; the required
focused documentation test and formal downstream reviews are recorded in
`impl-plans/progress/stt-06-docs.md`.
