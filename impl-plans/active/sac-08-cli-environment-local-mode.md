# sac-08-cli-environment-local-mode: `riela environment status|reload` local mode

- planId: `sac-08-cli-environment-local-mode`
- wave: 3, dependsOn: `sac-01-control-contract`, `sac-02-owner-lock-startup`, `sac-05-control-channel`
- design: `design-docs/specs/design-serverless-app-control.md` §3.1 (environment default change), §3.2, §3.8, §3.10
- writePaths:
  - `Sources/RielaCLI/EnvironmentCommand.swift`
  - `Tests/RielaCLITests/RuntimeEnvironmentChannelTests.swift` (environment-client test invocations only: add `--server`)
  - `Tests/RielaCLITests/EnvironmentLocalModeTests.swift` (new)
  - `impl-plans/progress/sac-08-cli-environment-local-mode.md`
- sharedPaths: none
- evidence: `tmp/serverless-app-control/sac-08/`

## Intent and context

Today `riela environment` defaults to `--server http://127.0.0.1:8787` (the
`riela serve` host). After this change:

- **no `--server`** → local mode. It probes the App socket through
  `RielaAppLocalControlProbe` (sac-05):
  - `reload` sends `environment.reload` and then `environment.status`;
  - `status` sends `environment.status`;
  - no App running → `app_not_running`.
- `--server <url>` → exactly today's HTTP flow and output.

Both modes print only the closed status fields, through the existing
`render(_:)` and `decodeStatus(_:)`. No values are ever printed.

## Non-goals

- `--profile` stays required.
- No env var.
- No change to the HTTP request construction or the output rendering.
- Do not touch `InstanceAppCommands.swift` or `RielaAppAPIClient.swift`
  (sac-07).
- No local-disk environment status: status is in-memory App state, so with no
  App the command returns `app_not_running`.

## File-level changes (`EnvironmentCommand.swift`)

- `@Option var server: String?` (no default).
- `EnvironmentCommand` gains `var environment: [String: String]? = nil`, used
  to compute `RielaAppAPIClient.appRoot(environment:)` with the default
  `CLIRuntimeEnvironment.mergedProcessEnvironment()`. It also gains
  `var probe: (@Sendable (URL) throws -> RielaAppLocalControlProbe.Outcome)? = nil`
  as a test seam. Keep the existing `transport` property and its default.
- Validation stays the same. URL validation applies only when `server` is
  non-nil.
- `server != nil` → the unchanged existing HTTP code path.
- `server == nil`:
  - non-macOS → stderr `app_server_required`;
  - macOS → probe:
    - `.notRunning(lock)` → release, stderr `app_not_running: start RielaApp, or use --server`,
      exit failure;
    - channel error code → stderr that code;
    - `.channel(c)`:
      1. `c.send(.bootstrap, profile:)`. A bootstrap `profile` other than
         `--profile` → `environment_profile_conflict` (the existing code),
         with no reload sent.
      2. For `reload`: `c.send(.environmentReload(identity: instance, body: {"action":"reloadEnvironment","expectedProfile":profile,"expectedRevision":rev}), profile:)`.
      3. A non-2xx result maps through the existing `failure(status:body:)`
         (`EnvironmentHTTPFailure`) from the result body's `Data`. A 422
         prints the status with `lastError`, exactly as the HTTP path does.
      4. Then `c.send(.environmentStatus(identity:), profile:)`, followed by
         `decodeStatus` and `render`.

## Pitfalls

- The `RuntimeEnvironmentChannelTests` environment-client tests (for example
  `testEnvironmentClientProfileConflictNeverPostsAndResponseIsTyped`,
  `testEnvironmentClientReloadUsesResidentCSRFAndReturnsOnlyStatus`,
  `testEnvironmentReload422PrintsStatusLastErrorInsteadOfHTTPCode`,
  `testEnvironmentErrorEnvelopeCodesAndFallbacks`,
  `testEnvironmentStatusDecodesUnknownLastErrorTolerantly`) call
  `command.run([...])` without `--server`. Append
  `"--server", "http://127.0.0.1:8787"` to each such argument list and change
  nothing else. Assertions, including the Origin `http://127.0.0.1:8787`, stay
  identical.
- `testEnvironmentHelpIsStaticAndNeverUsesTransportOrEchoesArguments` must
  still pass. Help must never probe.
- Never print environment values. The channel result body passes through
  `decodeStatus`/`render` only.
- Tests inject `environment` with a temp `RIELA_APP_ROOT=/tmp/rac-<8hex>`.
  Never probe the real root.

## Tests (`EnvironmentLocalModeTests`, in-process `RielaAppControlChannelServer` with a scripted handler)

| Situation | Expected outcome |
| --- | --- |
| `status --instance i --profile default` | handler ops `[.bootstrap, .environmentStatus("i")]`; stdout is the closed-field JSON; an extra field `"unexpectedSecret":"DO_NOT_FORWARD"` in the handler body is not printed |
| `reload` | ops `[.bootstrap, .environmentReload, .environmentStatus]`; the reload body has keys `{action, expectedProfile, expectedRevision}` with revision from bootstrap |
| Bootstrap profile `other` | `environment_profile_conflict`; no `environmentReload` op |
| Reload 422 with a status body carrying `lastError` | prints the status with `lastError`, matching the HTTP 422 behaviour |
| No socket, free lock | `app_not_running`; the lock is released afterwards |
| Lock held, no socket | `app_channel_unavailable` |
| `--server http://127.0.0.1:8787` with an injected HTTP transport | the probe seam is never called |

## Verification (`tmp/serverless-app-control/sac-08/`)

- `mkdir -p tmp/serverless-app-control/sac-08`
- `arch -arm64 /bin/zsh -lc 'swift build --build-tests' > tmp/serverless-app-control/sac-08/build.log 2>&1`
  must exit 0.
- `arch -arm64 /bin/zsh -lc "swift test --skip-build --filter 'EnvironmentLocalModeTests|RuntimeEnvironmentChannelTests|ServeWebHostRuntimeEnvironmentTests'" > tmp/serverless-app-control/sac-08/test.log 2>&1`
  must exit 0.
- `git diff -U0 -- Tests/RielaCLITests/RuntimeEnvironmentChannelTests.swift > tmp/serverless-app-control/sac-08/existing-test-diff.log`.
  Record in the progress log that every changed line only appends
  `"--server", "http://127.0.0.1:8787"`.
- `arch -arm64 /bin/zsh -lc 'swiftlint lint Sources/RielaCLI/EnvironmentCommand.swift Tests/RielaCLITests/EnvironmentLocalModeTests.swift Tests/RielaCLITests/RuntimeEnvironmentChannelTests.swift' > tmp/serverless-app-control/sac-08/lint.log 2>&1`

## Done criteria

- Both modes behave as in the table.
- The existing tests change only by the appended `--server`.
- The progress log records exit codes, log paths and hashes, using the drift
  rules from sac-01.
