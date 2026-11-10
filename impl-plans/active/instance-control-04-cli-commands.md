# Instance control 04: CLI identity normalization, App endpoint discovery, reload/run/executions commands

**Status**: Planned
**planId**: instance-control-04-cli-commands
**dependsOn**: none (wave 1). The CLI decodes App responses with its own closed structs, so it needs no shared types.
**Design Reference**: design-docs/specs/design-instance-reload-run-cli.md D1, D3, D5, §4
**Created**: 2026-11-10
**Evidence root**: tmp/instance-control/instance-control-04-cli-commands/

## Intent and context

Operators and agents must control resident RielaApp instances with only the `riela` CLI:

1. `riela instance show <id>` must accept identities printed by `riela instance list`. Today, `ScopedWorkflowInstanceStore.findInPrecedence` (`Sources/RielaCLI/FileWorkflowInstanceStore.swift`) never searches App profiles.
2. Three new App-API subcommands: `reload`, `run` and `executions`.
3. The App endpoint and profile are discovered read-only from `<appRoot>` (`$RIELA_APP_ROOT` or `~/.riela/rielaapp`).

The existing client pattern to imitate is `Sources/RielaCLI/EnvironmentCommand.swift`:
- bootstrap → csrf;
- `x-riela-profile` header;
- `expectedRevision`;
- no-redirect delegate, 1 MiB cap;
- safe-code error mapping, using `EnvironmentClientStatus.safeCode`.

## Non-goals

- `riela environment` keeps its defaults and output unchanged. **Do not edit `EnvironmentCommand.swift`**; you may copy its helpers into the new client.
- No GraphQL or SDL change. No writes under `~/.riela/rielaapp` or `~/.riela/profiles`, ever. Never quarantine or rename `web-server.json` from the CLI.
- No new qualified identity syntax.

## File-level changes

### Sources/RielaCLI/FileWorkflowInstanceStore.swift

- `ScopedWorkflowInstanceStore.find(identity:workflowId:scope:)`: when `scope` is `nil` or `.all`, search project → user → App profiles.
  - Add a new method `findRecord(identity:workflowId:scope:profile:) throws -> (scope: String, instance: WorkflowInstanceDefinition)?`. Its scope string is `"project"`, `"user"` or `"app:<profile>"`.
  - Keep the existing `find` signature and behaviour for project/user callers. `findRecord` wraps it.
- `AppProfileWorkflowInstanceStore` gains `find(identity:profile:workflowId:) throws -> [(profile: String, instance:)]`.
  - When more than one profile matches and `profile == nil` → `WorkflowInstanceStoreError.ambiguousIdentity(identity, profiles)`. Reuse the existing case; its second argument holds the profile names.
- `workflowId(from:)` also strips `selected-workflow:`. For path sources, read `<path>/workflow.json` `workflowId` when it is readable and decodes. Use a minimal `Decodable { workflowId: String }` and swallow errors. Otherwise use the stripped remainder.

### Sources/RielaCLI/InstanceCommands.swift

- `show` uses `findRecord` and accepts `--profile`. Output stays `InstanceRecord` with `scope: "app:<profile>"`, the same as `list`.
- `update` and `remove`: if the identity resolves only to an App profile (no project/user match), throw a `CLIUsageError` with exactly: `instance_app_scope_read_only: use 'riela instance reload <identity> [--workflow-definition-dir <dir>]'`. Never save a shadow project instance.
- Add `public func runAsync(_ options: CLICommandOptions) async -> CLICommandResult`:
  - it routes `reload`, `run` and `executions` to `InstanceAppCommands`;
  - other subcommands go to the existing sync `run`.

### Sources/RielaCLI/RielaAppAPIClient.swift (new)

`struct RielaAppAPIClient` with the following parts.

**Injectable transport.** `typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)`, with the same default as `EnvironmentCommand.transport`: ephemeral session, 30 s timeout, no redirects.

**Endpoint resolution.** `static func resolveEndpoint(server: String?, appRoot: URL, environment: [String: String]) throws -> URL`.
- `--server` is validated exactly like `EnvironmentCommand`: http(s), no userinfo/query/fragment/path, plain http only for 127.0.0.1/localhost/::1.
- Otherwise read `<appRoot>/web-server.json` with a **read-only** `JSONDecoder` of `{isEnabled, port}`. Never call `RielaAppWebServerSettingsStore.load()`, because it quarantines.
- The port must be in 1...65535. A missing or corrupt file gives 19091. The endpoint is `http://127.0.0.1:<port>`.
- `appRoot` is `$RIELA_APP_ROOT` if set, else `<home>/.riela/rielaapp`. Use `CLIRuntimeEnvironment.homeDirectory(environment:)`.
- Non-macOS without `--server` → `CLIUsageError("app_server_required")`.

**Profile resolution.** `static func expectedProfile(explicit: String?, appRoot: URL) -> String` reads `<appRoot>/active-profile.json`.
- `RielaAppProfileStore(appRootURL:).loadActiveProfileName()` may be used only if it is read-only; check that it is (`DaemonWorkflowSupport.swift:139`). Otherwise decode `{activeProfileName}` manually. The default is `default`.
- Validate the profile: non-empty, ≤128 bytes.

**Bootstrap.** `func bootstrap() async throws -> (profile: String, revision: Int, csrfToken: String)`.
- If the bootstrap profile differs from the expected profile → error `app_profile_conflict`, with no further request.

**Requests.**
- `func get(_ path: String) async throws -> Data` sets `x-riela-profile`.
- `func post(_ path: String, body: [String: Any]) async throws -> Data` sets:
  - `Origin` = endpoint string without trailing `/`;
  - `x-riela-csrf`, `x-riela-profile`, `Content-Type: application/json`.

**Errors.** Non-2xx → `RielaAppAPIFailure { code: String; status: Int; body: Data }`.
- `code` is the `{"error":{"code"}}` envelope code when it is safe-code shaped, else `app_http_<status>`.
- A connection failure (URLError `cannotConnectToHost`/`networkConnectionLost`/`timedOut`) → code `app_unreachable`, with the hint text `start the web server in RielaApp Console > Settings > Web Config server` on stderr.
- Responses over 1 MiB → `app_response_too_large`.

Identity path segments are percent-encoded with `.alphanumerics`, as in `EnvironmentCommand`.

### Sources/RielaCLI/InstanceAppCommands.swift (new)

All three commands share these rules:
- Options `--server`, `--profile`, `--cwd`.
- Output: exactly one JSON object on stdout.
- Failure: exit 2 for usage errors (`.usage`), 1 for remote errors. Stdout is `{"error":"<code>","exitCode":n}` (the `InstanceFailureResult` shape); stderr is `<code>`.
- Before any request, when `--server` is absent: the identity must exist in `AppProfileWorkflowInstanceStore` for the expected profile, else `instance_not_found` with **no request sent**.

**`reload <identity> --reason <text> [--workflow-definition-dir <dir>] [--interrupt-running] [--wait-idle] [--timeout-seconds N]`**
- Request:
  - `--reason` is required and trimmed to 1–512 bytes (usage error otherwise).
  - A relative directory is resolved against `--cwd` (default: the current directory) and standardized to an absolute path.
  - `POST /api/v1/instances/{id}/reload` with exactly `{expectedProfile, expectedRevision, reason, workflowDirectory (string|null), interruptRunning}`.
- Retry: `--wait-idle` retries only the 409 `instance_run_in_flight`, every 10 s, until `--timeout-seconds` (default 600, range 1...86400). Use an injectable sleep. Each retry re-bootstraps.
- Output: on 200, print the decoded response re-encoded from a closed struct. The fields are exactly those of the design D4 response:
  - `profile`, `revision`, `identity`, `workflowId`, `workflowDirectory`, `sourceChanged`
  - `definition{outcome,versionId,digest}`
  - `eventBindings{respawnRequired,respawned}`
  - `handoff`, `runtimeStatus`, `committed`
- Exit status:
  - 0 only for a 200 with `handoff != "lost"`.
  - A lost handoff → exit 1 with code `reload_handoff_lost`; still print the body.
  - Non-2xx with `committed:true` in the body → print the body, exit 1, with the code from the envelope.
  - Any 404/405 whose code is not `instance_not_found` → `app_reload_unsupported`.

**`run <identity> [--variables <json|@file>] [--wait] [--timeout-seconds N] [--poll-interval-seconds N]`**
- Request:
  - `--variables` goes through `JSONReferenceLoader.object(from:workingDirectory:)`; the default is `{}`; a non-object value is a usage error.
  - `POST /api/v1/instances/{id}/runs` with exactly `{expectedProfile, expectedRevision, variables}`.
- Response `202 {id,status,sessionId,error}`:
  - Without `--wait`: poll `GET /api/v1/workflow-editor/launches/{id}` until `sessionId != null` or the status is terminal. Interval `--poll-interval-seconds` (default 2, range 1...60). Bounded by `--timeout-seconds` (default 60).
  - With `--wait`: poll until `completed|failed` (default timeout 3600).
  - A launch 404 after a sessionId was seen → fall back to `GET /api/v1/instances/{id}/executions/{sessionId}` `session.status`.
- Output `{"launchId","sessionId","status","error"}`.
- Exit status:
  - Timeout → exit 1, code `run_wait_timeout`; the body is still printed.
  - Terminal `failed` → exit 1, code `run_failed`; the body is printed.
  - Server codes that are safe-code shaped are passed through.

**`executions <identity> [--limit N]`**
- `GET /api/v1/instances/{id}/executions`. `--limit` defaults to 20, range 1...100.
- Output `{"identity","profile","items":[{"sessionId","status","startedAt","endedAt","updatedAt","currentStepId"}],"truncated"}`. `startedAt`/`endedAt` are null when absent (App 0.3.1).
- Re-encode the closed fields only. Never forward raw server JSON.

### Shared files (single owner: this plan)

- `Sources/RielaCLI/RielaClientFamilyArguments.swift`: add `reload`, `run` and `executions` to `InstanceClientSubcommand`. Do not touch any other enum.
- `Sources/RielaCLI/RielaCLIApplication.swift`: change only the `.instance(options)` case (line ~154) to `return await instanceCommandRunner.runAsync(options)`.
- `Sources/RielaCore/SurfaceCatalog+RowsCLI.swift`: in `instanceRows`, add rows `instance.reload` (mutation), `instance.run` (mutation) and `instance.executions` (query) with `cli: "instance reload"` etc.
  - GraphQL stays excluded: use the `instanceDefaults` exclusion with no `graphql:` argument. Inspect how a row without GraphQL is declared in the same file, e.g. the cache rows.
  - SurfaceParity tests must stay green. If they require a CLI options list, add the declared flags.
- `Sources/RielaCLI/RielaClientCommandRouter.swift`: edit only if `riela instance --help` does not list the new subcommands after the enum change. In that case edit only the `instance` route abstract/help entry.

## Key pitfalls

- **Test isolation.** `ScopedWorkflowInstanceStore(workingDirectory:)` reads the real home through the environment. Every new test must inject a temp `homeDirectory` / `environment` (HOME and RIELA_APP_ROOT pointing under `<cwd>/tmp/...`). Existing `Tests/RielaCLITests/WorkflowInstanceCommandTests.swift` cases that assert "not found" must not start finding real App instances.
  - Check whether those tests already isolate HOME. If one now fails only because of real-home leakage, fix that test's isolation (sharedPath note) without changing its intent.
- Never print environment values or the csrf token.
- The `Host` header is set by URLSession from the URL. Always use `127.0.0.1`, not `localhost`, for discovered endpoints: the App checks `Host == 127.0.0.1:<port>`.
- `run` must not send the `Origin` header on GET polls; on POSTs it is required.

## Tests

**Tests/RielaCLITests/InstanceIdentityNormalizationTests.swift (new)** — temp HOME containing `.riela/rielaapp/profiles/default/daemon-workflows.json`. Imitate the fixtures in `Tests/RielaCLITests/WorkflowInstanceCommandTests.swift`.

| Situation | Expected |
| --- | --- |
| `show configuration-abc` (App only) | exit 0, `scope:"app:default"` |
| Same identity in project and App | project wins |
| Identity in two profiles, no `--profile` | ambiguous error naming both |
| `--profile b` | resolves to b |
| `update`/`remove` on an App-only identity | usage error `instance_app_scope_read_only…`; no project `instances.json` created |
| `selected-workflow:/tmp/x` with `workflow.json` `{workflowId:"wf"}` | `workflowId` `wf` |

**Tests/RielaCLITests/InstanceAppCommandsTests.swift (new)** — injected transport recording requests, a temp app root, and a fake sleep.

Discovery:
| Situation | Expected |
| --- | --- |
| `web-server.json` port 19555 | `http://127.0.0.1:19555` |
| Missing file | 19091 |
| Corrupt file | 19091, and the file still exists unchanged (byte compare) |
| `--server http://10.0.0.1:1` | usage error |
| `active-profile.json` b | expected profile b |
| Bootstrap profile a vs expected b | `app_profile_conflict`, and only 1 request sent |

Request construction:
- reload sends `Origin`, `x-riela-csrf`, `x-riela-profile` and `content-type`, with body keys exactly the 5.
- A relative `--workflow-definition-dir` becomes absolute.
- run body keys are exactly 3.
- An identity with `/` is percent-encoded.

Argument validation:
- missing `--reason` → exit 2.
- `--limit 0` / `101` → exit 2.
- `--variables '[1]'` → exit 2.
- `--timeout-seconds 0` → exit 2.

Error mapping:
| Situation | Expected |
| --- | --- |
| reload 404 `{"error":"not_found"}` or code `not_found` | `app_reload_unsupported` |
| 404 `instance_not_found` | passes through |
| 409 `instance_run_in_flight` with `--wait-idle` | 2 retries then 200 → exit 0 |
| Retries beyond the timeout | `instance_run_in_flight`, exit 1 |
| 200 with `handoff:"lost"` | exit 1, `reload_handoff_lost`, body printed |
| 422 with `committed:true` | body printed, exit 1 |
| Unsafe code `"Bad Code!"` | `app_http_422` |
| Connection refused | `app_unreachable` |

Run polling:
- 202 with sessionId null → poll → sessionId (exit 0, no `--wait`).
- `--wait`: running → completed (exit 0).
- failed → `run_failed`.
- launch 404 → executions-detail fallback.
- timeout → `run_wait_timeout`.

Executions:
- `--limit 2` returns 2 items.
- Missing `startedAt` → null.
- Extra server fields are not forwarded.

## Invariants

- `riela environment` output and defaults are unchanged.
- `list` output is unchanged.
- project/user `show`/`update`/`remove` behave exactly as before.

## Verification (each exits 0; logs under the evidence root)

1. `mkdir -p tmp/instance-control/instance-control-04-cli-commands && arch -arm64 /bin/zsh -lc 'swift test --filter "InstanceIdentityNormalizationTests|InstanceAppCommandsTests|WorkflowInstanceCommandTests|SurfaceParityCLITests|SurfaceParitySkillTests" 2>&1 | tee tmp/instance-control/instance-control-04-cli-commands/test.log; exit ${pipestatus[1]}'` — 0 failures; the log shows each class ran.
2. `arch -arm64 /bin/zsh -lc 'swift build --product riela 2>&1 | tee tmp/instance-control/instance-control-04-cli-commands/build.log; exit ${pipestatus[1]}'`
3. `arch -arm64 /bin/zsh -lc '.build/debug/riela instance --help 2>&1 | tee tmp/instance-control/instance-control-04-cli-commands/help.log'` — the log lists reload, run and executions.
4. `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet Sources/RielaCLI/InstanceCommands.swift Sources/RielaCLI/InstanceAppCommands.swift Sources/RielaCLI/RielaAppAPIClient.swift Sources/RielaCLI/FileWorkflowInstanceStore.swift Tests/RielaCLITests/InstanceIdentityNormalizationTests.swift Tests/RielaCLITests/InstanceAppCommandsTests.swift 2>&1 | tee tmp/instance-control/instance-control-04-cli-commands/lint.log; exit ${pipestatus[1]}'`
5. A read-only live probe using the worktree binary:
   `arch -arm64 /bin/zsh -lc '.build/debug/riela instance list --output json > tmp/instance-control/instance-control-04-cli-commands/probe-list.json; .build/debug/riela instance show configuration-903fe205-9c44-404f-9b4a-97c101422380 --output json > tmp/instance-control/instance-control-04-cli-commands/probe-show.json; echo show-exit=$?'`
   - Record the exit codes. The expected result is that show succeeds.
   - Do not run reload or run against the live App. `executions` may be probed; `app_unreachable` is an acceptable, explained result.

## Edit safety

- Fresh-read every file before editing, and record the pre- and post-edit sha256.
- For shared files, apply only the noted one-line or row edits.
- On drift, re-apply only those edits.

## Completion criteria

- [ ] All commands exist and appear in help.
- [ ] Tests 1 pass, and builds/lint exit 0.
- [ ] The probe results are recorded.
- [ ] No writes under `~/.riela`.

## Progress Log

### Session: 2026-11-10
Plan authored (Opus). Not started.
