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
    "Tests/RielaCLITests/BuiltinAddonContainerResolverTests.swift",
    "impl-plans/progress/stt-05-validation.md"
  ],
  "sharedPaths": [],
  "artifactRoots": []
}
```

Artifacts: none. Evidence goes in `tmp/stt-agent-gateway/stt-05/`.

- Design: §7 (validation), §2.2 host-only rule (rejected by validation *and* at run time) including "Run-time host-only check" (effective options, before dispatch), and §8 run-time host-only regressions.
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

## Amendment 2026-11-12 (blocked-wave-scope-or-contract, round 1)

Blocker (wave-003, `tmp/opus-terra-waves/opus-terra-design-and-implement-review-loop-session-854/wave-003/wave-summary.json`):
`BuiltinAddonContainerResolverTests.testMediaAddonsSelectVideoImageWhenBaseImageIsSelected`
runs `riela/speech-to-text` with `container: .init()` and no `config`. The new host-only check
correctly throws `invalidInput "invalid speech-to-text option 'options'"`, as design §2.2 step 3
requires. The suite therefore shows 21 tests with 1 failure
(`tmp/stt-agent-gateway/stt-05-validation/test-redispatch.log`).

Decisions:
- `Tests/RielaCLITests/BuiltinAddonContainerResolverTests.swift` is added to this plan's
  `writePaths`, here and in the dispatch manifest. stt-05 is its only owner; stt-04 does not touch it.
- The only edit allowed in that file: in `testMediaAddonsSelectVideoImageWhenBaseImageIsSelected`,
  give the `riela/speech-to-text` iteration an addon `config` of
  `{"options": {"path": "audio.wav", "provider": "openai"}}`. Plain literal strings are enough,
  because the host-only check only renders the options and the file does not need to exist.
  Leave `config` nil for the other three add-on names. Keep the assertion that the video image
  is selected unchanged.
- Forbidden: changing the production check in `BuiltinAddonContainerResolver.swift` to tolerate
  missing options; skipping, deleting or weakening any other test in that file; and editing any
  other test in that file.
- The existing stt-05 implementation in the tree (resolver check, validator,
  `SpeechToTextValidationTests`) is kept. Re-read each file, record pre/post hashes, and change only
  what this amendment requires.
- `.build/` is the shared, gitignored SwiftPM build cache, not owned by any plan. Running
  `swift build` / `swift test` is authorized and does not count as a write. Do not declare
  `.build` in `artifactRoots`, and do not use a separate `--scratch-path`.

Resume verification (logs in `tmp/stt-agent-gateway/stt-05/`):
- `arch -arm64 /bin/zsh -lc 'swift build --build-tests'` -> exit 0.
- `arch -arm64 /bin/zsh -lc "swift test --skip-build --filter 'SpeechToTextValidationTests|BuiltinAddonContainerResolverTests'"`
  -> exit 0 with 0 failures. The image-selection test passes and all host-only regressions pass.
- Strict lint on the four changed Swift files, including `BuiltinAddonContainerResolverTests.swift` -> 0 violations.

## Amendment 2026-11-12 (session 854): partial reuse

A previous-run implementation exists in `tmp/stt-agent-gateway/partial-untracked/Tests/RielaCLITests/SpeechToTextValidationTests.swift`
and in the `BuiltinGatewayRequestChecks+Extended.swift` / `BuiltinAddonContainerResolver.swift`
hunks of `tmp/stt-agent-gateway/partial-wave-001-003.patch`. The validator part may be reused
after a diff against this plan. The resolver hunk implements the old raw-options guard
(STT-DESIGN-001) and must not be applied; write the effective-options check described below.

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

Amended 2026-11-12 (STT-DESIGN-001, design §2.2 "Run-time host-only check"). The
earlier version parsed the unrendered options and ignored parse failures, so a templated
provider, or literal whisper-cpp combined with a templated numeric option, slipped past
the check and ran in the worker after the isolation metadata had been stripped. Use the
**effective** options instead.

In `executeUnprocessed`, place the check right after the `sandbox == nil || container == nil`
guard and the early return to primary, so it runs before
`prepareAppleGatewayContainerOperation`, image selection, admission, stripping
(`workerInput.addon.container/sandbox = nil`, ~lines 138-140), and any runner call.
Add a file-private helper `speechToTextHostOnlyCheck(_ input:)` that:
- returns at once unless `input.addon.name == "riela/speech-to-text"`;
- computes the effective options exactly like `MediaPipelineContext.finish`
  (`MediaPipelineAddons.swift:71-89`):
  - remove the raw keys `command` and `fallback` from `config.options`;
  - render the rest with `renderAddonConfig(.object(rawConfig), variables: addonVariables(for: templateInput))` (public, `Sources/RielaAddonSupport/WorkflowAddonSupport.swift:42-67`);
  - merge the raw values back, unrendered;
- if rendering throws, or the rendered config has no `options` object, throws
  `AdapterExecutionError(.invalidInput, "invalid speech-to-text option 'options'")`;
- throws `AdapterExecutionError(.policyBlocked, "speech-to-text provider 'whisper-cpp' runs on the host; remove addon.container/addon.sandbox")`
  when either:
  - the effective `options.provider` is `.string("whisper-cpp")`, or
  - the raw `options.fallback` is an array containing an object whose `provider` is `.string("whisper-cpp")`;
- decides this with the direct scan above, **not** through `SpeechToTextOptionsParser.parse`,
  so a parse failure cannot bypass the check. Parse errors for other providers are still
  reported by the worker, as today.

Do not edit `MediaPipelineAddons.swift`; it is owned by stt-04. Use `["command", "fallback"]`,
the keys stt-04 sets as `rawOptionKeys`, as a file-private constant here and note the
coupling in the progress log. No other behaviour change: apple, raw command and fallback,
valid templated options, and openai-only container/sandbox dispatch are untouched.

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
- `BuiltinAddonContainerResolver` run-time host-only regressions (design §8), using a recording runner and a recording primary resolver (see `BuiltinAddonContainerResolverTests.swift:testMediaAddonsSelectVideoImageWhenBaseImageIsSelected`). Run each case once with `addon.container` and once with `addon.sandbox`. Each must throw the exact host-only `policyBlocked` message with zero runner calls and zero primary calls:
  - literal `provider:"whisper-cpp"`, `whisperCpp:{model:"m.bin"}`;
  - `provider:"{{input.p}}"` with `addon.inputs` making it render to `"whisper-cpp"` (the static validator returns no issue for this config; assert that too);
  - literal `provider:"whisper-cpp"` with `maxAttempts:"{{input.n}}"` and `whisperCpp:{model:"m.bin", threads:"{{input.t}}"}`;
  - `provider:"openai"` with a raw `fallback:[{provider:"whisper-cpp", whisperCpp:{model:"m.bin"}}]`.
- Preserved behaviour:
  - an openai-only config plus container still dispatches to the video image (runner invoked once);
  - an openai-only config plus sandbox does not throw the host-only message;
  - a raw `fallback` entry with `command:["x","{{path}}"]` still reaches the runner with `{{path}}` unrendered in the transported config.

## Verification (evidence in `tmp/stt-agent-gateway/stt-05/`)

- `mkdir -p tmp/stt-agent-gateway/stt-05`
- `arch -arm64 /bin/zsh -lc 'swift build --build-tests' > tmp/stt-agent-gateway/stt-05/build.log 2>&1` -> exit 0.
- `arch -arm64 /bin/zsh -lc "swift test --skip-build --filter 'SpeechToTextValidationTests|BuiltinAddonContainerResolverTests'" > tmp/stt-agent-gateway/stt-05/test.log 2>&1` -> exit 0, 0 failures.
- `arch -arm64 /bin/zsh -lc 'swiftlint lint Sources/RielaCLI/BuiltinGatewayRequestChecks+Extended.swift Sources/RielaCLI/BuiltinAddonContainerResolver.swift Tests/RielaCLITests/SpeechToTextValidationTests.swift Tests/RielaCLITests/BuiltinAddonContainerResolverTests.swift' > tmp/stt-agent-gateway/stt-05/lint.log 2>&1` -> 0 new violations.

## Done criteria

- The tests above pass.
- The progress log has commands, exit codes, test counts, and pre/post hashes. Follow the stt-01 drift rules.

Implementation progress: validation and the pre-dispatch effective-options host-only guard are implemented. Verification and formal review status are recorded in `impl-plans/progress/stt-05-validation.md`; formal review remains downstream.
