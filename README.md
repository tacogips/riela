# Riela

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

Local agent backend ids remain explicit compatibility contracts:
`codex-agent`, `claude-code-agent`, and `cursor-cli-agent`. Official SDK adapter
parity is tracked separately; `official/cursor-sdk` is not aliased to
`cursor-cli-agent`.

Riela-owned environment names use the `RIELA_` prefix. Remote GraphQL workflow
runs read `RIELA_MANAGER_AUTH_TOKEN` and `RIELA_MANAGER_SESSION_ID`, with
legacy `RIEL_MANAGER_AUTH_TOKEN` and `RIEL_MANAGER_SESSION_ID` fallback for
existing Rielflow-authored data. Remote auto-improve input is opt-in:
`workflow run --endpoint ...` omits `autoImprove` by default and only sends the
supervision policy when `--auto-improve` is set.

## TypeScript Deletion Gate

`packaging/swift-deletion-readiness.json` is the deletion gate for the remaining
TypeScript handoff. The current accepted workflow scope is
`codex-design-and-implement-review-loop` for "Riela full Swift parity TASK-003
through TASK-008"; ordinary review and adversarial review accepted the latest
implementation with no high or mid findings at `step7-review` and
`step7-adversarial-review`.

The checked-in gate still keeps `migrationStatus=incomplete`,
`allowsTypeScriptDeletion=false`, and `typeScriptSourceDeletionReady=false`
until accepted review metadata is recorded for all required domains. Actual
TypeScript source removal remains a separate reviewed implementation step.
The active plan `impl-plans/active/swift-cli-runtime-parity-gap-closure.md`
therefore stays active as deletion-gate follow-through, while unrelated
completed implementation plans are archived under `impl-plans/completed/` and
listed in `impl-plans/README.md`. The current index records
`native-command-bash-script-dispatch` and
`workflow-registry-run-temp-checkout` as completed on 2026-06-16.

The evidence manifest
`packaging/swift-deletion-readiness-evidence.json` records the command results
referenced by the gate. Representative accepted verification commands include:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk swift test --filter 'WorkflowCommandTests/testURLSessionWorkflowRunAutoImproveIsOptInOverRemotePayload|WorkflowCommandTests/testWorkflowRunEndpointUsesRielaAuthEnvironmentWithLegacyFallback|WorkflowCommandTests/testURLSessionWorkflowRunUsesSchemaAccurateRemotePayloadAndPausedStatus|CommandParsingTests/testParsesRemoteRunOptions'
jq -r '[.migrationStatus,.allowsTypeScriptDeletion,.typeScriptSourceDeletionReady,([.domains[].acceptedReviewNodeId]|map(select(.!=null))|length),([.domains[].reviewDecision]|unique|join(","))] | @tsv' packaging/swift-deletion-readiness.json
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
