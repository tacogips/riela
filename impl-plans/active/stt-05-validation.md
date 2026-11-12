# stt-05 `workflow validate` + container rejection for riela/speech-to-text

```json
{
  "planId": "stt-05-validation",
  "planPath": "impl-plans/active/stt-05-validation.md",
  "dependsOn": ["stt-01-contract"],
  "wave": 2,
  "writePaths": [
    "Sources/RielaCLI/BuiltinGatewayRequestChecks+Extended.swift",
    "Sources/RielaCLI/BuiltinAddonContainerResolver.swift",
    "Tests/RielaCLITests/SpeechToTextValidationTests.swift",
    "impl-plans/progress/stt-05-validation.md"
  ],
  "sharedPaths": [],
  "artifactRoots": []
}
```

Artifacts: none. Evidence goes in `tmp/stt-agent-gateway/stt-05/`.

- Design: §7 (validation) and §2.2 host-only rule (rejected by validation *and* at run time).
- Progress log: `impl-plans/progress/stt-05-validation.md`.

## Intent and context

`riela workflow validate` must reject:
- unknown providers;
- invalid fallback entries;
- `fallbackOn` values outside the documented set;
- `addon.env` keys outside the chain's allowlist;
- `whisper-cpp` combined with `addon.container` or `addon.sandbox`.

Production validation already calls `BuiltinGatewayRequestChecks.issues` through
`WorkflowValidationContext+Production.swift:addonRequestChecker`, which falls through to
`extendedIssues(_:leaf:)` (`Sources/RielaCLI/BuiltinGatewayRequestChecks+Extended.swift`).
Add a `riela/speech-to-text` case that reuses `SpeechToTextOptionsParser` from stt-01, so
that validation and runtime share one parser.

The container resolver strips `addon.container` and `addon.sandbox` before the worker runs
(`BuiltinAddonContainerResolver.swift` lines ~139-140). The worker therefore cannot see
them, so the run-time host-only rejection must happen in `BuiltinAddonContainerResolver.executeUnprocessed`.

Patterns to follow:
- `BuiltinGatewayRequestChecks+Extended.swift:xReaderIssues`, for mapping a thrown error to an `issue(<relativePath>, message)`.

## Non-goals

- Do not change the parser (stt-01) or the runtime flow (stt-04).
- No validation of `path`, `language`, or `prompt`.
- Do not reject apple-in-container statically. The design keeps the run-time policyBlocked for apple.

## File-level changes

### `Sources/RielaCLI/BuiltinGatewayRequestChecks+Extended.swift`

Add `case "riela/speech-to-text": return speechToTextIssues(addon)`. Then:
- Take `options` from `addon.config?["options"]`. If it is not an object, return [] (the runtime reports the missing options).
- If `SpeechToTextOptionsParser.isTemplated(options["provider"])`, return []. A template-rendered provider can only be checked at run time.
- Skip templated values (design §7: "skips values that contain `{{` (rendered later)"). Before parsing, build a copy `literal` of `options`:
  - Drop every top-level key whose value `isTemplated`, EXCEPT `fallback` and `command`. Those two are raw at run time (`rawOptionKeys`), so their literal values are what actually runs, and they are always checked. The skip covers `maxAttempts`, `timeoutSeconds`, `onDevice`, `cacheAcceptsFallback`, `fallbackOn`, and any other rendered key. Dropped keys take the parser defaults.
  - If `model` is templated, set it to the placeholder `"templated"` instead of dropping it. Otherwise gemini and openrouter would falsely hit the required-model rule.
  - If `whisperCpp` is an object:
    - drop its templated scalars (`binary`, `threads`);
    - if `model` is templated, set it to the placeholder `"templated"`;
    - if any `extraArgs` element is templated, drop `extraArgs`.
  - If `whisperCpp` itself is templated, replace it with `{model:"templated"}`.
- Call `parse(literal)`. If it throws `MediaPipelineError.invalidOption(name)`, return the issue at relativePath `options.<name>` with the message `"invalid speech-to-text option '<name>'"`.
- `addon.env` keys that are not in `chain.environmentAllowlist` give an issue at relative path `env` with a message naming the rejected keys. Only key names go in the message, never values. `COMMAND_*` keys longer than 8 characters are allowed only when `allowsCommandPrefix`.
- If `chain.usesWhisperCpp` and either `addon.container != nil` or `addon.sandbox != nil`, give an issue at `options.provider` with the message `"speech-to-text provider 'whisper-cpp' runs on the host; remove addon.container/addon.sandbox"`.
- Check whether `issue()` paths are relative to `addon.config`, as `validateGatewayAddon` prefixes `<path>.addon.config`. Choose relative paths so the final diagnostic path reads `….addon.config.options.<name>`. For env, an issue rooted under config is acceptable, provided the message names `addon.env`.

### `Sources/RielaCLI/BuiltinAddonContainerResolver.swift`

In `executeUnprocessed`, before the container settings are computed (after the `sandbox == nil || container == nil` guard and the early return to primary):
- if `input.addon.name == "riela/speech-to-text"`, and the raw `config.options` parses with `SpeechToTextOptionsParser.parse` and `usesWhisperCpp` is true, throw `AdapterExecutionError(.policyBlocked, <same message>)`;
- if the parse fails, do nothing and let the worker report it.

No other behavior change.

## Pitfalls

- The validator sees UNRENDERED options; the runtime parser expects rendered values and
  `MediaPipelineOptions.number` (`Sources/RielaCLI/MediaPipelineOptions.swift:5-19`) rejects
  strings. Never pass a templated rendered key to `parse` — existing valid workflows such
  as `maxAttempts: "{{input.attempts}}"` must still validate with no issue. Only raw
  `fallback`/`command` values are literal at run time and are checked as-is.
- Do not modify the stt-01 parser to accept templates; do the skip in the validator only.

- Return [] for non-speech add-ons. Do not disturb the other cases.
- Do not reject `fallbackOn` when `fallback` is templated. `fallback` is raw (it is not template-rendered), so literal checking is correct.
- The parser rejects `fallbackOn` without `fallback`. Keep that error.

## Tests (`Tests/RielaCLITests/SpeechToTextValidationTests.swift`)

Call `BuiltinGatewayRequestChecks.issues` directly, plus one end-to-end case through the production `WorkflowValidationContext`, if a helper exists (look for existing validation tests that use `addonRequestChecker`).
- `provider:"nope"` -> 1 issue on `options.provider`.
- `provider:"{{input.p}}"` -> no issues.
- `{path:"{{input.audio}}", maxAttempts:"{{input.attempts}}"}` -> no issues.
- templated `timeoutSeconds`, templated `onDevice`, templated `cacheAcceptsFallback` -> no issues each.
- `{provider:"gemini", model:"{{input.m}}"}` -> no issues; `{provider:"whisper-cpp", whisperCpp:{model:"{{input.model}}", threads:"{{input.t}}"}}` -> no issues.
- templated `maxAttempts` + valid `fallback` + `fallbackOn:["rejected"]` -> still exactly the `fallbackOn` issue.
- `fallback:[{provider:"nope"}]` with templated `maxAttempts` -> still the `fallback[0].provider` issue (raw fallback is always checked).
- `fallback:[{provider:"whisper-cpp"}]` -> an issue naming `fallback[0].whisperCpp`.
- `fallbackOn:["rejected"]` with a valid fallback -> an issue on `fallbackOn`.
- `fallbackOn` without `fallback` -> an issue.
- `env {"DEEPGRAM_API_KEY":…}` with openai and no fallback -> an env issue. With fallback `[{provider:"deepgram"}]` -> no env issue.
- whisper-cpp primary or fallback plus `addon.container` -> host-only issue. The same config without container -> no issue.
- A valid openai, command, or apple config -> no issues. Each existing config shape from `docs/workflows/speech.md` -> no issues.
- `BuiltinAddonContainerResolver` with a recording runner (see `BuiltinAddonContainerResolverTests.swift:testMediaAddonsSelectVideoImageWhenBaseImageIsSelected`) and a whisper-cpp config plus `container` -> policyBlocked, and the runner is never invoked. An openai config plus container still dispatches to the video image.

## Verification (evidence in `tmp/stt-agent-gateway/stt-05/`)

- `mkdir -p tmp/stt-agent-gateway/stt-05`
- `arch -arm64 /bin/zsh -lc 'swift build --build-tests' > tmp/stt-agent-gateway/stt-05/build.log 2>&1` -> exit 0.
- `arch -arm64 /bin/zsh -lc "swift test --skip-build --filter 'SpeechToTextValidationTests|BuiltinAddonContainerResolverTests'" > tmp/stt-agent-gateway/stt-05/test.log 2>&1` -> exit 0, 0 failures.
- `arch -arm64 /bin/zsh -lc 'swiftlint lint Sources/RielaCLI/BuiltinGatewayRequestChecks+Extended.swift Sources/RielaCLI/BuiltinAddonContainerResolver.swift Tests/RielaCLITests/SpeechToTextValidationTests.swift' > tmp/stt-agent-gateway/stt-05/lint.log 2>&1` -> 0 new violations.

## Done criteria

- The tests above pass.
- The progress log has commands, exit codes, test counts, and pre/post hashes. Follow the stt-01 drift rules.
