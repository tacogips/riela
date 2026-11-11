# mrot-03: `riela instance run --allow-overlap` and `instance_busy` surfacing

**planId**: mrot-03-cli-allow-overlap
**dependsOn**: none (wave 1). The wire contract is pinned by the design (§3.3, §3.4) and implemented App-side by mrot-05.
**Design Reference**: design-docs/specs/design-manual-run-overlap-and-terminal-reserve.md §3.3, §3.4, §6 (CLI row)
**Created**: 2026-11-11
**Progress log**: impl-plans/progress/mrot-03-cli-allow-overlap.md
**Evidence root**: tmp/manual-overlap-terminal-reserve/mrot-03/

## Intent and context

`riela instance run ID` (`Sources/RielaCLI/InstanceAppCommands.swift`,
`runInstance`) posts to `POST /api/v1/instances/{identity}/runs`. Once mrot-05
lands, the App answers HTTP 409 with
`{"error":{"code":"instance_busy","runningSessionId":"<sid|pending>"}}` when
the instance already has a live execution, unless the body contains
`"allowOverlap": true`.

## Wire contract (pinned)

- Request: send `"allowOverlap": true` **only** when `--allow-overlap` is
  given. Without the flag, the body keys stay exactly
  `expectedProfile, expectedRevision, variables`, because older Apps reject
  unknown keys.
- Response: on 409 with code `instance_busy`, read `error.runningSessionId`
  from the body (`RielaAppAPIFailure.body`). Then:
  - stdout: `{"error":"instance_busy","sessionId":"<runningSessionId>","exitCode":1}` plus a newline
  - stderr: `instance_busy` plus a newline
  - exit code 1
  If `runningSessionId` is absent (for example the existing App-shutting-down
  `instance_busy`), keep today's generic failure output unchanged.

## Non-goals

- No changes to reload or executions behavior or output, `--wait` polling,
  timeouts, or `RielaAppAPIClient` transport. `EnvironmentClientStatus.safeCode`
  already passes `instance_busy`.
- Do not edit `docs/` (mrot-06) or any App or dispatcher file.

## File-level changes

- `Sources/RielaCLI/InstanceAppCommands.swift`
  - `AppInstanceOptions`: add `@Flag var allowOverlap = false`. Its argument
    name must be `--allow-overlap`, the ArgumentParser default for that
    property name. Imitate `@Flag var waitIdle`.
  - Reject `--allow-overlap` for actions other than `run` with the existing
    `instance_invalid_options` usage error, the same way other action-specific
    validation is done in `run(_:)`.
  - `runInstance`: add `allowOverlap: true` to the body only when the flag is
    set. Catch `RielaAppAPIFailure` where `code == "instance_busy"` and
    `status == 409` around the `client.post` call. Decode a small private
    `Decodable` from `body` to get `runningSessionId`. Emit the contract
    output. Add a private `Encodable` struct
    `{error, sessionId, exitCode}` next to `AppCommandFailure`, and keep the
    key order `error, sessionId, exitCode` with `JSONEncoder` defaults the way
    `AppCommandFailure` does.
- `Sources/RielaCLI/RielaCLIApplication.swift`: in the help line at about
  line 356 (`riela instance run <identity> …`), add `[--allow-overlap]` after
  `[--poll-interval-seconds N]`. Change nothing else in this file.
- `Tests/RielaCLITests/InstanceAppCommandsTests.swift`: add tests. Imitate
  `testRunPollingAndFallback` and `testErrorCodesAndSizeLimit` (fake
  transport capturing request bodies).

## Tests (`situation -> expected`)

- `run` without the flag → the captured POST body has exactly 3 keys and no
  `allowOverlap`.
- `run --allow-overlap` → the body has `allowOverlap == true`, and success
  output is unchanged.
- Fake 409 `{"error":{"code":"instance_busy","runningSessionId":"hourly-refresh-session-249"}}`
  → exit 1, stdout JSON
  `{"error":"instance_busy","sessionId":"hourly-refresh-session-249","exitCode":1}`,
  stderr `instance_busy\n`, and no polling GET issued.
- Fake 409 `instance_busy` without `runningSessionId` → today's generic
  failure output (assert it matches the pre-change behavior).
- `reload --allow-overlap` → exit 2 with `instance_invalid_options`, and no
  request sent.

## Invariants

- Existing InstanceAppCommandsTests pass unmodified.

## Verification

- `/usr/bin/arch -arm64 /bin/zsh -lc 'swift build --target RielaCLI'`: exit 0.
- `/usr/bin/arch -arm64 /bin/zsh -lc 'swift test --filter InstanceAppCommandsTests'`: all pass.
- `/usr/bin/arch -arm64 /bin/zsh -lc 'swiftlint lint Sources/RielaCLI/InstanceAppCommands.swift Tests/RielaCLITests/InstanceAppCommandsTests.swift'`: clean.

Record each command's exit status and log path, plus fresh-read pre and post
hashes per edited file. Stop on drift.

## Done when

- [x] Flag, body rule, 409 mapping and help line done.
- [x] Five tests added and green.
- [x] Progress log complete.
