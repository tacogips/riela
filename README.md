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

Local agent backend ids remain explicit compatibility contracts:
`codex-agent`, `claude-code-agent`, and `cursor-cli-agent`. Official SDK adapter
parity is tracked separately; `official/cursor-sdk` is not aliased to
`cursor-cli-agent`.

Riela-owned environment names use the `RIELA_` prefix. Remote GraphQL workflow
runs read `RIELA_MANAGER_AUTH_TOKEN` and `RIELA_MANAGER_SESSION_ID`. Remote auto-improve input is opt-in:
`workflow run --endpoint ...` omits `autoImprove` by default and only sends the
supervision policy when `--auto-improve` is set.

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

## Riela Note

Riela Note is the local notebook and note store for markdown notes, provenance
aware tags, comments, links, file attachments, search, and workflow-backed note
automation. The CLI stores notes under `~/.riela/note` by default; set
`RIELA_NOTE_ROOT` or pass `--note-root <dir>` to use an isolated store.
RielaApp uses the active profile's note root under
`~/.riela/profiles/<profile>/note/`.

Common local commands:

```bash
riela note add --body '# Idea\n\nShip the small version first.' --tag idea
riela note list --limit 20 --output table
riela note search "small version" --tag idea
riela note show <note-id> --output text
riela note edit <note-id> --body-file ./updated.md
riela note tag <note-id> --add shipped --remove idea
riela note comment <note-id> --body "Reviewed."
riela note attach <note-id> ./diagram.png --role related
riela note readonly <note-id> --on
riela note delete <note-id>
```

Notebook, file-storage, and API-client management are in the same command
family:

```bash
riela note notebook create "Project notes"
riela note notebook list --output table
riela note storage migrate --all --to s3 --profile archive \
  --s3-endpoint https://s3.example.com --s3-region us-east-1 --s3-bucket notes
riela note storage gc --grace-hours 24
riela note auto-action retry
riela note client register "iPad" --output json
riela note client list --output table
riela note client revoke <client-id>
```

`riela note storage gc` reclaims file rows and blobs no note or notebook
references anymore and sweeps stray blob/temp files older than the grace
period (default 24 hours); referenced files still survive note deletion.
`riela note auto-action retry` reclaims interrupted auto-action dispatches
whose lease went stale and retries pending ones — dispatch rows are
lease-owned, so concurrent CLI or app processes never double-run a live
dispatch.

`riela note` executes note operations through the note GraphQL service against
the local store, so the CLI, built-in note add-ons, RielaNoteUI, and server note
surface share the same `NoteService` write path. Example workflow bundles live
under `examples/note-quick-memo`, `examples/note-pdf-ingest`,
`examples/note-youtube-transcript`, `examples/note-auto-tagging`,
`examples/note-agent`, `examples/note-config-agent`,
`examples/note-link-extract`, `examples/note-edit-rewrite`, and
`examples/note-selection-question`.

In the RielaApp Notes window, the note detail pane is a read-first vertical
reader: each note occupies one snapping page, and approaching either edge of a
mid-notebook window loads only the next bounded page instead of scanning the
whole notebook. Each page keeps **Ask agent** and **Add comment** one tap away
through the existing agent bar and comment service. **Ask agent** expands and
focuses the existing composer with the current note attached. Bounded page
loads are generation-guarded, so a late load from earlier navigation cannot
replace the note selected most recently. The header action row also carries an
**Edit** control at the top-left and **copy**, **download**, and **expand**
buttons at the top-right (copy/download/expand stay available on read-only
notes; only the Edit control is hidden). Pressing Edit disables pager movement,
enables manual markdown editing, and reveals an **"Ask for changes"** agent
pill. Submitting the pill
asks the edit agent to rewrite the note; on macOS you can also select text in
the body and press **⌘K** (or the floating "Ask for changes ⌘K" chip) to scope
the request to that selection, falling back to whole-note scope when the
selection is no longer valid. Agent rewrites land only in the edit draft for
review — nothing is persisted until you Save. The pill is backed by the
sequential `examples/note-edit-rewrite` workflow (`riela workflow run
note-edit-rewrite`), wired into RielaApp via
`RIELA_NOTE_EDIT_REWRITE_WORKFLOW_DIR` /
`RIELA_NOTE_EDIT_REWRITE_RIELA_EXECUTABLE` overrides; when no
`note-edit-rewrite` workflow is found the pill surfaces an
"edit agent is not configured" error instead of editing the draft.

While editing, the floating selection chip row also offers an
**"Ask question ⇧⌘K"** action next to "Ask for changes". With body text
selected it arms question mode on the top pill (separate from the rewrite
pathway): submitting sends the question plus the selected text to a new
selection-question pathway backed by the sequential
`examples/note-selection-question` workflow (`riela workflow run
note-selection-question`), wired into RielaApp via
`RIELA_NOTE_SELECTION_QUESTION_WORKFLOW_DIR` /
`RIELA_NOTE_SELECTION_QUESTION_RIELA_EXECUTABLE` overrides. A successful
answer is auto-saved as a `note-agent`-authored comment (blockquoted
selection + question + answer), the Comments section expands, and the pill
shows a transient "Saved as comment" caption; the note body/draft is never
modified, and failures persist nothing. Each comment gains a
**"Create notebook"** action that promotes it in one transaction into a new
notebook whose first note carries the comment body and links the source note
to that new note (`related`, human provenance), surfacing the link in the
detail Links section. The Agent tab query pathway is unchanged.

The regular-width RielaApp Notes workspace has a left pane with **Tree** and
**Notes** modes. Tree mode shows notebooks with lazily loaded note children and
a load-more row for large notebooks; explicit refreshes and note-store changes
invalidate the cached children so created and deleted notes reappear without an
app restart. Notes mode lists the selected notebook's notes in the same order as
the detail pager, highlights the current note, shows row positions such as
`3/12`, and selects through the same unsaved-edit guard as the pager and links.
Selecting a search result while body edits are unsaved dismisses the search
sheet and surfaces the root **Discard / Keep Editing** confirmation; Discard
navigates to the result and Keep Editing preserves the draft. Plain Return is
owned by the focused agent composer only: Return in note body, comment, tag,
rewrite, search, or link text inputs does not trigger agent send. The left and
right pane expansion state, selected Tree/Notes mode, and folded bottom-agent
bar persist across relaunches. Custom workspace panels use semantic SwiftUI
roles so the agent bar, attachment chips, pane backgrounds, and selected rows
remain legible in dark and light appearances.

The remote note API transport is not shipped yet. `riela note` and the built-in
note add-ons execute note GraphQL documents in-process against the local store.
`riela serve --note-api` currently prepares the note API configuration used by
the serving layer, but it does not bind a network socket or expose a remote URL.
Until a real listener lands, use `riela note client register --direct` for local
administrative token creation only; do not treat generated registration
challenge URLs as reachable remote endpoints.

## Apple Gateway Add-Ons

Riela includes built-in worker add-ons for local Apple integrations through an
external `apple-gateway` executable. The runtime invokes `apple-gateway` with
separate process arguments and does not vendor the gateway source. Executable
resolution is `addon.config.binaryPath`, then `APPLE_GATEWAY_BIN`, then `PATH`;
these add-ons reject authored `addon.env` and forward only the minimal process
environment required by the shared gateway bridge.

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
with auto-start off, so new users can inspect required credentials, attach an
env file, and activate only the instance they want to try.
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
and configuration panes.
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
`official/cursor-sdk` remains a distinct unavailable backend and is not aliased
to `cursor-cli-agent`.
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
nix develop -c env \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk \
  /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build
```

Run tests:

```bash
nix develop -c env \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk \
  /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test
```

Run the CLI from source:

```bash
nix develop -c env \
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
