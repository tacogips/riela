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
`--overwrite` to replace an existing entry. The legacy physical directory is
retained for read compatibility; public results use `provenance: "mutable"`,
`mutable: true`, and `activationState`. `--temporary` and
`--exclude-temporary` remain deprecated aliases for `--mutable` and
`--exclude-mutable` until the next major CLI release. Name resolution considers mutable entries after
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

Production execution for Claude Code, Codex, Cursor CLI, Cursor Cloud Agents,
OpenAI, Anthropic, Gemini, and OpenRouter is supplied by the sibling
`agent-gateway` package, which speaks the Agent Client Protocol (ACP,
https://agentclientprotocol.com). Riela drives one `agent-gateway client`
turn per step: the prompt travels as ACP content blocks on stdin, streaming
output arrives as `session/update` notifications (`agent_message_chunk`,
`agent_thought_chunk`, tool call updates) on stdout, and the `session/prompt`
response carries the final text, usage, and resumable vendor session id in
`_meta.agentGateway`. stderr stays reserved for diagnostics. Set
`RIELA_AGENT_GATEWAY_EXECUTABLE` when `agent-gateway` is not available on
`PATH`.

RielaApp also uses agent-gateway's model catalog when the Assistant settings
select OpenAI API, Claude API, or Cursor API. The live vendor response replaces
the bundled suggestions for that settings session. Missing credentials,
listing failures, empty responses, and CLI-backed vendors fall back to the
bundled catalog, and an already selected live model remains usable after it is
saved.

RielaApp is a resident workflow process; its HTTP listener is optional and is
disabled by default. Opening Web Config starts the loopback listener on demand,
and stopping that listener does not stop RielaApp or its workflow instances.
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
`GoogleServiceGatewayCore` Swift library directly. The read add-on supports
`services.list`, `services.get`, and `operations.get`; the write add-on supports
`services.enable`, `services.disable`, and `services.batchEnable`. Set the
operation in `addon.config.operation` and pass request fields through
`addon.inputs`.

Credentials require an explicit `addon.env.GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN`
binding. Ambient process credentials are not forwarded implicitly, and the
read add-on cannot invoke a mutation.

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
message-log rows, legacy session files, workflow-history snapshots, event
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

Riela consumes kaiba as an addon knowledge/context source. The built-in
`kaiba/*` addons expose kaiba-client-equivalent operations to workflows:

- `kaiba/note-create`, `kaiba/note-update`, `kaiba/note-get`,
  `kaiba/note-search`, `kaiba/note-tag-search`,
  `kaiba/note-graph-neighbors`, `kaiba/note-chain`, `kaiba/note-tag-apply`,
  `kaiba/note-attach-file`, `kaiba/note-attachments`, `kaiba/note-memos`,
  `kaiba/note-comment-add`, `kaiba/notebook-ingest-pages`,
  `kaiba/document-import`, `kaiba/note-conversation-save`
- Long-term memory: `kaiba/memory-consolidate`, `kaiba/memory-recall`
- Raw GraphQL: `kaiba/note-graphql-document`

Addons operate on a local note root (config `noteRoot`, env
`KAIBA_NOTE_ROOT`, default `~/.kaiba`) through the imported kaiba library, or
remotely against a running `kaiba serve` by setting `endpoint` in the addon
config plus an API key in the env var named by `apiKeyEnv` (default
`KAIBA_API_KEY`; issue keys with `kaiba client issue`).

`kaiba/document-import` consumes a local `path` (normally
`event.input.file.absolutePath` from a `file-change` source), converts PDF,
EPUB, office, CSV, and related formats through Kaiba's in-process AnydocKit,
and stores the original as a notebook attachment. Set node input `ocr: true`
for Kaiba's agent-gateway image OCR, and `translate: true` plus
`targetLanguage` for post-import notebook translation. OCR and translation
vendor/model fields can be supplied directly (`ocrVendor`/`ocrModel`,
`translationVendor`/`translationModel`) or loaded from the Kaiba config named
by addon config `configPath` / `KAIBA_CONFIG_PATH`. Kaiba 0.1.6 OCR applies to
standalone PNG/JPEG/GIF/WebP inputs; PDF and EPUB use AnydocKit conversion.

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

Riela always accesses in-process document conversion through Kaiba's
`AnydocKit` product from `anydoc-swift`; it does not build or invoke the native
converter directly. On macOS, `anydoc-swift` automatically uses its published
XCFramework, so building Riela does not require Cargo or `PKG_CONFIG_PATH`.
Platform-specific native integration remains encapsulated by `anydoc-swift`.

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

## Document Conversion Add-On

`riela/file-markdown-convert` converts local documents (pdf, doc, docx, ppt,
pptx, xls/xlsx, odt, ods, odp, rtf, epub, csv) to GitHub-Flavored Markdown
through the external [`anydoc-swift`](https://github.com/tacogips/anydoc-swift)
executable, which wraps [firecrawl/anydoc](https://github.com/firecrawl/anydoc).
The runtime does not vendor the converter: it invokes
`anydoc-swift convert <path> --json` with separate process arguments and reads
the result envelope, so a failed document keeps its machine-readable error kind
(`unsupported`, `malformed`, `encrypted`, `resourceLimit`, `io`, ...) instead of
a prose message. Version 0.1.1 or newer is required.

Executable resolution is `addon.config.binaryPath`, then `ANYDOC_SWIFT_BIN`,
then `PATH`; document paths come from `addon.inputs.path` / `addon.inputs.paths`
only. The add-on rejects authored `addon.env`, caps input size, document count,
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

Riela includes built-in worker add-ons for local Apple integrations through an
external `apple-gateway` executable. The runtime invokes `apple-gateway` with
separate process arguments and does not vendor the gateway source. Executable
resolution is `addon.config.binaryPath`, then `APPLE_GATEWAY_BIN`, then `PATH`;
these add-ons reject authored `addon.env` and forward only the minimal process
environment required by the shared gateway bridge.

Apple Mail access requires `apple-gateway` 0.1.6 or newer so the gateway can
adapt to the installed Mail Envelope Index schema. Check or update a Homebrew
installation with `apple-gateway --version` and `brew upgrade apple-gateway`.

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
sudo apt-get install -y ca-certificates curl libcurl4 libsqlite3-0
version="$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/tacogips/riela/releases/latest | sed 's#.*/v##')"
curl -LO "https://github.com/tacogips/riela/releases/download/v${version}/riela-${version}-linux-x64.tar.gz"
curl -LO "https://github.com/tacogips/riela/releases/download/v${version}/riela-${version}-linux-x64.tar.gz.sha256"
sha256sum -c "riela-${version}-linux-x64.tar.gz.sha256"
tar -xzf "riela-${version}-linux-x64.tar.gz"
sudo install -m 0755 bin/riela /usr/local/bin/riela
riela --version
```

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
bot, and a mail-gateway latest-mail digest. They appear in the Instances window
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
