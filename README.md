# Riela

<p align="center">
  <img src="img/riela.png" alt="Riela" width="720">
</p>

Riela is the Swift-native command line runtime.

The public executable is `riela`. The Swift module names still use
`Riela*` and workflow package manifests still use `riela-package.json`
for compatibility with existing workflow bundles.

## Swift Runtime Coverage

The Swift CLI owns the production command surface for local workflow execution,
session inspection, workflow packages, event sources, hooks, GraphQL/server
control-plane commands, direct `call-step`/`workflow-call` execution,
supervised `workflow run --auto-improve`, and reviewed `workflow self-improve`
mutation flows.

Client command routing, subcommand validation, positional arguments, and typed
option parsing use Apple's `swift-argument-parser`. Existing command names,
aliases, defaults, and output contracts remain stable behind the typed routes.

Runtime-owned records stay in the Swift session and runtime stores. Workers and
adapters return candidate outputs only; session ids, step execution ids,
workflow message ids, output publication, root output selection, continuation,
resume, rerun, replay, and GraphQL/session DTO projection are runtime-owned.

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

The default SQLite session-store connections wait for another process to
release its database lock, including during WAL initialization. Parallel runs
can share a session store without a fixed three-second contention timeout.
An interrupted process releases its OS locks; stop a waiting CLI process with
Ctrl-C if you do not want to wait for a long-running owner. Library callers can
request bounded waiting with `SQLiteOpenOptions(busyTimeoutMilliseconds: ...)`.
Only lock acquisition and WAL initialization are retried; workflow actions and
transaction bodies are not replayed.

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
fetch, mutable CRUD, activation, and consolidation; remote registry execution
is disabled unless an embedding host supplies the complete provider,
authorizer, and managed-reference configuration.

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
[implementation plan](impl-plans/active/workflow-graph-studio.md), with
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
disabled by default. **Open Riela...** opens the Tauri dashboard through native
IPC. **Start Web Server** starts the loopback listener explicitly; stopping that
listener does not stop RielaApp or its workflow instances.
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

Riela-owned environment names use the `RIELA_` prefix. Remote GraphQL workflow
runs read `RIELA_MANAGER_AUTH_TOKEN` and `RIELA_MANAGER_SESSION_ID`. Remote auto-improve input is opt-in:
`workflow run --endpoint ...` omits `autoImprove` by default and only sends the
supervision policy when `--auto-improve` is set.

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

## Runtime Data Garbage Collection

Runtime data GC is off by default. Enable automatic RielaApp cleanup by writing
the retention period to `~/.riela/config.json`:

```json
{
  "gc": {
    "retentionDays": 30
  }
}
```

RielaApp starts cleanup asynchronously during launch, so opening the app and
starting configured workflows do not wait for GC. `RIELA_GC_RETENTION_DAYS`
overrides the configuration file when an environment-based deployment is more
convenient.

Run the same cleanup manually with the CLI:

```bash
riela gc --scope all
riela gc --retention-days 30 --scope user
riela gc --retention-days 30 --scope project --dry-run --output json
```

With no configured or explicit retention period, `riela gc` reports that GC is
off and changes nothing. The collector removes expired session/runtime rows,
message-log rows, workflow-history snapshots, event
receipts, artifacts, and logs. Authored workflows, installed packages,
registries, profiles, notes, and configuration files are not GC targets.
`--scope all` covers both `~/.riela` and the current project's `.riela`;
RielaApp automatically collects only its configured user home.

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


## Workflow memory (short-term)

Riela owns short-term workflow memory in its own standalone SQLite store,
separate from kaiba notes. Workflows declare `memories` at the workflow and
node level; the `riela memory` commands and the `riela/memory-*` /
`riela/chat-persona-memory-*` add-ons persist records under `.riela/memory/`
(or the memory root given by `--memory-root`, addon config `memoryRoot`, or
`RIELA_MEMORY_ROOT`).

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

Relative routine-store paths resolve against `--working-dir`, and routine list
limits must be between 1 and 1,000 so CLI, GraphQL, and add-on queries stay
bounded.

Surfaces:

- CLI: `riela routine create --name <n> --task <t> (--schedule "0 */30 * * * *" | --every 30m) --workflow routine-task-runner [--completion-criteria <c>] [--timezone Asia/Tokyo] [--deactivate-workflow-on-completion]`,
  plus `list`, `inspect <id>`, `complete <id> [--note ...]`, `enable <id>`,
  `disable <id>`, and `delete <id>`.
- GraphQL (locally trusted hosts): `routines` / `routine` queries and
  `createRoutine` / `completeRoutine` / `setRoutineStatus` / `deleteRoutine`
  mutations, available through `riela graphql execute --query ...` and the
  RielaApp web `/graphql` endpoint.
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

Choose **Open Riela...** from the menu bar to open the shared dashboard in
Tauri. The Swift menu-bar process owns the profile and workflow runtime;
the Tauri child loads bundled assets and exchanges API requests over inherited
stdin/stdout pipes. Opening the desktop window does not start an HTTP listener.
Closing the window leaves the menu-bar app running; opening it again creates
a new window. Repeated open actions focus the existing window.

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

The explicit **Start Web Server** and **Open in Browser** menu actions remain
available. A saved server preference does not automatically open a listening
port when the menu-bar app starts.

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
Sources refresh after configuration changes. Profile and revision conflicts reject
stale updates. The server port is saved separately in `~/.riela/serve-web.json`;
restart `riela serve` to apply it. An explicit `--port` overrides the saved value.

Workflow studio uses the same editor runtime in the desktop and browser: copy a
source bundle, edit definitions and file-backed node settings, generate graph
changes with the configured assistant, save a revision, activate and run it, and
inspect recorded inputs and outputs. Runs use `--session-store` when supplied,
otherwise the active profile's session directory. Browser-hosted editor jobs are
cancelled when the serve process shuts down.

In server mode, select an instance to start, stop or restart it and change its
launch enablement. Starting marks it active and enabled; stopping clears its
active state. `riela serve` starts saved instances that are both active and
enabled at launch. Configuration and event-source changes restart running
instances. Switching profiles stops the previous profile's instances before
starting the selected profile's enabled active instances; server shutdown stops
all owned instances. Instance runs and their browser history share the profile's
session directory, or the explicit `--session-store` override.

For browser access on a public listener, set `RIELA_WEB_TOKEN` to an operator
access token and `RIELA_WEB_ORIGIN` to the exact browser origin, including the
scheme and non-default port, with no trailing slash. For example, with the token
already set in the process environment:

```bash
RIELA_WEB_ORIGIN=https://riela.example riela serve --host 0.0.0.0 --port 8787
```

Use an HTTPS reverse proxy for remote connections; `riela serve` itself speaks
HTTP. Preserve the public Host header through the proxy. The login screen asks
for the token, which grants access to the server's profiles, configuration and
workflow execution. It stays in page memory and must be entered again after
reloading. API responses are not cached, and authenticated mutations still
require the matching Origin, CSRF token and profile. Missing or invalid public
access configuration leaves browser APIs unavailable. Explicit token/origin
configuration also requires authentication on a loopback listener. CLI and
manager GraphQL clients retain their separate, existing credential contract.

## RielaApp Packages And Profiles

RielaApp imports workflow folders, package folders, and `.rielapkg` archives
from the menu bar item:

```text
Instances... > Add Workflow/Package...
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

Imported packages are stored under the selected RielaApp profile. The Instances
window separates workflow/package sources from workflow instances. An instance is
the configured run unit RielaApp starts: a workflow source plus the saved
environment file, inline environment values, default variables, working
directory, enabled state, and active state. The source column shows `profile`,
`user`, or `project` so profile-scoped imports can be separated from user-level
or project-level workflow sources that are visible in every profile.
On a fresh install, the default profile is seeded with inactive starter
packages for a Discord Yuki chat bot, a Telegram Yuki chat bot, a Slack chat
bot, and a gmail-gateway latest-mail digest. They appear in the Instances window
with auto-start off, so new users can inspect required credentials in Web
Config and activate only the instance they want to try.
The Instances table uses `Active` for the saved profile preference that starts
an instance when RielaApp launches or when the profile is started; `Status`
shows the current runtime state. Toggling `Active` starts or stops that instance
immediately. Selecting an instance shows its source path, event sources, profile
scope, active preference, instance variables, and runtime detail below the
toolbar.
The search fields in Instances, Workflow Sources, Add Instance, and Marketplace
filter their already-loaded lists as you type; matching is case- and
diacritic-insensitive, and clearing a search restores the full list. The Back
control appears only when the current pane has a real back destination, so it is
hidden at the Instances overview root and available throughout supported detail
panes. Configuration rows are read-only and route to Web Config; native
instance, Assistant, and Profile panes do not expose configuration editors.
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
