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
riela note client register "iPad" --output json
riela note client list --output table
riela note client revoke <client-id>
```

`riela note` executes note operations through the note GraphQL service against
the local store, so the CLI, built-in note add-ons, RielaNoteUI, and server note
surface share the same `NoteService` write path. Example workflow bundles live
under `examples/note-quick-memo`, `examples/note-pdf-ingest`,
`examples/note-youtube-transcript`, `examples/note-auto-tagging`,
`examples/note-agent`, `examples/note-config-agent`,
`examples/note-link-extract`, `examples/note-edit-rewrite`, and
`examples/note-selection-question`.

In the RielaApp Notes window, the note detail pane carries a header action row:
an **Edit** control at the top-left and **copy**, **download**, and **expand**
buttons at the top-right (copy/download/expand stay available on read-only
notes; only the Edit control is hidden). Pressing Edit enables manual markdown
editing and reveals an **"Ask for changes"** agent pill. Submitting the pill
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

The remote note API transport is not shipped yet. `riela note` and the built-in
note add-ons execute note GraphQL documents in-process against the local store.
`riela serve --note-api` currently prepares the note API configuration used by
the serving layer, but it does not bind a network socket or expose a remote URL.
Until a real listener lands, use `riela note client register --direct` for local
administrative token creation only; do not treat generated registration
challenge URLs as reachable remote endpoints.

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
