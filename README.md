# Riela — put your AI agents on rails

**Riela turns Codex, Claude Code, Cursor and API models into a team that follows
your process.** You draw the workflow — design, implement, review, fix, ship —
and Riela runs it step by step: the right agent for each step, every result
recorded, any run resumable, and the whole thing testable before you spend a
token.

<p align="center">
  <img src="img/riela.png" alt="Riela logo with a railway track mark on a black background" width="480">
</p>

```bash
brew tap tacogips/tap && brew install --cask riela   # RielaApp + riela CLI (macOS)
riela workflow run <workflow> --variables '{"task": "..."}'
```

## What you can do with Riela

- **Chain agents into real pipelines.** Mix Codex, Claude Code, Cursor, OpenAI /
  Anthropic / Gemini SDK workers, shell commands and containers in one workflow,
  with branching, fan-out/fan-in, review loops and manager/worker routing.
- **Never lose a run.** The runtime owns every session, step execution, message
  and output. Resume, continue, rerun or replay from any step, and trace what
  each agent saw and returned.
- **Test before you pay.** Mock scenarios run whole workflows deterministically;
  output contracts are checked before and after every step.
- **Trigger work from anywhere.** Run from the CLI, the RielaApp menu-bar app and
  web console, a GraphQL control plane, or let Telegram, Discord, Slack,
  webhooks, cron schedules and file changes start workflows for you.
- **Connect your tools.** Built-in add-ons for Gmail, Google Docs / Sheets /
  Analytics, Wrike, X, Apple Notes and notifications, document-to-Markdown
  conversion, key-value state, workflow memory and kaiba long-term notes.
- **Edit, share and scale.** Edit workflows as graphs in the app, publish and
  install them as packages, run recurring routines, and spread steps across
  distributed workers.

## How Riela differs from Hermes Agent and OpenClaw

[Hermes Agent](https://github.com/NousResearch/hermes-agent) and
[OpenClaw](https://github.com/openclaw/openclaw) are autonomous assistants: one
agent lives in your chats, decides what to do next, and grows its own skills
and memory. Riela takes the other side of the trade-off: **you decide the
process, and Riela makes many agents follow it reliably.**

| | Riela | Hermes Agent | OpenClaw |
| --- | --- | --- | --- |
| What it is | Workflow runtime that orchestrates many agents | Self-improving personal agent | Personal AI assistant in your chat apps and devices |
| Who picks the next step | Your workflow graph — explicit and reviewable | The agent's own loop and learned skills | The assistant's own loop, skills and plugins |
| Which AI does the work | Existing coding agents (Codex, Claude Code, Cursor) and API models, chosen per step | Its own agent on your chosen model | Its own agent on hosted or local models |
| Reproducibility | Every step recorded; resume / rerun / replay; deterministic mock runs | Session search and persistent memory | Sessions managed by its local gateway |
| How it improves | Workflow changes you review (reviewed self-improve flows) | Creates and patches its own skills | Skills and plugins from its ecosystem |
| Best for | Repeatable multi-agent work: dev loops, reviews, scheduled and chat-triggered pipelines | An agent that learns you over time | An always-on assistant across chats and devices |
| Built with | Swift; native macOS app, CLI on macOS and Linux | Python / JavaScript | Node.js / TypeScript |

They are complementary: keep a conversational assistant for open-ended help,
and use Riela when the work has to follow the same steps every time, across
several agents, with a record you can audit and rerun.

## Naming

The public executable is `riela`. The Swift module names still use
`Riela*` and workflow package manifests still use `riela-package.json`
for compatibility with existing workflow bundles.

## Swift Runtime Coverage

The Swift CLI owns the production command surface for local workflow execution,
session inspection, workflow packages, event sources, hooks, GraphQL/server
control-plane commands, direct `call-step`/`workflow-call` execution,
task-backed Work Runtime dispatch, and reviewed `workflow self-improve`
mutation flows.

Client command routing, subcommand validation, positional arguments, and typed
option parsing use Apple's `swift-argument-parser`. Existing command names,
aliases, defaults, and output contracts remain stable behind the typed routes.

Runtime-owned records stay in the Swift session and runtime stores. Workers and
adapters return candidate outputs only; session ids, step execution ids,
workflow message ids, output publication, root output selection, continuation,
resume, rerun, replay, and GraphQL/session DTO projection are runtime-owned.

Authored [node output contracts](docs/output-contracts.md) are checked before
execution and included in agent instructions. The guide describes the supported
JSON Schema dialect and how payload contracts interact with routing envelopes.

A transition with `dynamicWorkflow` lets a brain node return an inline workflow
definition. The runtime checks it against a deny-by-default allowlist and size
limits, runs it as a child session linked to its parent and root sessions, and
sends back one `dynamicWorkflowResult` message. This repeats until the brain
returns `finish` or the loop reaches `maxIterations`. See the
[brain-generated workflow loop guide](docs/workflows/brain-generated-workflow-loop.md)
and the `examples/brain-generated-workflow-loop` mock-scenario example.

For failed sequential agent workflows, [history-preserving recovery](docs/preserved-history-recovery.md)
reuses accepted discussion without rerunning earlier agents and records explicit
source lineage in the new session. A plain `riela session rerun SESSION STEP`
also carries the source's accepted inbox state as of the target's latest
execution into the new session: the target's recorded inbox plus the messages
every step reachable from it had received, so a loop back-edge (for example
`integration-review` returning to `dispatch-plans`) still finds its checkpoint
message. It rejects missing or unaccepted inbox evidence, and created or running
sources whose evidence would be carried, before creating a session.
`riela session resume SESSION --retry-failed-step` also accepts a step that
failed with a node timeout. Step reruns of the protected git-finalization
workflow bind the latest accepted commit/push/mode evidence or reject in
preflight with a recovery path; see the same guide.

Fanout change evidence accepts explicit repository-relative file or directory
`writePaths`, including paths that do not exist yet. Directory snapshots include
hidden descendants and empty directories. At reduce, Riela re-enumerates the
declared roots and reports added or removed entries, kind changes, directory
membership changes, and content or mode changes with path and branch attribution.
Selections reject traversal, Git metadata, symlinks, special or unreadable
entries. Each capture or reduce allows 1–512 declared paths, at most 512 unique
expanded entries, 8,000,000 bytes per file, and 64,000,000 total file bytes.
Snapshots occur at workflow node boundaries, so writes that begin and end
within one agent invocation may not appear in the evidence.

Local command invocations reject an already-expired deadline or pre-existing task
cancellation before dispatch. Cancellation racing with spawn uses the owned
process-group cleanup; commands are never automatically replayed.
Local command nodes run foreground work: their process group is reclaimed when
the command leader exits, including background children that retain its pipes.
Foreground exit status and captured logs remain available. Commands must not
escape that group with `setsid`, `setpgid`, or daemonization. CLI-agent turns
also receive a foreground-only instruction and await executor/ACP cleanup.
The embedded agent-gateway now exposes an injectable process runner and its
built-in runner atomically owns and drains the foreground process group before
publishing a terminal result. It advertises that capability explicitly and
rejects an `allDescendants` requirement before spawn; callers needing escaped
daemon containment must inject a runner that provides it. Do not detach
aggregate tests inside AI nodes; retain tool-session handles until terminal
exit and record complete logs. Long-lived services need an explicitly owned
service/workflow lifecycle.

Fresh workflow runs seed ID high-water marks from compact SQLite identity projections
without loading unrelated session outputs or message payloads into their execution
cache. Projections are updated with snapshot writes; database triggers invalidate them
when an older writer replaces a snapshot. Existing stores need a one-time ID-only
backfill, after which startup reads small projections and covering ID indexes.
Missing trigger lineage rebuilds the projection, while unsupported projection
versions fail closed. This changes neither session reservations nor stored payloads.
`riela session resume`, `riela session rerun` and `riela workflow run --resume`
load only the target's session family (the target plus sessions that share its
root session id), not the whole persisted store. On large stores they now emit
their first JSONL event promptly. Existing session records and execution locks
remain authoritative.

The default SQLite session-store connections wait for another process to
release its database lock, including during WAL initialization. Parallel runs
can share a session store without a fixed three-second contention timeout.
An interrupted process releases its OS locks; stop a waiting CLI process with
Ctrl-C if you do not want to wait for a long-running owner. Library callers can
request bounded waiting with `SQLiteOpenOptions(busyTimeoutMilliseconds: ...)`.
Only lock acquisition and WAL initialization are retried; workflow actions and
transaction bodies are not replayed.

Every workflow session entered through the production local CLI, library, or
GraphQL surfaces also holds a session-store-scoped advisory lock for its full
execution lifetime. A concurrent `session resume` or `session continue` for
that session fails before any node effect starts. The operating system
releases the lock when its owner exits, so an interrupted session can be
resumed without waiting for a stale heartbeat timeout. Different session IDs
remain independently executable.

Graceful cancellation (SIGINT/SIGTERM or host task cancellation) now records
the session and step status as `cancelled`, with `failureKind: cancelled`. The
CLI still exits with code 1. A cancelled session can be rerun but not resumed.
When the host cancels an agent-gateway turn, Riela reports a cancellation, not
a provider, authentication or policy failure. If a runner is hard-killed, its
sessions can be left `running`. `riela session reconcile` lists them (dry run
by default), and `--apply` marks them cancelled. Sessions whose execution lock
is still held are never changed. See
[session cancellation and reconciliation](docs/session-cancellation-and-reconcile.md).

Installed workflow packages are local workflow sources. After
`riela package install <name>`, package-provided workflows appear in
`riela workflow list` and can be used with ordinary workflow commands such as
`riela workflow validate <name>`, `riela workflow inspect <name>`, and
`riela workflow run <name>`. `workflow run --from-registry` is only for
registry-backed execution without a prior local install. Workflow command JSON
includes provenance fields such as `sourceKind`, `packageName`,
`packageDirectory`, and `mutable` so package-derived workflows can be treated as
installed, read-only artifacts.

Validated authored workflows can also be registered as persistent user-scoped
mutable workflows:

```bash
riela workflow register ./path/to/workflow-bundle --mutable
riela workflow list mutable-name --output table
riela workflow validate mutable-name
riela workflow deactivate mutable-name
riela workflow activate mutable-name
riela workflow run mutable-name --mock-scenario ./path/to/mock.json
```

Registration accepts a standalone workflow JSON file or a bundle directory,
copies it under `~/.riela/temporary-workflows/<workflowId>/`, and requires
`--overwrite` to replace an existing entry. Public results use
`provenance: "mutable"`, `mutable: true`, and `activationState`.
Name resolution considers mutable entries after
project workflows, user workflows, project packages, and user packages.
Project, user, and installed-package workflows have immutable provenance:
they remain readable but update/delete operations return
`IMMUTABLE_WORKFLOW`. Either provenance can be deactivated; deactivated
origins remain listable and inspectable but execution returns
`WORKFLOW_DEACTIVATED`. The additive GraphQL registry surface provides list,
fetch, mutable CRUD, activation, and consolidation. `riela serve` also receives
ordinary remote workflow runs through the separate `executeWorkflow` mutation
and `workflowExecution` summary query. Registry writes keep their own
authorization; an execution bearer does not grant registry write access.

For installed package workflows, `riela workflow validate` and `inspect` keep
the owning package's locked native, container, or local-command add-on metadata
when selecting by package ID, workflow name, or the manifest-declared installed
workflow directory. The package root is not a workflow directory. A dependency
resolves only when the installed package, selected-scope lockfile, add-on
identity, version, registry, digest, and explicit execution kind agree. An
installed local-command add-on also needs an executable entrypoint contained in
its package. Validation and inspection expose its canonical executable and
required environment as host requirements; remote hosts must satisfy those
requirements independently. Unknown or ambiguous add-ons, copied workflows,
missing execution kinds, and cross-scope substitutions remain unresolved.
Validation checks package integrity and host readiness without executing the
add-on. See [issue #117](https://github.com/tacogips/riela/issues/117), the
[native/container plan](impl-plans/completed/issue-117-installed-addon-metadata.md),
and the [local-command plan](impl-plans/completed/issue-117-installed-local-command.md).

Local agent backend ids remain explicit workflow compatibility contracts:
`codex-agent`, `claude-code-agent`, and `cursor-cli-agent`. They no longer name
Riela-owned executables or targets. The `official/*` backend ids are also
compatibility selectors; every one is dispatched through `agent-gateway`.

### Web workflow studio

In RielaApp's web **Command deck**, choose **Create / edit workflow** to open
the graph editor. Node positions and the camera are stored separately in
browser-local storage, scoped by profile and workflow origin; moving a node
does not change the executable workflow or its saved revision.

Existing inline agent nodes expose prompt/model settings in the inspector.
Other protected configuration stays opaque, and hidden prompt/model values
are retained unless explicitly replaced. Save refreshes the canonical revision
and protected-value handles, preserving the canvas and chat while resetting
Undo/Redo history. If that refresh fails, use **Reload saved workflow** before
another save or execution. A save conflict keeps the draft until you explicitly
confirm reloading.

For a saved file-backed agent node, choose **Edit file-backed node settings**.
Its dialog loads the prompt (including a referenced prompt file) and model.
**Save node settings** preserves other payload fields and creates a
content-addressed node file, updating the workflow reference in the same
registry transaction. Original node/prompt resources are retained. Both the
workflow revision and the loaded asset digest must still match, so an external
file edit cannot be silently overwritten. Prompt whitespace is preserved.

Save the graph, activate the workflow if necessary, then enter an absolute
execution working directory and an input JSON object under **Run saved
workflow**. **Run workflow** executes that exact saved revision and opens its
session in **Run logs and values** on the same page. Unsaved edits must be
saved before execution. You can also open an existing run by session ID.

Select a graph step or an execution attempt to inspect its recorded input,
accepted output, agent response text and failure details. Attempts remain
separate, including retries. Old sessions without input snapshots explicitly
show “not recorded”; values are not reconstructed from today's definition.
The inspector shows the latest 500 attempts and refuses values above 512 KiB
with an explicit export instruction. Actual values may contain sensitive
workflow data, although process environment credentials are not copied into
input snapshots. Logs from another workflow remain readable without applying
their statuses to the current graph.

Agent chat applies generated edits to the canvas as drafts. It uses bounded
incremental provider rounds so intermediate graphs appear even when a vendor
buffers its replies, and includes recent chat context for follow-up requests.
Stop generation and Undo remain available; publishing still requires Save.

See
[the design](design-docs/specs/design-workflow-graph-studio.md) and
[implementation plan](impl-plans/completed/workflow-graph-studio.md), with
[acceptance evidence](design-docs/user-qa/qa-workflow-graph-studio.md).

Production execution for Claude Code, Codex, Cursor CLI, Cursor Cloud Agents,
OpenAI, Anthropic, Gemini, and OpenRouter is supplied by the sibling
`agent-gateway` package, which speaks the Agent Client Protocol (ACP,
https://agentclientprotocol.com). Riela links that package as a **library**
and hosts its ACP agent inside the `riela` process: the agent and an ACP
client are connected over an in-memory transport, so no `agent-gateway`
executable is spawned and none has to be installed. The only child process a
step creates is the vendor CLI itself (`claude`, `codex`, `cursor-agent`);
API vendors make HTTP requests from the riela process.

Each step is one ACP prompt turn: the prompt travels as ACP content blocks,
streaming output arrives as `session/update` notifications
(`agent_message_chunk`, `agent_thought_chunk`, tool call updates), and the
`session/prompt` response carries the final text, usage, and resumable vendor
session id in `_meta.agentGateway`. A step's `agentEnvironment` is applied to
that turn only — it reaches the vendor process without ever being written into
riela's own environment, so concurrent steps with different credentials cannot
collide. A step deadline cancels the ACP turn, which terminates the vendor
process group.

RielaApp also uses agent-gateway's model catalog when the Assistant settings
select OpenAI API, Claude API, or Cursor API. The live vendor response replaces
the bundled suggestions for that settings session. Missing credentials,
listing failures, empty responses, and CLI-backed vendors fall back to the
bundled catalog, and an already selected live model remains usable after it is
saved.

RielaApp is a resident workflow process; its HTTP listener is optional and is
disabled by default. **Open Console...** opens the Tauri dashboard through native
IPC. **Start server** in the console's Settings → Web Config server starts the
loopback listener explicitly; stopping that listener does not stop RielaApp or
its workflow instances.
This is intentionally different from bare `riela serve`, whose process exists
to host an HTTP server and stays alive until SIGINT or SIGTERM. All other
`riela` commands remain one-shot and read or update their configuration files
directly without depending on either HTTP process.

Persisted RielaApp configuration is edited only in Web Config. The local
GraphQL `configuration` query and typed configuration mutations cover assistant
models, appearance, the optional RielaApp-hosted server, profiles, workflow
directories, instance environment/default variables, and event sources. The
configuration result includes the RielaApp state plus its server section. The
legacy REST settings and configuration-write routes are not exposed.

Provider validation and Base URL routing for `codex-agent` and
`claude-code-agent` are also supplied by `agent-gateway`.
For OpenRouter, use `https://openrouter.ai/api/v1` with Codex Agent and
`https://openrouter.ai/api` with Claude Code. Set `apiKeyEnv` to
`OPENROUTER_API_KEY`; Riela resolves the value only at launch and does not put
it in command arguments or workflow artifacts. Claude Code routing also clears
`ANTHROPIC_API_KEY` so it cannot override `ANTHROPIC_AUTH_TOKEN`.

Riela-owned environment names use the `RIELA_` prefix. In the Mac app's
**Settings → API Keys**, issue a **Client API** key, optionally set an expiration,
and copy the key when it is shown. Store that value securely on the client and
set `RIELA_API_KEY` (or select an environment variable with `--auth-token-env`).
The server no longer uses `RIELA_MANAGER_AUTH_TOKEN`.

**Require an API key for client requests** defaults on. Turning it off admits
clients without a key; invalid, expired or revoked supplied keys still fail.
Worker keys always require authentication and bind to a configured worker ID.
Key hashes and policy persist under `~/.riela/rielaapp/api-auth`; app restarts do
not invalidate keys. The Mac app's custom app root uses its own `api-auth` directory.
Key management is available only through the local desktop window. API keys do
not grant access to key administration. See [API key management](docs/api-keys.md).

Both the Mac app's optional loopback server and `riela serve` accept client keys.
CLI hosting uses the same default store on the same OS account. With the issued
key already set in the client environment:

```bash
riela workflow run my-workflow --endpoint https://riela.example/graphql --output json
```

The client also accepts `--auth-token` or `--auth-token-env`. The server uses
its selected working directory and session store for both the run and the
following summary read; request input cannot choose either path. The mutation
waits for a persisted result and reports the actual status and exit code,
including a failed run. A client or proxy timeout can precede completion, and
retrying then can start a second run. `--from-registry`, `--mock-scenario`,
and `--supervisor-mode` are unsupported for this remote run.

Codex multi-agent supervisor mode is also opt-in. Riela explicitly disables the
Codex `multi_agent` feature for ordinary local workflow runs, regardless of the
user's global Codex configuration. Pass `--supervisor-mode` to
`riela workflow run` to enable it for that run. This option is currently local-only.

CLI commands default to JSONL so automation can read one complete JSON record
per line. Most commands emit a single JSONL record. `riela workflow run` emits
progress records such as `session_started`, `step_started`, and
`step_completed` before the final `run_result`, so callers can capture the
session id immediately and inspect it while the run is still active. Automation,
agents, and LLM-driven tool use should prefer `--output jsonl`, especially for
`workflow run`. Package commands are the exception: they default to text for
interactive package creation and import flows. Use `--output json` only when a
legacy caller explicitly needs a single non-streaming JSON document after
completion.

## Built-in Git Workflow Finalization

`riela/git-commit@1` and `riela/git-push@1` are opt-in workflow add-ons for
reviewed repository finalization. Merely selecting an add-on does not authorize
the mutation: a commit node must set `config.allowCommit: true`, and a push node
must independently set `config.allowPush: true`. Commit input includes a
bounded message and an ordered, unique list of exact repository-relative files;
directories, repository escapes, `.git` paths, custom clean filters, and
pre-existing staged paths outside that list are rejected. Unstaged and
untracked files outside the list remain untouched.

Commit preparation uses an isolated index and a runtime-owned crash journal
outside the repository. Publication compares the recorded branch state, never
removes a foreign Git index lock, and supports evidence-backed idempotent retry.
Successful commit output reports `operation`, `status`, the full `commitHash`,
the accepted `commitMessage`, and `committedFiles` in their authored order.

Push requires `expectedCommitHashTemplate` to resolve to the accepted commit
hash and requires the current `HEAD` to equal it. Version 1 accepts a named
branch only when its configured upstream is the same branch, validates the live
remote tip, and permits at most the single accepted unpublished commit. It uses
a non-force push and verifies the live remote again before reporting `pushed`
or `already-pushed`. Successful output includes the validated remote name and
branch, never the remote URL or credentials.

For GitHub HTTPS remotes, push can use the operator's URL-matched Homebrew
`gh auth git-credential` helper when its command and executable match the
strict allowlist. The isolated transport still disables system/global Git
configuration; only the GitHub CLI's user authentication context is restored
for that transport. Other credential-helper snippets remain rejected. A failed
push reports the transport stage and exit code without exposing Git output.

Production invokes only the trusted system Git at `/usr/bin/git` with argument
arrays, a minimal environment, disabled hooks/signing/prompts, and bounded
diagnostics; it never searches `PATH` or evaluates a shell command. Version 1
supports validated HTTPS and SSH network transports but rejects local/file and
external-helper transports. Additional Git installations, credential-helper
locations, or transport policies require a new explicitly tested runtime
policy version.

## Google Service Usage Add-ons

`riela/google-service-gateway-read@1` and
`riela/google-service-gateway-write@1` import the sibling
`GoogleServiceGatewayCore` Swift library directly, the same way the local
gateway add-ons below do. The read add-on supports
`services.list`, `services.get`, and `operations.get`; the write add-on supports
`services.enable`, `services.disable`, and `services.batchEnable`. Set the
operation in `addon.config.operation` and pass request fields through
`addon.inputs`.

Credentials require an explicit `addon.env.GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN`
binding. Ambient process credentials are not forwarded implicitly, and the
read add-on cannot invoke a mutation.

## Local Gateway Add-ons

Four add-on families bridge to sibling gateway packages. Riela links each
gateway as a **library** and calls it inside the `riela` process: no gateway
executable is spawned, and none has to be installed. There is consequently no
`addon.config.binaryPath` and no per-tier `*_BIN` environment fallback.

Each add-on still pins one capability tier. With the gateway linked rather than
launched, the boundary is the role and capability list the add-on hands the
gateway's own registry — which refuses a document or command naming a
capability outside that tier — instead of which binary was on `PATH`. A
workflow cannot widen the tier through inputs or payload data either way. The
add-on payload reports the tier that answered under
`<namespace>.runtime.tier` (the old `<namespace>.binary.path` is gone, since
there is no binary).

A gateway sees only the sanitized ambient allowlist (`HOME`, `PATH`, `LANG`,
`TMPDIR`, …) plus exactly the `addon.env` bindings its contract declares —
the same environment it saw as a child process. Nothing is written into
riela's own environment, so concurrent steps with different credentials do not
collide.

- `riela/wrike-gateway-read@1`, `-write@1`, and `-admin@1` run wrike-gateway's
  GraphQL runtime with a rendered `config.queryTemplate` plus optional
  `variablesTemplate` / `selectFirst` / `whenFlags` / `payloadExtras`. Allowed
  `addon.env` targets are the five `WRIKE_GATEWAY_*` credential variables.
- `riela/gmail-gateway-reader@1`, `riela/gmail-gateway-draft@1`, and
  `riela/gmail-gateway-sender@1` run gmail-gateway's GraphQL surface in the
  matching mode. gmail-gateway rejects GraphQL variables, so values render into
  the document text and `config.variablesTemplate` is refused. Allowed
  `addon.env` targets are `GMAIL_GATEWAY_CONFIG`,
  `GMAIL_GATEWAY_CREDENTIAL_DIR`, and the
  `GMAIL_GATEWAY_CREDENTIAL_<SUFFIX>_{OAUTH_CLIENT_SECRET,TOKEN_STORE}_{PATH,JSON}`
  credential shapes. (Distinct from the container-backed
  `riela/gmail-gateway-read` / `riela/gmail-gateway` add-ons.)
- `riela/google-analytics-gateway-read@1`, `-write@1`, and `-admin@1` run
  google-analytics-gateway's GraphQL runtime (GA4 Admin/Data plus Tag Manager)
  with the same `queryTemplate` contract as wrike. Allowed `addon.env` targets
  are `GOOGLE_ANALYTICS_GATEWAY_ACCESS_TOKEN` and
  `GOOGLE_ANALYTICS_GATEWAY_CONFIG`.
- `riela/google-docs-gateway-read@1`/`-write@1`,
  `riela/google-sheet-gateway-read@1`/`-write@1`, and
  `riela/google-drive-gateway-read@1`/`-write@1` run the six
  google-documents-gateway roles. That gateway is not GraphQL, so the config is
  `command` (one or two literal words) plus `argsTemplate` (flag map bound as
  `--flag=value`); `auth login` and `auth revoke` are refused. Allowed
  `addon.env` targets are exactly the five
  `GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_<ROLE>_*` variables of the add-on's own
  role, plus `GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DIR`.

`riela workflow validate` checks built-in gateway JSON `operation` requests with
the same checker the runtime uses. It covers the catalog-backed gateways, both X
readers (`riela/x-gateway-reader` and container `riela/x-gateway-read`),
`riela/gmail-gateway-read`, Google Service read/write and nested `kaiba/*`
arguments, and checks argument names against the catalog when the SDK catalog
is available. It rejects an operation mixed with legacy request keys, a
non-literal or malformed operation/selection, Gmail `variablesTemplate`
passthrough, an invalid non-templated `config.postprocess` program, and an
unknown catalog or X SDL operation. Templated argument values are only
key-checked statically. `riela workflow run` reports the same findings as
non-blocking `warning:` lines on stderr. `inspect`, the registry and the server
do not apply these checks. Aliases and legacy modes, including the X nested
`select` form, stay valid.

X readers also accept `providerFailure: "output"`. A recognized provider
failure then completes with `xGateway.failure.{category,retryable}` and the
`providerFailed` / `providerRetryable` / `spendCapReached` / `rateLimited`
`when` flags, so the workflow can branch on it. Riela never retries the call.
See [built-in gateway JSON requests](docs/builtin-gateway-json.md) for the
matrix, the cases that remain runtime-only, and the script-free
[X](examples/x-gateway-json-search/README.md),
[Notion](examples/notion-gateway-json-sync/README.md) and
[Gmail](examples/builtin-gateway-json/README.md) examples.

### Native command outcomes

`riela/command-result@1` captures a bounded command outcome as JSON for
collect-all fanout, with optional schema projection before persistence and
trusted owner cancellation. See [command results](docs/workflows/command-result.md).

### Notion pages and images

`riela/notion-gateway-read@1` and `riela/notion-gateway-write@1` call the linked
Notion SDK with fixed reader/writer roles. Use `config.queryTemplate` and
`config.variablesTemplate`; native Notion JSON, pagination and truncation flags
remain in `payload.data`. Bind the credential explicitly with
`addon.env: {"NOTION_API_KEY": {"fromEnv": "NOTION_API_KEY"}}`; ambient unrelated credentials
are excluded. Reader mutations are rejected before credentials or transport.

`riela gateway notion --role reader|writer ...` delegates the gateway's native
CLI commands, including `schema`, `graphql`, `page` and `block`; reader is the
default. Supply `NOTION_API_KEY` from the caller environment, for example through
`kinko exec --env NOTION_API_KEY --`. For `node run`, pass the same binding via `--env '{"NOTION_API_KEY":{"fromEnv":"NOTION_API_KEY"}}'`.
No external gateway executable is launched.
Writes are never automatically replayed: retain native IDs and reconcile an
uncertain result before retrying. The integration must be connected to each
chosen parent page; gateway installation does not grant access to existing pages.

### Apple permissions

The apple-gateway add-ons are linked the same way, which moves one thing that
is not just an implementation detail. macOS attaches Apple Events, Calendars,
Reminders, and Contacts permission grants to the executable that asks, so the
asker is now `riela` (bundle id `me.tacogips.riela`, usage strings in
`Resources/RielaInfo.plist`) rather than a separate `apple-gateway` binary.
**Grants previously given to `apple-gateway` do not carry over** — the first
Apple add-on step prompts again, and a headless `riela` cannot answer a prompt,
so approve it once from an interactive run before relying on it in a daemon.
`addon.config.binaryPath` and `APPLE_GATEWAY_BIN` are gone with the executable
and a leftover `binaryPath` is refused rather than ignored.

A step deadline is checked before each gateway call. A linked call already
under way cannot be killed the way the child process could, so a step whose
deadline passes mid-call fails when that call returns.

## Session Observability

Session observers open the runtime store read-only and never create, migrate,
lock, or update it. Checkpointed stores without WAL/SHM sidecars use SQLite's
immutable read-only mode; live WAL stores retain the normal read-only snapshot
path. Use one-shot progress for a compact digest or follow a live writer with a
two-second default polling interval:

```bash
riela session progress <session-id> --output text
riela session progress <session-id> --follow --output text
riela session progress <session-id> --follow --poll-interval 0.5 --output jsonl
```

`--poll-interval` accepts finite values from `0.1` through `3600` seconds.
Follow emits every refresh, including unchanged state, and exits after its
terminal digest. Streaming structured output is JSONL; `--follow --output json`
is rejected.

Cross-workflow children persist `parentSessionId` and `rootSessionId` on their
first writer-owned snapshot. Inspect the complete running or completed tree and
list its relationships with:

```bash
riela session progress <parent-session-id> --include-children --output json
riela session progress <parent-session-id> --include-children --follow --output jsonl
riela session list --output table
```

`--include-children` follow waits until the requested session and every
discovered descendant are terminal. Legacy sessions without provenance remain
standalone. Rollup refreshes decode at most 1,000 snapshots. Structured output
reports `rollupTruncated` and `rollupSnapshotLimit`; text output prints the same
fields before the tree so an intentionally bounded view is never mistaken for
the complete tree. If a terminal-looking follow refresh is truncated, the
command emits that refresh and exits nonzero instead of claiming the complete
tree is terminal.

Backend health is evidence-based:

```bash
riela session health <session-id> --output json
```

`backendActivity` is `active`, `quiet`, `stalled-suspect`, or `unknown` and
includes activity evidence plus the active and stalled thresholds. Codex uses
uniquely correlated rollout freshness; Claude Code uses persisted stream-event
recency and a uniquely correlated artifact when available. Missing, unreadable,
or ambiguous artifacts produce `unknown` when no other sufficient correlated
evidence exists. A stalled-suspect verdict is an observation signal, not
remediation or proof of deadlock. Provider fallback correlation inspects at
most 200 launch-window candidates and returns `unknown` if that limit is
exceeded; native session ids use targeted SQLite lookup.

### Agent prompt size limits

Agent requests are measured before invocation as the UTF-8 byte count of
`systemPromptText` plus the larger of the fresh and resumed `promptText`.
The agent node payload field `promptMaxBytes` overrides the workflow default
`defaults.agentPromptMaxBytes`; both must be positive integers and fall back to
400,000 bytes. Fanout `changeTracking.observationInlineLimit` defaults to 200
and accepts 0 through 10,000 aggregated observations. Workflow excerpt (other
step and fanout fields omitted):

```json
{
  "defaults": { "agentPromptMaxBytes": 600000 },
  "steps": [
    {
      "id": "dispatch",
      "transitions": [
        {
          "toStepId": "branch",
          "fanout": {
            "joinStepId": "join",
            "changeTracking": {
              "pathsFrom": "/trackedPaths",
              "observationInlineLimit": 50
            }
          }
        }
      ]
    }
  ]
}
```

A single agent node can set its own budget in its node payload, for example
`"promptMaxBytes": 800000`.

The runtime variables block renders upstream message payloads once. In that
JSON, `$rielaElidedKeys` lists payload keys whose values are already present at
the top level, and `_rielaInput.latest.payload` is replaced by a `$rielaSameAs`
JSON pointer to the last `_rielaInput.messages[]` payload. These markers retain
the values without repeating their full JSON text. Prompt templates still
render from the original, unmodified variables.

If the composed prompt exceeds its byte budget, values of at least 4,096 bytes
are written losslessly under
`<working-directory>/tmp/riela-prompt-spill/<sessionId>/<stepId>/` as
content-addressed `<sha256>.json` files. The prompt receives a stub containing
`$rielaSpilled`, `pointer`, `path`, `bytes`, `sha256`, and a `preview` of up to
256 characters. The agent can read the referenced file. Spilling is limited to local CLI agent nodes with default tool arguments and
no OS sandbox or distributed placement. SDK, isolated and custom-tool nodes
retain inline data and fail with `promptTooLarge` when over budget, since access
to a host spill file is not guaranteed. If compaction cannot fit the budget,
the step fails before the backend is called.

When a prompt is compacted or rejected, its execution `inputSnapshot` includes
`promptCompaction` with the budget, measured and final byte counts, outcome,
and spill records. Guard rejections use `failureKind: promptTooLarge`.
Provider errors containing `prompt is too long`, `context_length_exceeded`,
`maximum context length`, or `request_too_large` receive the same failure kind.
The existing `riela session resume <id> --retry-failed-step` and
`rerunOnAdapterFailure` recovery controls apply; raising the budget lets the
guard recompute on retry.

Fanout `changeEvidence` keeps a bounded inline `observations` list and reports
`observationCount`, `observationOccurrenceCount`, `inlineObservationCount`,
`observationsTruncated`, `observationsPath`, and
`observationCountsByBranch`. The complete aggregated list is stored at
`observationsPath`; `hasDrift` is derived from the total `observationCount`.

## Workflow Definition Store (service vs one-time runs)

Long-running service workflows use the SQLite definition store in the runtime
records database. The workflow files seed the store on first use; later file
edits do not replace a registered definition automatically. One-time
`riela workflow run` continues to read workflow files only and never reads or
writes definition rows.

| Execution | Definition source |
| --- | --- |
| GraphQL, RielaApp configured runs, events serve, cron, routines and daemon workflows | SQLite store, pinned per session |
| One-time `riela workflow run` | Workflow files only |

Inspect changes with `riela workflow definition history <workflow>` and
`riela workflow definition show <workflow>`. Apply an audited whole-workflow
change with `riela workflow definition update <workflow> --patch <file> --reason <reason>`.
Import file changes explicitly with `riela workflow definition import <workflow>`;
use `--force --reason <reason>` to replace a registered head. See the
[workflow definition store guide](docs/workflow-definition-store.md) for
prompt updates, restore, export, GraphQL fields and the improvement addons.

## Runtime Data Retention

Retention is off when no `retention` policy is configured. Configure results,
workflow messages and logs independently in `~/.riela/config.json` (project
`.riela/config.json` can override the user policy for project data):

```json
{
  "retention": {
    "automatic": true,
    "minIntervalMinutes": 60,
    "results": { "maxAgeDays": 30, "maxTotalBytes": "5GB" },
    "messages": { "maxAgeDays": 30 },
    "logs": { "maxAgeDays": 14, "maxTotalBytes": "1GB" }
  }
}
```

To keep all results and messages forever while limiting logs to 14 days and
1GB, use:

```json
{
  "retention": {
    "results": { "keepForever": true },
    "messages": { "keepForever": true },
    "logs": { "maxAgeDays": 14, "maxTotalBytes": "1GB" }
  }
}
```

`RIELA_RETENTION` supplies the complete policy as inline JSON and takes
precedence over both files. Project policy takes precedence over user policy
for the project target. `RIELA_RETENTION_AUTOMATIC=true|false|1|0` overrides
only the automatic switch. Automatic passes are throttled per target and run
after workflow run/resume/rerun/continue, inside `riela events serve` and
`riela serve`, and at RielaApp startup and periodically.

`automatic` defaults to `true` and `minIntervalMinutes` defaults to `60`, so the
keep-forever example above also prunes logs automatically. Byte caps accept
integers or sizes such as `500MB`, `5GB` (decimal) and `1GiB` (binary). Unknown
keys inside `retention` are errors. A failed automatic pass only prints a
`riela retention warning:` line on stderr. It never changes the workflow exit
code or stdout. `riela gc` exits `0` on success, `1` when a target fails or is
busy, and `2` on usage or configuration errors. Overriding a `keepForever`
category on the command line is a usage error.

The legacy `gc.retentionDays` and `RIELA_GC_RETENTION_DAYS` keys were removed.
Using them returns `gc.retentionDays was removed; configure "retention" (see
riela gc --help)`.

Preview and apply the same configured policy with `riela gc`:

```bash
riela gc --scope all --dry-run --output json
riela gc --results-max-age-days 30 --logs-max-total-bytes 1GB --scope user
```

The JSON report lists selected and removed counts/bytes, protected reasons,
cap status and database reclamation. Use `--session-store` or
`RIELA_SESSION_STORE` for an alternate session store. Large databases that use
SQLite's default `auto_vacuum=NONE` need a one-time conversion; run `riela gc`
when about twice the database size is available. Automatic passes defer this
conversion for databases larger than 64MiB. Automatic cleanup only removes
eligible terminal session families and directly managed log files. Unpaired
memory journals are retained. Authored workflows, packages, registries,
profiles, notes and user outputs are not retention targets. `riela session
prune` remains the explicit low-level command for caller-selected workflow
ids and artifact roots; see [terminal retention](docs/terminal-retention.md).

## Kaiba Notes (external note store)

The note subsystem formerly embedded here ("Riela Note") now lives in the
standalone [kaiba](https://github.com/tacogips/kaiba) package: a local-first
note store with notebooks, provenance-aware hierarchical tags, comments,
agent chat and note editing, links, file attachments (local/S3), FTS5 search,
a note GraphQL API, a `kaiba serve` web viewer, and API-key authentication
(`kaiba client issue`).

Riela accesses Kaiba only through the dependency-free first-party
`KaibaClient` HTTP(S) SDK. It never opens a Kaiba store, resolves a Kaiba
configuration file, or falls back to an in-process service. Riela keeps its
own short-term memory; Kaiba owns long-term notes and knowledge.

Configure a named server once, then use its stable ID in a node's
`addon.config.kaibaInstanceId`. If the field is absent, the enabled default is
used; an unknown, disabled, or missing ID fails before add-on transport. The
catalog stores only an environment-variable *name*, never a bearer value.

```text
riela kaiba instance add --name local --endpoint http://127.0.0.1:8787 \
  --unauthenticated --allow-insecure-http
riela kaiba instance test <instance-id>
riela kaiba instance list --output json
```

Use `list`, `show`, `add`, `update`, `remove`, `test`, and `set-default` under
`riela kaiba instance`. The RielaApp Kaiba settings surface uses the same
user-wide catalog and readiness policy. Remote HTTP and remote unauthenticated
servers require their explicit opt-ins. Do not put a token in workflow JSON,
CLI arguments, logs, or `instances.json`: supply it only through the named
process environment variable at runtime.

All existing Kaiba nodes use that resolution path:

- `kaiba/note-create`, `kaiba/note-update`, `kaiba/note-get`,
  `kaiba/note-search`, `kaiba/note-tag-search`,
  `kaiba/note-graph-neighbors`, `kaiba/note-chain`, `kaiba/note-tag-apply`,
  `kaiba/note-attach-file`, `kaiba/note-attachments`, `kaiba/note-memos`,
  `kaiba/note-comment-add`, `kaiba/notebook-ingest-pages`,
  `kaiba/document-import`, `kaiba/note-conversation-save`
- Long-term memory: `kaiba/memory-consolidate`, `kaiba/memory-recall`
- Arbitrary GraphQL: `kaiba/note-graphql-document` and
  `kaiba/note-graphql-remote`

`noteRoot`, `databasePath`, `configPath`, `KAIBA_NOTE_ROOT`, and
`RIELA_NOTE_ROOT` are inert legacy inputs. They cannot select a server. Legacy
remote connection fields are assertions only and fail on a mismatch.

`kaiba/document-import` reads a bounded local source path (normally a
file-change input), sends the original as an inline attachment, and imports
caller-supplied pages or UTF-8 text over HTTP. Non-text conversion/OCR and
translation are caller-owned preparation inputs; the HTTP add-on refuses
unsupported server-local paths, S3 routing, and configuration-derived
conversion. This keeps document content and credentials on the caller side of
the API boundary.

`kaiba/note-tag-search` performs tag-only retrieval without requiring an FTS
query. `kaiba/note-chain` returns bounded graph paths. Attachments include a
stable `s3URL` locator (`s3://bucket/key`) when stored in S3; it is deliberately
not a public or signed download URL. `kaiba/note-memos` returns all Kaiba note
comments plus an `agentMemos` subset based on the stored author.

For operations not covered by a convenience addon, use
`kaiba/note-graphql-document`. Put the GraphQL document in `config.query` and
the AI-produced parameters in `addon.inputs.variables`; JSON templates retain
the variables' JSON types. The reference bundle
`examples/kaiba-document-intake` shows directory intake and GraphQL retrieval.


## Temporary retrieval cache

Pending retrievals can opt into capacity protection with `protectFromEviction: true`
on each `cache put --entries-file` entry. Protected entries still count against the
shared budget; every writer and policy shrink respects protection and rejects an
operation atomically when protected data plus the incoming batch cannot fit.
`stats.protectedByteCount` reports the exact protected charged bytes. Replacement
puts preserve existing protection, including older callers that omit the flag.
After a durable export receipt is verified, release protection without deleting:
`riela cache protect CACHE --scope S --entries-file -` accepts an array such as
`[{"key":"post","revision":"<current SHA256>","protectFromEviction":false}]`.
Use `true` to protect an existing current revision. The entire batch (up to 1024
keys) fails on missing, expired, or changed revisions. Protection/release does not
touch LRU order, content revision, or fetchedAt. Released entries remain reusable
until normal TTL/LRU eviction. **Capacity protection does not override TTL**:
expired pending payloads require repair or a fail-closed stop before advancing a
checkpoint. Protect body and image entries separately. This uses cache schema 2;
stop older shared-cache callers before migration, since older CLIs reject schema 2.

Use `riela cache` or the `riela/cache-*` add-ons for disposable inspected
retrieval bodies and media. The opt-in cache defaults to a fixed 24-hour TTL
and a 256 MiB LRU budget, with bounded batch stdin operations and physical
SQLite reclamation. Durable memory and export receipts are unaffected. See
[the cache contract and safe replay rules](docs/retrieval-cache.md).

## Workflow memory (short-term)

Riela owns short-term workflow memory in its own standalone SQLite store,
separate from kaiba notes. Workflows declare `memories` at the workflow and
node level; the `riela memory` commands and the `riela/memory-*` /
`riela/chat-persona-memory-*` add-ons persist records under `.riela/memory/`
(or the memory root given by `--memory-root`, addon config `memoryRoot`, or
`RIELA_MEMORY_ROOT`).

Each memory record has a default 1,000,000-byte payload read budget, measured
as its stored SQLite JSONB bytes. `memory load` fails with `payloadTooLarge`
when a selected record exceeds the budget; it never substitutes an older
record. `memory search` and persona context reads retain the existing behavior
of skipping oversized records. Set `--max-payload-bytes` on CLI load/search,
or `config.maxPayloadBytes` on memory-load, memory-search, and persona memory
add-ons, to an integer from 1 through 67,108,864. This is a per-record budget,
not a total response limit. Persona write deduplication always fails closed
on oversized prior records, preventing a replay from creating duplicates.
The Swift `MemorySearchOptions.payloadOverflowPolicy` explicitly selects
`.skip` (search default) or `.fail`; store load helpers use `.fail`.

Memory record changes are versioned atomically using the latest value and
explicit `next-to-previous` deltas. Use `riela memory history`, `show-version`,
and `restore-version` to inspect or restore an earlier value. Replaced
attachments remain available to historical versions. See
[evolution history](docs/evolution-history.md) for commands and storage details.

Long-term memory is kaiba's: `kaiba/memory-consolidate` distills a short-term
window into notes in the canonical `Kaiba Long-Term Memory` notebook and links
their graph associations, and `kaiba/memory-recall` searches those notes and
renders prompt-ready `recallText`. Riela short-term record ids are not kaiba
notes, so `sourceMemoryRecordIds` is stored in the note's `metaJSON` rather
than becoming note links; only `relatedNoteIds` that resolve to existing kaiba
notes are linked. Appends are idempotent per step execution, or per an explicit
`idempotencyKey` for period-keyed consolidation. The reference bundle is
`examples/memory-consolidation`, which also shows the cron event source that
drives it on a schedule.

## Workflow Key-Value Store Add-Ons

`riela/kv-set`, `riela/kv-get`, `riela/kv-delete`, and `riela/kv-list` give
workflows a durable-object-style persistent key-value store: JSON values
addressed by key, upserted into a local SQLite database that survives across
workflow runs. Entries are scoped to the executing workflow id by default, so
each workflow gets its own namespace inside a shared store file; an explicit
`config.scope` opts into sharing a namespace across workflows. The canonical
use is an incremental fetch cursor: persist the newest fetched post id or page
token with `kv-set` at the end of a run, read it back with `kv-get` (with an
optional `default` for the first run) at the start of the next run, and clear
it with `kv-delete` when resetting.

Values come from `config.value` (literal JSON), `config.valueTemplate`
(template-rendered JSON, preserving types for exact `{{...}}` references), or
rendered `addon.inputs.value`. Databases live under `.riela/kv/<storeId>.sqlite`
in the working directory (default `storeId` is `workflow-kv`; override the root
with addon config `kvRoot` or workflow input `kvRoot`). `kv-get` reports
`found` plus the stored `value`, `kv-delete` reports `deleted`, and `kv-list`
enumerates scoped keys with an optional `keyPrefix` filter. The reference
bundle is `examples/x-incremental-posts-kv`. The digest add-ons reuse the same
store: `riela/x-digest` and `riela/gmail-digest` accept `stateBackend: "kv"`
on `read-state`/`persist-state` to keep their fetch cursor in the key-value
store instead of an ad-hoc JSON state file, as the shipped digest examples do.

## Routines (first-class recurring jobs)

A routine is a managed "do NN every YY" job: a task prompt, a six-field cron
schedule, a target workflow run on every tick, an optional natural-language
completion criteria, and a lifecycle status (`active` / `disabled` /
`completed`) stored in SQLite at `.riela/routines/routines.sqlite` (override
with `--routine-store` or `RIELA_ROUTINE_STORE`). Creating a routine also
writes a cron event source and a routine-tagged binding under the event root
(default `.riela/events`), so `riela events serve` fires it; the cron dispatch
path checks the SQLite status before every run, so completing or disabling a
routine stops it immediately without restarting the serve loop (new/changed
schedules still need one restart to load).

To inspect live event ingestion without executing workflows or sending replies,
use `riela events serve --read-only` (or `RIELA_EVENTS_READ_ONLY=true`). The
listener keeps receiving events and writes skipped receipts with the original
envelope and matched input, with no workflow execution ID. Matched provider
polling cursors advance after durable evidence is saved; file watchers retain
their existing in-memory scan and startup snapshot behavior. Skipped deliveries
do not count as completed routine runs. `--limit 1` provides a bounded check.
`--dry-run` is a separate one-shot check that does not start the listener.
`events replay` currently persists a replay receipt; it does not execute a
workflow. Replaying read-only evidence retains a dry-run status and no execution ID.

Relative routine-store paths resolve against `--working-dir`, and routine list
limits must be between 1 and 1,000 so CLI, GraphQL, and add-on queries stay
bounded.

Surfaces:

- CLI: `riela routine create --name <n> --task <t> (--schedule "0 */30 * * * *" | --every 30m) --workflow routine-task-runner [--completion-criteria <c>] [--timezone Asia/Tokyo] [--deactivate-workflow-on-completion] [--overlap-policy <skip|cancelRunning|queue|concurrent>] [--max-queued-runs <n>] [--max-concurrent-runs <n>]`,
  plus `list`, `inspect <id>`, `complete <id> [--note ...]`, `enable <id>`,
  `disable <id>`, `set-overlap-policy <id> (--overlap-policy <v> | --clear-overlap-policy) [--max-queued-runs <n>] [--max-concurrent-runs <n>]`,
  and `delete <id>`. `inspect` prints `overlapPolicy=<v|inherit>`. `inherit`
  means the routine's binding sets no policy, so serve uses the workflow's
  `triggerDefaults` policy or, without one, `skip`; that layer is resolved
  when `riela events serve` starts and is shown in `serve-record.json`
  (`overlapPolicies`), not by `inspect`. `set-overlap-policy` replaces the
  whole policy: a cap you omit is removed, so
  `--overlap-policy queue` alone resets `maxQueuedRuns` to its default of 1.
  It patches only the overlap keys of the binding file and keeps its
  `enabled` state and other edits. A policy change takes effect the next time
  `riela events serve` starts.
- GraphQL (locally trusted hosts): `routines` / `routine` queries and
  `createRoutine` / `completeRoutine` / `setRoutineStatus` / `deleteRoutine` /
  `setRoutineOverlapPolicy` mutations (`Routine` and `CreateRoutineInput` carry
  `overlapPolicy`, `maxQueuedRuns`, and `maxConcurrentRuns`), available
  through `riela graphql execute --query ...` and the RielaApp web `/graphql`
  endpoint.
- Add-ons: `riela/routine-create`, `riela/routine-complete`,
  `riela/routine-get`, `riela/routine-list`, `riela/routine-update-status`,
  and `riela/routine-delete`, so workflows can manage routines themselves.

When a completion criteria is set, the per-tick workflow judges it and calls
`riela/routine-complete` with `conditionMet`; on completion the routine's
event source/binding files are disabled and, when the routine was created
with `deactivateWorkflowOnCompletion`, the target workflow is deactivated in
the workflow registry. Reference bundles: `examples/routine-task-runner` (the
generic per-tick executor) and `examples/routine-chat-manager` (create a
routine from a chat instruction like "check the release status every 30
minutes and stop once v2.0 ships" and confirm in the conversation).

### Overlapping cron fires

`riela events serve` runs cron-fired workflows as tracked in-flight tasks, so a
long run does not block the other sources in the same serve process. When a
fire arrives while a run of the same binding is still in flight, the
binding's overlap policy decides what happens:

- `skip` (the default): the new fire starts no run. It is recorded with reason
  `overlap-skip:<bindingId>:<runningSessionId>`.
- `cancelRunning`: the in-flight run is cancelled through the runtime's normal
  cancellation path. The new fire waits up to 30 seconds for that run to
  settle and then starts. The cancelled session ends with status
  `cancelled` and `failureKind: cancelled`. If it does not settle within 30 seconds, the new
  fire is not started and is recorded as `overlap-cancel-timeout`.
- `queue`: the fire waits in an in-memory FIFO of at most `maxQueuedRuns`
  entries (default `1`). A fire that finds the queue full is dropped. A
  `--limit` run waits for queued fires to finish. A signal or error shutdown
  discards them and records them as discarded.
- `concurrent`: the fire starts at once, in parallel. If `maxConcurrentRuns`
  is set and that many runs are already in flight, the fire is dropped.

Set `overlapPolicy` (plus `maxQueuedRuns` for `queue` or `maxConcurrentRuns`
for `concurrent`) on a cron binding, or on a routine with the flags above. To
set a default for a workflow, put the same keys in a `triggerDefaults` object
in its `workflow.json`. Manual runs ignore `triggerDefaults`. The policy
resolves as binding, then workflow `triggerDefaults`, then `skip`, and is
resolved once when serve starts. Existing configs that do not set it get
`skip`. Before this change, missed ticks were merged into one later fire; set
`"overlapPolicy": "queue"` to keep that catch-up behavior. Unknown values fail
`riela events validate` (JSON `status: failed`) and `riela workflow validate`.

Every outcome is recorded as a cron receipt, including a fire the routine
gate skips. `riela events list` adds ` reason=overlap-...` and ` binding=<id>`
to each line, lists receipts newest first (so `--limit` returns the most
recent outcomes), and `--status skipped` filters skipped fires. A frequent
cron writes one receipt file per fire and binding: `riela gc --results-max-age-days
<n>` ages out receipts under the user and project `.riela/events/receipts`
roots, while receipts under a custom `--event-root` are never collected and
need their own cleanup. Queued fires are not persisted across restarts; a
serve that starts after `kill -9` closes receipts a dead serve left `queued`
(as `discarded`) or `dispatched` (as `failed`) with reason
`overlap-abandoned:<bindingId>`. `serve-record.json` gains `overlapPolicies` and
`lastIgnoredReason`. `riela workflow inspect` prints a `triggerDefaults:` line.
A routine counts only runs that complete successfully. Skipped, dropped,
cancelled and failed fires are not counted, and `lastRunAt` never moves
backwards when concurrent runs finish out of order.

Only cron sources apply an overlap policy; webhooky, file-change and chat
sources still run their workflows inline. The policy applies within one serve
process; `workflow.loop.concurrency` remains the cross-process guard. See
[the overlap policy design](design-docs/specs/design-scheduled-overlap-policy.md).

## Document Conversion Add-On

`riela/file-markdown-convert` converts local documents (pdf, doc, docx, ppt,
pptx, xls/xlsx, odt, ods, odp, rtf, epub, csv) to GitHub-Flavored Markdown
through the [`anydoc-swift`](https://github.com/tacogips/anydoc-swift) package's
`AnydocKit` library, which wraps
[firecrawl/anydoc](https://github.com/firecrawl/anydoc). That library is linked
into `riela` and called in-process — it is the same native converter kaiba's
document intake already uses — so no `anydoc-swift` executable has to be
installed. Failures arrive as a typed error kind (`unsupported`, `malformed`,
`encrypted`, `resourceLimit`, `io`, ...) rather than a prose message.

`addon.config.binaryPath` and `ANYDOC_SWIFT_BIN` no longer exist; a leftover
`binaryPath` is refused rather than ignored. Document paths come from
`addon.inputs.path` / `addon.inputs.paths` only. A step deadline still fails the
step on time, but the native conversion cannot be interrupted, so at most one
document's work finishes in the background after that. The add-on rejects authored `addon.env`, caps input size, document count,
and emitted Markdown size, and can be restricted to `config.allowedRoots`.

```bash
riela workflow validate file-markdown-convert --workflow-definition-dir examples
riela workflow run file-markdown-convert --workflow-definition-dir examples \
  --variables '{"workflowInput":{"path":"/abs/path/report.pdf"}}'
```

The reference bundle is `examples/file-markdown-convert`.

## Apple Container Nodes

Workflow container nodes may select Apple Container with
`container.runnerKind: "container"`. This runtime is available only when
Riela itself is running on a Darwin host; other hosts reject the node before
starting a process. Docker, Podman, and explicitly configured custom container
runtimes retain their existing cross-platform behavior.

On Darwin, Riela resolves the Apple Container executable to an absolute path
and launches it directly from Swift through the local `posix_spawn` process
boundary. It does not invoke Apple Container through a shell or
`/usr/bin/env`. Install and start the runtime with:

```bash
riela setup container --yes
```

## Apple Gateway Add-Ons

Riela includes built-in worker add-ons for local Apple integrations. They call
the sibling `apple-gateway` package's `AppleGatewayCore` library inside the
`riela` process, so no `apple-gateway` executable is spawned or installed and
there is no `addon.config.binaryPath` or `APPLE_GATEWAY_BIN`. These add-ons
reject authored `addon.env` and let the gateway see only the minimal process
environment the shared bridge allows.

macOS attaches Apple Events, Calendars, Reminders, and Contacts permission
grants to the executable that asks, so `riela` is now the asker — see
[Apple permissions](#apple-permissions) for what that means for existing
grants.

Native Apple and Gmail add-ons accept `config.writeRetry` with
`initialWaitSeconds` (1...60, default 2) and `maxRetries` (0...5, default 3).
Retries exclude the initial attempt; zero disables retries. Delays double
from the initial wait up to 60 seconds. Only transient failures proven not
to have dispatched the mutation are replayed. Ambiguous outcomes fail closed;
GraphQL operations and successful mutation aliases are never replayed as a
whole. Notes verification may retry reads against the confirmed resource ID.
Cancellation and the node deadline stop pending retries.

The linked gateways also accept explicitly supplied
`APPLE_GATEWAY_WRITE_RETRY_INITIAL_WAIT_SECONDS` /
`APPLE_GATEWAY_WRITE_RETRY_MAX_RETRIES` and the corresponding
`GMAIL_GATEWAY_WRITE_RETRY_*` keys. Add-on configuration takes precedence over
explicit Gmail environment bindings; ambient process retry variables are not
forwarded. Apple settings also apply to host-native bridge operations,
including note attachments, Calendar, Mail, Reminders, and notifications.

Current Apple gateway add-ons include `riela/apple-notes-list`,
`riela/apple-notifications-list`, `riela/apple-notification-post`, and
`riela/apple-notifications-dismiss`. Notification listing is read-only.
Notification posting uses AppleGatewayNotifier.app and may require the macOS
notification authorization prompt. Reading notifications from `SYSTEM_DB`
requires Full Disk Access for the apple-gateway host process.

Apple Gateway packaging is intentionally not a built-in add-on. Packaging uses
repository `task` targets and human-readable build output rather than the
shared `apple-gateway graphql` JSON envelope. Use command-node recipes for
read-only dry-run plans, and keep signed/notarized Cask builds and release
publishing as human-run shell commands outside Riela so Apple signing
credentials stay only in the operator's kinko-managed environment and macOS
keychain. The deterministic reference bundle is
`examples/apple-gateway-packaging-plan`.

Use the bundled examples to validate authoring without copying workflows into
`./.riela`:

```bash
riela workflow validate apple-notes-list --workflow-definition-dir examples
riela workflow validate apple-notifications --workflow-definition-dir examples
riela workflow validate apple-gateway-packaging-plan --workflow-definition-dir examples
```

`examples/apple-notifications` posts one demo notification and then dismisses
only the returned `postedNotificationId`; it never uses dismiss-all. Check local
gateway permissions before live notification runs:

```bash
apple-gateway permissions status --json
```

## Built-in Add-on Host Catalog

Issue [#116](https://github.com/tacogips/riela/issues/116) adds 12 existing
version-1 adapter names to the built-in host catalog: the chat persona, memory,
digest, SDK worker, time signal, and deferred container gateway add-ons. Bundled
workflows using these names validate without declaring external add-on
executables. Unknown names and unsupported versions still fail closed. The
`riela/gmail-gateway-read` and `riela/x-gateway-read` entries retain their
existing `status: ok` no-op response and make no gateway request; they do not
represent live gateway reads.

The 0.2.2 source CLI validates all 75 bundled examples, with zero
`unresolvedAddonExecutable` diagnostics. The earlier 0.2.1 validation finding
for `x-follower-ai-business-digest` was resolved during the example contract
migration. To check an example with the built CLI, run:

```bash
swift build --skip-update
.build/arm64-apple-macosx/debug/riela workflow validate <example-name> --workflow-definition-dir examples --output json
```

The source verification used `swift test --skip-update` with the
`RielaBuiltinAddonCatalog`, `WorkflowHostCapabilityTests`, and
`DeferredContainerAddonTests` filters, plus
`/usr/bin/xcrun swiftlint --quiet --no-cache`, `swift build --skip-update`,
and `git diff --check`.

## Work Runtime (`RielaWork`)

See [Work handover and takeover](docs/work-handover.md) for task handover,
answers, presence placement, and orphan recovery.

A task attempt can stop because it needs an answer, needs a person at a
particular host, has gone inactive, or has lost its owner. The runtime then
seals a digest-verified `HandoverPacket` and publishes repository work on
`riela/task/<taskId>/g<generation>`. A successor attempt imports the accepted
history and continues at the packet's resume step. A workflow run or resume
that suspends exits with code **5**. The handover commands are:

```bash
riela task handover <task-id> --reason <text> [--now]
riela task answer <task-id> --question <question-id> --text <answer>
riela task takeover <task-id> [--force-orphan] [--traits userReachable] [--endpoint <url>/graphql]
riela task handovers
riela task reconcile --expired-leases
riela task serve --takeover --endpoint <url>/graphql --traits userReachable
riela session handover <session-id> [--reason <text>]
```

Over GraphQL, the same operations are `requestTaskHandover`, `answerTask`,
`takeoverTask`, `taskHandover`, `tasksAwaitingHandover`, `heartbeatAttempt`
and `reportAttempt`.

The P1 release remediation for Draft PR #113 registers
`riela/chat-reply-worker@1` in the built-in catalog, so
`riela workflow usage matrix-chat-reply --workflow-definition-dir examples --output json`
resolves the example's reply step. Unknown add-on names and unsupported
versions still fail validation. Current-source verification passed the focused
P1 suite (181/181), Work/CLI/Core (2,062/2,062), and the full nonparallel
Swift suite (2,717 passed, two disclosed skips, zero failures). See the
[integration progress](impl-plans/progress/p1-release-integration.md) for
commands, logs, skips, and the 21-assertion ledger. Draft PR #113 remains
unpublished from this documentation gate; commit, non-force push, and PR head
verification remain open.

`Sources/RielaWork` is the Work Runtime module: one lifecycle for the work
that a single workflow run is not enough to finish. An `Intent` states what is
wanted, a `WorkTask` carries the completion contract, guard policy and
director policy, and each `Attempt` is one ordinary workflow session. Whether
the work is done is decided by `CompletionEvaluator` against the task's
contract — required gates accepted, verification passing, no open blocking
finding, and, when the task states natural-language acceptance criteria, an
explicit `acceptance.met` in the gate payload — never by the session's own
status. `WorkEvidenceProjector` turns a terminal session snapshot into the
task's evidence ledger and findings, with `causedBy` edges linking findings to
the gates that raised them. `RielaWork` depends on `RielaCore`; the runner
never imports it, so plain runs, tests and library callers are unaffected.

`WorkStore` keeps `work_intents`, `work_tasks`, `work_attempts`,
`work_decisions`, `work_evidence` and `work_findings` in the same runtime
records database as the workflow snapshots, behind that store's single schema
generation. There is no migration: a session store from an older generation is
discarded and recreated.

Task inspection and execution are available through the CLI:

```bash
riela task list [--state <task-state>] [--intent <intent-id>] [--workflow <name>] [--limit <n>]
riela task show <task-id> [--scope project|user|auto] [--session-store <dir>] [--output jsonl|json|text]
riela task run <task-id> [--scope project|user|auto] [--session-store <dir>] [--dry-run] [--output jsonl|json|text]
```

`task run` resolves reachable root and called-workflow requirements before
reserving an attempt. It keeps selected worker, backend, model and workspace
choices through the existing workflow runner and authenticated worker path.
Missing capacity, dependencies or a live eligible worker return a wait without
allocating an attempt or session; `--dry-run` previews placement without an
allocation. A dry run reads private copies of existing task stores and leaves
the live database, SQLite sidecars and host profile unchanged. An active SQLite
WAL, corrupt input or a concurrent store change returns an error instead of a
possibly stale preview. Text and structured output report `ready` with
prospective placement, or `waiting` with a reason, without attempt or session
IDs. A real run reports the exact reserved IDs after admission, including when
the admitted execution fails; pre-admission errors have no reserved IDs. A
preview does not guarantee later admission. Once a worker has claimed a job,
loss of that worker does not trigger a local fallback or duplicate launch. See
[controller and worker setup](docs/distributed-workers.md) for placement and
workspace configuration and the
[P1-6a plan](impl-plans/completed/work-runtime-p1-selected-host-delivery.md) for
its accepted slice and verification limits.

The accepted P1-6c cancellation slice makes a cancel request and terminal
session write arbitrate
in the shared SQLite transaction: an accepted request waits for the owned run
and selected host to stop before cancelled state and acknowledgment persist;
an already terminal session rejects a later cancel. If stop cannot be proved,
the request stays pending and the terminal write stays fenced. Replaying an
accepted decision does not create another cancellation. The source-matched
selected-host and focused checks passed, while the serial broad gate still
fails on 19 classified non-slice assertions. See the
[P1-6c progress record](impl-plans/progress/p1-dispatch.md) for verification.

The accepted P1-6d slice runs one configured, bounded `.director` child through
ordinary task dispatch. The shared store links the child to the judged attempt,
retains the judged TaskView and host capability inputs, and applies the child's
typed decision against the original work gates, verification and findings.
Child success alone cannot accept the task. Reservation, replay and terminal
reconciliation preserve one child attempt, session and cost charge; invalid,
failed or budget-blocked child work escalates without recursive dispatch.
Seven source-matched focused selections passed 399/399 tests, build and touched
SwiftLint passed, and independent test-integrity, adversarial and combined-tree
review accepted this slice. The serial broad run remains **FAILED** with 19
classified historical non-slice assertions among 2,666 tests. Browser E2E was
skipped because no `web/` file changed. See the
[P1-6d progress record](impl-plans/progress/p1-dispatch.md) for exact commands
and evidence. The P1-7b replacement bundles are now available as
[`task-repair-loop`](examples/task-repair-loop/README.md) and
[`task-agent-director`](examples/task-agent-director/README.md). The new
[`task-handover-answer`](examples/task-handover-answer/README.md),
[`task-handover-presence`](examples/task-handover-presence/README.md), and
[`task-handover-orphan`](examples/task-handover-orphan/README.md) examples show resumable task handovers.
The three new examples join the shared catalog and raise its deterministic mock scenario count to 43. Task-backed
tests check rejected-gate recovery with a second attempt, guard stop, capacity
wait, bounded director decisions, once-only child accounting and invalid-output
escalation. A task-reserved run retains a completed canonical session when its
required gate rejects so the task can recover; a standalone rejected required
gate still fails the run and preserves gate evidence. The P1-7b build, catalog
checks, 21 task example tests, 57 before-removal tests, 115 affected work tests
and 55 selected-host tests passed. The serial broad suite remains **FAILED**
with 18 classified non-P1-7b assertions among 2,668 tests. Browser E2E was
skipped because no `web/` file changed. Parent P1 and the broad failure
follow-ups remain open. See the
[P1-7b progress record](impl-plans/progress/p1-dispatch.md) for exact commands
and logs.

The reviewed P1-7a A1 dispatcher guard now checks the exact running attempt,
session, execution and canonical progress inside the SQLite decision
transaction before an inactivity stop or bounded rerun. Progress committed
after the observer recheck makes that observation stale, so it cannot create a
decision, cancellation or replacement reservation. A genuinely idle attempt
still follows its configured policy; committed decisions replay once. The
deterministic race regression and source-matched Xcode build, policy (75/75),
before-removal (69/69), canonical (94/94), cancellation-host (49/49) and live
(5/5) test selections passed with strict changed-file SwiftLint. Codex Sol
(`comm-000013`) and Codex Astra (`comm-000018`) accepted A1. Browser E2E was
skipped because no `web/` file changed. P1-7a A2/A3 has since removed the
legacy workflow auto-improve option, result and examples after task-backed
replacement coverage. Ordinary workflows remain task-free; specialist, event,
loop and routine paths remain available. Current-source cancellation coverage
passed 1/1, strict changed-file SwiftLint passed on 21 paths, and the V7
repository lint comparison found 24 unchanged warnings across 970 Swift files.
Both broad Swift test aggregates remain **FAILED**, exit 1: Work/CLI/Core ran
2,061 tests and the full nonparallel suite ran 2,717 cases with two skips. Each
matched all 21 baseline assertions across 19 failed cases. Independent
test-integrity, adversarial and integration reviews accepted the baseline
attribution and P1-7a A4 handoff with no material finding. The historical A0
per-command environment snapshots are unavailable. Browser E2E was skipped
because no `web/` file changed. The native parent continuation has since
carried the single `p1-dispatch` branch through current-tree review. Independent
test-integrity, Codex Sol adversarial and Codex Astra integration accepted the
documentation-only continuation and the separate baseline attribution of both
FAILED aggregates. The focused dispatcher/example selection remains 69/69
passing; the Work/CLI/Core and full nonparallel aggregates remain **FAILED**,
exit 1, with 21 baseline-matched assertions each. Browser E2E was skipped for
this continuation because no browser-facing file changed. The accepted P1
implementation plan is archived. Exact-file commit, non-force push and Draft
PR #109 head verification remain pending workflow publication gates.
See the [P1-7a progress record](impl-plans/progress/p1-dispatch.md) for commands,
logs and review history. The design is
[Work Runtime consolidation](design-docs/specs/design-work-runtime-consolidation.md).

## Control Surfaces

Every operation that riela exposes is declared once in `SurfaceCatalog`
(`Sources/RielaCore/SurfaceCatalog.swift`), with one row per CLI command,
GraphQL field, `/api/v1` route, library entry point and packaged skill command
block. Rows that are intentionally unavailable carry an explicit reason:
`blocked` rows cite the plan that will implement them, `excluded` rows explain
why the surface is not offered. Five gate tests hold CLI, skills, GraphQL, web
API and library in agreement with the catalog, so a new command cannot ship on
one surface and silently be missing from the others.

The GraphQL schema is generated from the request/response types plus the
catalog. Regenerate it with `scripts/surface-parity/generate-sdl.sh` after
changing a DTO or a catalog row; a freshness test requires the checked-in SDL
to be byte-identical to the generator's output. `riela graphql`, `riela serve`,
the desktop provider and the browser console all share one GraphQL parser.

Session control is available on GraphQL as well as on the CLI. The
`rerunSession` and `resumeSession` mutations reuse the same runner paths as
`riela session rerun` and `riela session resume` and authenticate like
`continueSession`, so a session driven from either surface keeps the same
lineage; a `workflowId` that does not own the session is rejected with
`SESSION_WORKFLOW_MISMATCH`. `stopSession` has no CLI counterpart — the command
line cancels by signalling the running process — and it stops only sessions the
answering process is running, addressed by the session id you entered rather
than an id a rerun reports.

Browser and desktop console reads — instance list, instance detail and the
operations overview — go through GraphQL. The former `/api/v1/instances` read
routes and the instance portion of `/api/v1/ops/overview` are removed with no
compatibility shim. The surviving `/api/v1` routes — console bootstrap,
workflow-source reads, execution reads, instance creation and instance actions,
and the Passkey authentication routes — are declared in
`Sources/RielaAppSupport/RielaWebAPIRouteTable.swift` and cataloged as excluded
with reasons.

Embedding callers use the `RielaLibrary` facade in
`Sources/RielaCLI/RielaLibrary.swift`, whose entry points are
`executeWorkflow`, `resumeSession`, `rerunSession`,
`inspectWorkflow`, `sessionView` and `executeGraphQLDocument`. The packaged
skills under `Resources/skills` — `riela-workflow-reference` and
`riela-workflow-run` — are written against those real names and against the
cataloged CLI commands, and the skills gate fails if they drift.

## Install

On macOS, install the Homebrew formula when you want only the `riela` command
line tool:

```bash
brew tap tacogips/tap
brew install riela
```

Install the signed and notarized Cask archive when you want both
`RielaApp.app` and the `riela` command line tool on macOS:

```bash
brew tap tacogips/tap
brew install --cask riela
```

The Cask release is built locally from Apple Developer ID credentials and
publishes signed, notarized, and stapled `.dmg` assets to the GitHub release before rendering
`Casks/riela.rb` in `tacogips/homebrew-tap`. See
`packaging/homebrew/README.md` for the signing, notarization, and tap update
workflow.

Linux releases are CLI-only tarballs published on GitHub releases. They are
not wired into the Homebrew tap.

On Ubuntu x64, install the latest CLI archive from GitHub Releases:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl libcurl4 libsqlite3-0 libxml2
version="$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/tacogips/riela/releases/latest | sed 's#.*/v##')"
curl -LO "https://github.com/tacogips/riela/releases/download/v${version}/riela-${version}-linux-x64.tar.gz"
curl -LO "https://github.com/tacogips/riela/releases/download/v${version}/riela-${version}-linux-x64.tar.gz.sha256"
sha256sum -c "riela-${version}-linux-x64.tar.gz.sha256"
tar -xzf "riela-${version}-linux-x64.tar.gz"
sudo install -m 0755 bin/riela /usr/local/bin/riela
sudo mkdir -p /usr/local/share/riela
sudo cp -R share/riela/. /usr/local/share/riela/
riela --version
```

## Desktop window

Choose **Open Console...** from the menu bar to open the shared dashboard in
Tauri. In the desktop header, **Connection** selects **Local** (the default,
no login or HTTP listener required) or **Web mode**. Web mode accepts a remote
Riela server origin such as `https://riela.example` and uses Passkey sign-in
through the system browser. Confirm the matching code in both windows; after
sign-in the desktop connects automatically. The bundled console sends remote API requests through Tauri's HTTP
client; the remote server does not need to allow the Tauri webview origin via CORS.
The URL must be an origin without a path, query, or credentials. Changing mode
reloads the console and clears authentication and loaded profile data; save edits
first. The selected origin lasts for the window session, and tokens stay only in
page memory. Returning to Local requires no authentication. Browser users open
the same server URL to use the web console hosted by `riela serve`.

The Swift menu-bar process owns the profile and workflow runtime;
the Tauri child loads bundled assets and exchanges API requests over inherited
stdin/stdout pipes. Opening the desktop window does not start an HTTP listener.
Closing the window leaves the menu-bar app running; opening it again creates
a new window. Repeated open actions focus the existing window.

To explicitly start the app-owned loopback HTTP server when launching a new
RielaApp process, pass `--start-web-server`. It uses the selected app root’s
persisted web-server port (default `19091`) and the existing controller’s
security and shutdown behavior. Without the flag, launch behavior is unchanged;
opening the desktop or a saved enabled setting alone does not start HTTP.
This flag does not register a service or send an action to an already running app.

For development:

```bash
mise install
bun run --cwd web desktop:build:debug
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --product RielaApp
.build/debug/RielaApp --open-desktop --no-autostart-daemons
```

In **Workflows → Discovered workflows**, selecting a workflow opens a
dedicated definition screen with its node network and directional connections.
Select a node for details, drag the canvas to pan, or use the zoom and fit
controls. **Back to workflows** returns to the list; browser history and
`#/workflows/<encoded-source-id>` links also work.

The desktop executable requires a parent RielaApp IPC connection; launch it
through RielaApp. `RIELA_DESKTOP_EXECUTABLE` can point to a specific desktop
executable for development. `scripts/build-riela-menu-bar-app.sh` builds and
embeds `Contents/Helpers/RielaDesktop.app` in the menu-bar app.

The Cask builder includes the same helper and signs it before the parent app.
Install the matching Rust targets before building both macOS architectures:
`mise exec -- rustup target add aarch64-apple-darwin x86_64-apple-darwin`.

The explicit **Start server**, **Stop server** and **Open in browser** actions
live in the console's Settings → Web Config server (local desktop only). A saved
server preference does not automatically open a listening port when the
menu-bar app starts.

## Browser server development

`riela serve` discovers bundled dashboard assets in the app's `Resources/Web`,
beside the Cask CLI in `Web`, or under the installation prefix's
`share/riela/web`. Executable symlinks are resolved before locating assets.
Development runs also search `web/dist` in the working directory.
CLI archives include the dashboard and Swift resource bundles in `share/riela`;
install this directory alongside `bin/riela`. Use `--web-root` to override the
asset directory, and `--working-dir` to include a project's workflows:

```bash
bun run --cwd web build
.build/debug/riela serve --host 127.0.0.1 --port 8787 --working-dir /path/to/project
```

The loopback browser backend shares definition, instance and execution
projections with RielaApp. It reads the active profile's sources and provides
the mutable workflow registry through the same validated GraphQL contract.
Browser mutations require the matching Host, Origin, CSRF token and profile.
CLI and manager GraphQL requests retain the existing authenticated route.

Settings supports persisted profiles, assistant preferences, native appearance,
workflow directories, instance environment settings and event-source registration.
The RielaApp menu-bar menu keeps only app-level items (**Open Console...**,
**Launch on Login**, About, Quit); everything else is done in the console.
Worker controller configuration is edited in Settings, including authorized
workers, start/stop, live worker status and save/restart; there is no separate
Swift settings window. The desktop uses native IPC and does not require starting
the optional HTTP server.
Sources refresh after configuration changes. Profile and revision conflicts reject
stale updates. The server port is saved separately in `~/.riela/serve-web.json`;
restart `riela serve` to apply it. An explicit `--port` overrides the saved value.

Workflow studio uses the same editor runtime in the desktop and browser: copy a
source bundle, edit definitions and file-backed node settings, generate graph
changes with the configured assistant, save a revision, activate and run it, and
inspect recorded inputs and outputs. Runs use `--session-store` when supplied,
otherwise the active profile's session directory. Browser-hosted editor jobs are
cancelled when the serve process shuts down.

In the desktop and server dashboard, open **ワークフロー** (Workflows), select a
workflow, then choose its **実行設定** (run configuration). **標準設定** (Default)
is available immediately after discovery without a separate creation step. Use
**実行設定を追加** only when another named configuration is needed. The selected
configuration provides settings, start/stop/restart controls, and **履歴** (history).
Adding a workflow or configuration does not start execution. Required environment
values must still be supplied before running. Workflow definitions and instance
identities remain separate internally; configurations are grouped by source
identity so workflows with matching names or IDs do not share settings.

Select a configuration to change its launch enablement. Starting marks it active and enabled; stopping clears its
active state. `riela serve` starts saved instances that are both active and
enabled at launch. Configuration and event-source changes restart running
instances. Switching profiles stops the previous profile's instances before
starting the selected profile's enabled active instances; server shutdown stops
all owned instances. Instance runs and their browser history share the profile's
session directory, or the explicit `--session-store` override.

Remote browser and Tauri console access uses Passkeys (WebAuthn). Set
`RIELA_WEB_ORIGIN` to the exact public HTTPS origin, including a non-default port
when applicable, without a trailing slash. Run these commands on the server
with the same OS user and environment:

```bash
export RIELA_WEB_ORIGIN=https://riela.example
riela auth invite operator
riela serve --host 0.0.0.0 --port 8787
```

Use an HTTPS reverse proxy for remote connections; `riela serve` itself speaks
HTTP. Preserve the public Host header through the proxy. The invitation command
prints a private, one-use registration URL that expires in 15 minutes. Open it
in a browser to create a Passkey. No email address or password is required.
**Every registered user has full console operator access**, including profiles,
configuration and workflow execution. Registration is invitation-only; do not
publish invitation links. Private keys remain with the user's authenticator.

Browser users open the server URL and choose **Sign in with Passkey**. In Tauri,
select **Connection → Web mode**, enter the same server origin, and choose
**Sign in using browser**. Compare the displayed codes before approving. The
browser never receives the desktop session; only the initiating desktop window
can redeem the result, once, within five minutes. Cancel stops desktop polling
and cancels the pending grant. No local callback HTTP server is started.

Sessions expire after eight hours, and **Sign out** revokes the current session.
Reloading or closing the console drops its in-memory session token. Restarting
the server invalidates all sessions and pending logins. API responses are not
cached; authenticated mutations retain Host, Origin, CSRF and profile checks.
`RIELA_WEB_TOKEN` no longer grants console access. CLI and manager GraphQL clients
retain their separate, existing credential contract.

Use `riela auth users` to list usernames and public credential IDs. Run
`riela auth invite operator` again to add a backup Passkey for the same user.
`riela auth revoke-key <credential-id>` revokes a lost key and its sessions;
issue another invitation to recover access. `riela auth revoke-user operator`
disables that user, all their sessions and outstanding invitations. Disabled
users cannot receive new invitations; use a new username when intentionally
replacing a disabled account.

Keys and invitation hashes are stored under `~/.riela/web-auth`, independently of
workflow profiles. `RIELA_WEB_AUTH_ROOT` overrides this directory for both CLI
and server. Keep a secure backup; the store is bound to its configured origin.
Changing the origin requires a separate store and new Passkey registrations.
Passkeys need a browser with WebAuthn support and HTTPS. For local development,
`http://localhost:<port>` is supported. Explicit `RIELA_WEB_ORIGIN` enables
Passkey authentication even on a loopback listener. Without it, loopback browser
access and Tauri Local mode remain registration-free and authentication-free.
An unconfigured public listener fails closed.

Implementation and test details are in [Passkey authentication](docs/passkey-authentication.md).

## RielaApp Packages And Profiles

RielaApp imports workflow folders, package folders, and `.rielapkg` archives
from the menu bar item:

```text
Install Workflow...
```

The picker accepts multiple selections, so several package archives or workflow
folders can be added to the active profile in one pass.

Package archives can also be imported at launch, which is useful after a CLI
pack step or in support reproductions:

```bash
RIELA_APP_ROOT="$PWD/tmp/rielaapp-root" \
.build/debug/RielaApp \
  --profile work \
  --import-workflow-or-package "$PWD/my-workflow.rielapkg" \
  --open-workflows
```

Imported packages are stored under the selected RielaApp profile. The dashboard
opens the workflow list; each workflow contains its default and named run
configurations. A run configuration saves its environment, variables, working
directory, model overrides, and launch preferences. Opening or importing a
workflow makes its default configuration available without starting it. Existing
saved configurations and their histories remain attached to the same source.

On a fresh install, the default profile is seeded with inactive starter
packages for a Discord Yuki chat bot, a Telegram Yuki chat bot, a Slack chat
bot, and a gmail-gateway latest-mail digest. Choose a workflow and its run
configuration to inspect required credentials, then start it explicitly.
Selecting a workflow opens a canvas in the center and **実行設定** in the right
pane, with no left pane. The graph stays visible while selecting configurations
or switching between **設定・実行** and **履歴**. Drag nodes to arrange the
view, drag the canvas to pan, zoom, and select nodes to inspect connections.
Node arrangement affects the current view; workflow definitions remain unchanged.
Browser Back and configuration URLs restore the workflow and selected
configuration. A missing source remains visible for recovery.

Use `Add Project...` to attach one or more project folders containing
`.riela/workflows` or `.riela/packages` without copying them into the profile.
Use `Open Profile Folder` from the menu bar item or Instances window to inspect
the active profile's imported `workflows/`, `packages/`, and daemon state.
Use `Reveal Source` in the Instances window to open the selected workflow or
package source directly.

To turn an existing workflow folder into a package that RielaApp can import,
generate the package manifest first, then archive it:

```bash
riela package init ./my-workflow --package-name my-workflow
riela package pack ./my-workflow
```

For a package source that keeps workflows under `workflows/<name>/`,
`package init` automatically uses the single workflow it finds:

```bash
riela package init ./my-package-source --package-name my-workflow
riela package pack ./my-package-source
```

If the package source contains multiple workflows, add
`--workflow-definition-dir workflows/<name>`.

### Optional pre-install security checks

`package install` and `package checkout` accept an opt-in static content scan of
the staged package before anything is written. It is off by default:

```bash
riela package install my-package --pre-install-check warn
riela package install my-package --pre-install-check reject
```

`warn` reports findings (piped remote-script execution, credential material,
network exfiltration, prompt-instruction overrides, machine-local paths) and
still installs. `reject` fails the install on any high/critical finding and
leaves nothing on disk. Finding excerpts are redacted and never contain full
secret values. Add `--pre-install-check-container docker|podman|auto` for an
optional no-network container inspection (read-only mount, no privileged mode,
secret environment variables filtered); it degrades to a diagnostic when no
container runtime is available, and static scanning always runs regardless.

### Publishing a workflow to a registry

Registries are explicit: register one with `riela package registry add`, or
pass `--registry-url` when searching, installing, or publishing. There is no
automatically selected registry. `riela package registry list` shows the
configured registries; `riela package search --refresh --registry <id>` fetches
its current index.

To update an installed package directly from GitHub, run
`riela package update https://github.com/owner/repo/tree/branch/packages/name`.
The URL must point to a directory containing `riela-package.json`. Use
`--dry-run` to preview changes. Set `RIELA_GIT_EXECUTABLE` to a Git executable
path when Git is not available on `PATH`.
Repository-root packages can use `https://github.com/owner/repo`. Updates
validate the source even with `--dry-run` or when its version is unchanged.
GitHub updates record the resolved commit in `riela-lock.json`, so `package ci`
reinstalls that revision even after the branch advances.

`package publish <workflow-dir>` computes a real md5 checksum over the staged
workflow, writes a normalized `riela-package.json`, and derives backend hints
from the workflow's node payloads. When the target registry has a local git
checkout, publish verifies the checkout's `origin` remote, refuses a dirty
worktree, then either pushes directly (after a non-destructive push-permission
probe) or, with `--create-pr`, opens a pull request (`--pr-base` selects the
base branch) and reports the `prUrl`. `--dry-run` validates and stages without
any git mutation.

```bash
riela package publish ./my-workflow --package-id my-package --registry local --yes
riela package publish ./my-workflow --package-id my-package --registry local --create-pr --pr-base main --yes
```

Packages can declare environment variables that must be configured before the
workflow is useful. Add them to `riela-package.json` with `environmentVariables`;
RielaApp shows whether each required value is set. The Instances window also
detects required workflow env bindings from `addon.env.*.fromEnv` and required
`agentEnvironment.*.fromEnv` entries. Select the instance, choose `Env File...`,
and pick a `.env` or `*.env` file to pass those values to the workflow and its
event-source process. Env file contents are treated as credentials: RielaApp
confirms before using the file and only displays set/missing status, not values.

```json
"environmentVariables": [
  {"name": "RIELA_TELEGRAM_BOT_TOKEN", "description": "Telegram bot token", "secret": true}
]
```

Runtime environment loaders keep credentials in memory for the lifetime of the
App instance. In its run configuration, set `environmentResolution` to a descriptor:

```json
{
  "required": ["SERVICE_API_KEY"],
  "sources": [{
    "id": "credentials",
    "names": ["SERVICE_API_KEY"],
    "command": ["/path/to/credential-loader", "--json"],
    "format": "json",
    "timeoutSeconds": 30
  }]
}
```

The command returns a JSON object of environment names and string values, or
NUL-separated `NAME=value` records when `format` is `env0`. Commands are argv
arrays executed without a shell; only declared names are accepted from their
output. Descriptors and required names are persisted; resolved values are not.
Workflow and file-backed node definitions can also declare
`"requiredEnvironment": ["SERVICE_API_KEY"]`. Missing required values or loader
failures prevent execution and appear as safe errors in environment status.

An instance loads once before its first execution. Later scheduled and manual
runs reuse its in-memory snapshot, including when the credential store becomes
locked. Use **Reload environment** in the App or web console, or target the
App's HTTP server or a `riela serve` host (both run the same loaders and serve
the same status and reload routes):

```bash
riela environment status --instance INSTANCE_ID --profile default --server http://127.0.0.1:8787
riela environment reload --instance INSTANCE_ID --profile default --server http://127.0.0.1:8787
```

Status exposes names, missing names and generation, never values. Credentials
are scoped per profile; deleting or renaming an App run configuration, or
switching the active profile (App or `riela serve`), drops the affected
in-memory values and statuses. A successful
reload atomically supplies a new snapshot to future executions, including
executions dispatched by a running event listener and the listener's own next
poll (chat and gateway tokens); Webhooky streams reconnect with the reloaded
credentials. Already running executions keep their captured snapshot. A failed credential reload preserves the last successful snapshot.
Changing the set of managed names (required names plus loader `names`) on a
running instance requires stopping and starting it; reload refuses with
`environment_restart_required` before running any loader or touching the
listener. A changed loader command or format with the same names is applied by
reload; if the new loader fails, the running instance keeps the previous
snapshot. Reload errors are safe codes: `environment_reload_in_progress` when
another reload of the same instance is still running, and
`environment_instance_changed` when the listener was restarted or stopped while
loaders ran (retry the reload). `riela environment reload` prints the failing
code (for example `environment_source_failed`) on stderr and exits non-zero.
A managed event listener receives values on a private close-on-exec channel
that its subprocesses never inherit, and it stops with
`environment_channel_closed` when the App goes away instead of serving with its
last snapshot. Restarting the App clears memory and requires the store to be
readable again.

Local one-shot CLI runs accept `--runtime-environment-file /path/to/descriptor.json`.
Bare CLI resident processes can load the descriptor at startup too; the reload
command above addresses the App owner and does not reload an unrelated standalone
CLI process. Keep credentials out of descriptor files, default variables and
command arguments.

For manual verification, demos, or support reproduction without touching the
normal user catalog, launch RielaApp with isolated roots:

```bash
HOME="$PWD/tmp/rielaapp-home" \
RIELA_APP_ROOT="$PWD/tmp/rielaapp-root" \
RIELA_APP_RIELA_EXECUTABLE="$PWD/.build/debug/riela" \
.build/debug/RielaApp \
  --import-workflow-or-package "$PWD/tmp/rielaapp-demo.rielapkg" \
  --open-workflows \
  --no-autostart-daemons \
  --project-root "$PWD/tmp/empty-project"
```

`RIELA_APP_HOME` or `--home-root <path>` can be used instead of `HOME`; `--app-root
<path>` can be used instead of `RIELA_APP_ROOT`.
For a local `.app` bundle, run `scripts/build-riela-menu-bar-app.sh` after
building; the plain `.build/debug/RielaApp` executable is the fastest path for
development and support reproductions.

## TypeScript Deletion Gate

`packaging/swift-deletion-readiness.json` is the deletion gate for the remaining
TypeScript handoff. The current implementation removed or ported the remaining
TypeScript-family source files for "Complete Riela TypeScript deletion
readiness after accepted Swift parity workflow". The gate now records
`migrationStatus=deletion_ready`, `allowsTypeScriptDeletion=true`, and
`typeScriptSourceDeletionReady=true` using reviewed-tree evidence bound to the
base commit and stable reviewed-file tree digest in
`packaging/swift-deletion-readiness-evidence.json`.
Ordinary review (`step7-review`) and adversarial review
(`step7-adversarial-review`) accepted the high-risk deletion-readiness run with
no high or mid findings; all 13 required domains record
`reviewDecision=accepted` and
`acceptedReviewNodeId=step7-adversarial-review`.
`official/cursor-sdk` remains distinct from `cursor-cli-agent` and selects the
`cursor-api` vendor in `agent-gateway`.
The completion plan is archived at
`impl-plans/completed/typescript-deletion-readiness-completion.md`; the active
Swift parity follow-through plan is no longer a deletion gate blocker.

The evidence manifest
`packaging/swift-deletion-readiness-evidence.json` records the command results
referenced by the gate. Representative accepted verification commands include:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk swift test --filter SourceDeletionReadinessTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk swift test --filter 'WorkflowCommandTests/testURLSessionWorkflowRunAutoImproveIsOptInOverRemotePayload|WorkflowCommandTests/testWorkflowRunEndpointUsesRielaAuthEnvironmentWithLegacyFallback|WorkflowCommandTests/testURLSessionWorkflowRunUsesSchemaAccurateRemotePayloadAndPausedStatus|CommandParsingTests/testParsesRemoteRunOptions'
jq -r '[.migrationStatus,.allowsTypeScriptDeletion,.typeScriptSourceDeletionReady,([.domains[].acceptedReviewNodeId]|map(select(.!=null))|length),([.domains[].reviewDecision]|unique|join(","))] | @tsv' packaging/swift-deletion-readiness.json
rg --files | rg '\.(ts|tsx|mts|cts|mjs)$'
{ printf 'reviewed-tree-v1\n'; git ls-files --cached --others --exclude-standard | grep -v '^packaging/swift-deletion-readiness-evidence\.json$' | sort | while IFS= read -r path; do [ -e "$path" ] || continue; printf 'path:%s\n' "$path"; if [ -x "$path" ]; then printf 'executable:true\n'; else printf 'executable:false\n'; fi; cat "$path"; printf '\n'; done; } | shasum -a 256
```

## Build

Use the flake shell and Xcode's Swift toolchain:

```bash
mise exec -- env \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk \
  /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build
```

Run tests:

```bash
mise exec -- env \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk \
  /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test
```

Run the CLI from source:

```bash
mise exec -- env \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk \
  /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela --help
```

## Included Source

This repository keeps the Swift runtime, tests, examples, workflow fixtures,
Homebrew packaging scripts, and flake development environment needed to build
and verify the Swift CLI.

The TypeScript workspace source is intentionally not copied into this repo.
Historical deletion-readiness evidence remains under `packaging/` where it is
needed by Swift tests and migration records.

# RielaApp private assistant runs

For non-trivial assistant requests, RielaApp creates a dedicated workflow in an
invocation-private root, requires the assistant to validate and run it directly,
and removes that root when the invocation finishes. The resulting session is
stored in the active profile's shared session store. The assistant creates one
run notebook, organized with workflow-ID / history-date folder tags, containing
Input, Work log, and Response notes; Response includes a
`#/runs/{sessionId}` Web link.
Folder identity is parent-scoped, so assistants use the workflow ID as the
parent and a reusable `history-YYYY-MM-DD` child, for example
`build-release/history-2026-08-03`.

Private here means isolation from Riela workflow registry, discovery, imports,
catalogs, and reuse. It is not a security boundary against arbitrary processes
running under the same OS account.

## Distributed workers

RielaApp and `riela serve` can host a worker controller, with outbound
`riela worker --config` processes and step-level worker ID/group selection.
See [controller and worker setup](docs/distributed-workers.md) for configuration,
workspace mapping, verified platform coverage and operational limits.

Command nodes can declare [execution locks](docs/command-execution-locks.md)
held through process completion and cancellation cleanup.

Command nodes can opt into non-authoritative failure metadata with
`command.failureDiagnostics: {"path": ["diagnostics"], "schema": ..., "maxBytes": 16384}`.
The trusted path selects an object; raw sibling fields are never retained. Opted-in
commands drain stdout while retaining at most 64 KiB plus one overflow byte; oversized
stdout is rejected even on exit zero, never accepted as a truncated result. Only a deliberately
restricted metadata schema is supported: closed objects (`additionalProperties:false`,
`properties`, `required`), bounded arrays (`items`, `maxItems`), enum-only strings,
bounded integers (`minimum`, `maximum`), booleans and null. On a nonzero exit,
unexpected fields, invalid schemas/values or oversized stdout produce only a
`rejected` receipt.
Validated metadata is stored in the execution's `command_failure_diagnostics`
backend event. Nonzero commands still fail; this metadata never becomes an accepted
output or root output. Default behavior persists no failed stdout. See
[the implementation plan](impl-plans/command-failure-metadata.md) for exact limits.

### Run a desktop configuration once

The authenticated desktop API accepts `POST /api/v1/instances/{identity}/runs`
with `x-riela-profile` and JSON `{"expectedProfile":"default","expectedRevision":0,"variables":{}}`.
Use the current profile/revision and exact configuration identity from the console.
Only these three body keys are accepted. The app validates readiness and rechecks
the configuration after asynchronous approval, then snapshots its trusted source,
working directory, scoped environment, default variables and node patches. Request
variables override matching default-variable keys; callers cannot override paths
or environment. The response is 202 with a launch ID; poll
`GET /api/v1/workflow-editor/launches/{id}` with the same profile header.
This starts one app-owned workflow run without starting/restarting its cron listener
or changing launch enablement. App shutdown cancels and awaits these launches with
other editor runs. The existing launch limit applies. Failed preflight returns only
a closed error code; the selected environment is not returned by this API.
