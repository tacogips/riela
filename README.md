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
session id immediately and inspect it while the run is still active. Use
`--output json` for the legacy single JSON document or `--output text` for
human-readable output.

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
