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
sudo apt-get install -y ca-certificates curl libsqlite3-0
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
