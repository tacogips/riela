# instance-cancel-05: `riela instance cancel` CLI action

**planId**: instance-cancel-05-cli-command
**dependsOn**: none (wave 1). It speaks the HTTP contract pinned in the design and uses string codes, not Swift types from plan 01.
**Design Reference**: design-docs/specs/design-instance-cancel.md §3 C4, C4b, C7
**Created**: 2026-11-11
**Progress log**: impl-plans/progress/instance-cancel-05-cli-command.md
**Evidence root**: tmp/instance-cancel/instance-cancel-05-cli-command/

## Intent and context

Add a fourth action `cancel` to `Sources/RielaCLI/InstanceAppCommands.swift`.
It reuses the existing discovery (`RielaAppAPIClient.resolveEndpoint`,
`expectedProfile`), the local identity check (`localInstanceExists`), the
bootstrap → CSRF POST (`client.post`), the failure shape (`Self.failure`) and
the closed-field output (`Self.result`), exactly like `reload`
(`InstanceAppCommands.swift:95-127`).

## Non-goals

- Do not change the reload, run or executions behavior, flags or output.
- Do not use `GET .../executions` to choose a session.
- No server-side code.

## File-level changes

- `Sources/RielaCLI/InstanceAppCommands.swift`:
  - In `AppInstanceOptions`, add `@Option var session: String?`.
  - The action whitelist (line 40) gains "cancel".
  - Cancel-only validation, all usage errors:
    - the reason must be 1...512 bytes after trimming, else
      `instance_reason_required`;
    - `--timeout-seconds` without `--wait` → `instance_invalid_options`;
    - `--session` empty, or over 1024 bytes → `instance_invalid_options`.
  - New `private func cancel(_ client:, path:, identity:, args:, reason:) async throws -> CLICommandResult`:
    - `bootstrap = try await client.bootstrap()`, then body
      `["expectedProfile": client.profile, "reason": reason]`, with no other
      keys.
    - With `--session`, post to
      `path + "/executions/" + sessionId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) + "/cancel"`.
      Without it, post to `path + "/cancel"`.
    - Decode the 202 into a private `AppCancelResponse { identity, profile, sessionId, owner, outcome }`.
    - Map failures: 404 or 405 with a code not in
      {`instance_not_found`, `session_not_found`} → `app_cancel_unsupported`.
      `ambiguous_running_sessions` → exit 1 with stdout
      `{"error":"ambiguous_running_sessions","exitCode":1,"sessionIds":[…],"pendingRunCount":n}`,
      where the ids and count are read from `failure.body`'s top-level keys
      and re-encoded as closed fields; on a decode failure, emit empty
      `sessionIds` and `pendingRunCount` 0. Other codes pass through the
      existing throw path.
    - `--wait`: loop, `GET path + "/executions/" + encodedSession`; decode
      `status`; stop on `completed|failed|cancelled`; sleep 1 s through the
      injected `sleep`. The timeout is `args.timeoutSeconds ?? 60`, counted in
      whole elapsed seconds like `reload`.
    - Output `AppCancelOutput { identity, profile, sessionId, owner, outcome, status: String? }`,
      encoding `status` as null when absent. Without `--wait`, status is
      null. Final `cancelled` → exit 0. Another terminal status → result with
      code `cancel_not_effective` (exit 1, body printed). Timeout → code
      `cancel_wait_timeout` (exit 1, body printed with the last status).
      Mirror how `runInstance` uses `Self.result(_, code:)` to return exit 1
      with a body.
- `Sources/RielaCLI/InstanceCommands.swift:19`: the case list
  `"reload", "run", "executions"` gains `"cancel"`.
- `Sources/RielaCLI/RielaCLIApplication.swift` (usage text near lines
  355-357): add the line
  `riela instance cancel <identity> [--session <id>] --reason <text> [--wait] [--timeout-seconds N] [--server URL] [--profile P] [--cwd <dir>]`.
- `Sources/RielaCore/SurfaceCatalog+RowsCLI.swift` (line ~352): append
  `surfaceRow(instanceDefaults, id: "instance.cancel", family: "instance", kind: .mutation, cli: "instance cancel")`.
  If a surface-parity or help test then demands a generated artifact or help
  table entry, update **only** the file named in the failing assertion and
  record it in the progress log. Expected: `Sources/RielaCLI/CLISubcommandHelp.swift`.

Pitfalls:
- Exit codes: usage is 2, remote is 1.
- Never print raw server bodies; re-encode closed fields only (the same rule
  as `executions`).
- `--profile` mismatch is still caught by the bootstrap check.

## Tests: Tests/RielaCLITests/InstanceAppCancelCommandTests.swift (new)

Imitate `Tests/RielaCLITests/InstanceAppCommandsTests.swift` (injected
transport, a temp app root, an instant `sleep`).
- with `--session s1` → POST path `/api/v1/instances/ID/executions/s1/cancel`
  and body keys exactly `{expectedProfile, reason}`; headers include Origin,
  x-riela-csrf, x-riela-profile and content-type;
- without `--session` → POST `/api/v1/instances/ID/cancel`, and the transport
  records **no** GET `/executions`;
- 409 `ambiguous_running_sessions` with body ids `[a,b]` → exit 1, stdout
  contains the ids, and `pendingRunCount` is present;
- 409 `no_running_execution` → exit 1, code on stderr;
- 404 `not_found` (fixture: the current projection body
  `{"error":{"code":"not_found","message":"Unknown API route"}}`) →
  `app_cancel_unsupported`, for both routes;
- 404 `session_not_found` → passes through;
- 409 `not_running` → passes through;
- `--wait` with statuses running → cancelled → exit 0 and status
  "cancelled";
- `--wait` → completed → exit 1 `cancel_not_effective`;
- `--wait --timeout-seconds 2`, always running → exit 1
  `cancel_wait_timeout`;
- missing `--reason` → exit 2 `instance_reason_required`;
- `--timeout-seconds 5` without `--wait` → exit 2 `instance_invalid_options`;
- the existing reload, run and executions tests are unchanged and pass.

## Verification (arm64 shell; tee to the evidence root)

- `swift build` → exit 0.
- `swift test --filter "InstanceAppCancelCommandTests|InstanceAppCommandsTests|SurfaceParity|CLISubcommandHelp"`
  → exit 0, 0 failures.
- `swiftlint lint` on the changed and new files → no new violations.

## Done criteria

- The tests pass.
- The diff is limited to the files listed here, plus any single
  catalog-artifact or help file named by a failing assertion, recorded in the
  progress log.

## Drift protocol

Re-read before each edit and record pre/post sha256. Stop on unexpected drift,
especially in `InstanceAppCommands.swift`, which branch
fix/manual-overlap-terminal-reserve may also change. Keep the edits additive.
