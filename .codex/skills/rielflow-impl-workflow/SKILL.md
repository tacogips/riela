---
name: rielflow-impl-workflow
description: Use the codex-design-and-implement-review-loop workflow for Riela issue-resolution implementation work, including documentation refresh, review gates, deletion-readiness evidence, and commit handoff.
---

# Riela Implementation Workflow

Use this skill for Riela implementation work that changes behavior, fixes bugs,
or closes migration parity gaps. The workflow id is
`codex-design-and-implement-review-loop`.

## Mode

Run behavior-changing work in `issue-resolution` mode unless the user explicitly
requests a planning-only handoff. Keep issue references, implementation-plan
paths, review communications, and backend ids explicit in workflow outputs.

Important references for the full Swift parity handoff:

- issue reference: `Riela full Swift parity TASK-003 through TASK-008`
- implementation plan: `impl-plans/active/swift-cli-runtime-parity-gap-closure.md`
- reference repository root: `/Users/taco/gits/tacogips/rielflow`
- target repository root: `/Users/taco/gits/tacogips/riela`
- codex-agent references: `codex-agent`, `claude-code-agent`, `cursor-cli-agent`

## Review Contract

High-risk runs require ordinary review, test-integrity review, and adversarial
review before documentation refresh and commit handoff. For the Swift parity
run, `step7-review` accepted with `reviewDecision=accepted_requires_adversarial_review`
and `step7-adversarial-review` accepted with
`reviewDecision=accepted_no_high_or_mid_adversarial_findings`.

Do not describe TypeScript source deletion as complete unless
`packaging/swift-deletion-readiness.json` has
`migrationStatus=deletion_ready`, `allowsTypeScriptDeletion=true`, and
`typeScriptSourceDeletionReady=true`. Current accepted behavior keeps deletion
blocked until accepted review metadata is recorded for all required domains;
source removal remains a separate reviewed implementation step. Keep
`impl-plans/active/swift-cli-runtime-parity-gap-closure.md` active while that
gate is blocked, even after Step 7 and adversarial review accept the current
Swift parity implementation.

## User-Facing Documentation

Step 8 documentation refresh must review and update:

- `README.md`
- `.codex/skills/rielflow-impl-workflow/SKILL.md`
- any directly affected user-facing workflow skill or repository-facing README
  section

Document the shipped Swift behavior, not placeholder behavior. Preserve the
runtime contract that workers and adapters return candidate outputs while the
runtime owns session ids, workflow messages, communication ids, output
publication, final root output selection, continuation, resume, rerun, replay,
and GraphQL/session DTO projection.

If the Step 8 implementation-plan completion check archives plans or refreshes
`impl-plans/README.md` after the first documentation pass, rerun the docs
refresh and reconcile `README.md`, this skill, and the plan index before commit
generation. Completed plans belong under `impl-plans/completed/`; blocked
deletion-readiness follow-through remains under `impl-plans/active/`.
For this run, `native-command-bash-script-dispatch` and
`workflow-registry-run-temp-checkout` were archived as completed on 2026-06-16,
while `swift-cli-runtime-parity-gap-closure` remains active.

Riela-owned environment variables use `RIELA_` names. Remote GraphQL workflow
runs use `RIELA_MANAGER_AUTH_TOKEN` and `RIELA_MANAGER_SESSION_ID`, with legacy
`RIEL_MANAGER_AUTH_TOKEN` and `RIEL_MANAGER_SESSION_ID` fallback. Remote
`autoImprove` serialization is opt-in: default and `--no-auto-improve` runs
omit the supervision policy, while `--auto-improve` sends it.

## Verification To Report

Keep verification commands explicit in workflow outputs. Relevant accepted
commands for the current Swift parity run include:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk swift test --filter 'WorkflowCommandTests/testURLSessionWorkflowRunAutoImproveIsOptInOverRemotePayload|WorkflowCommandTests/testWorkflowRunEndpointUsesRielaAuthEnvironmentWithLegacyFallback|WorkflowCommandTests/testURLSessionWorkflowRunUsesSchemaAccurateRemotePayloadAndPausedStatus|CommandParsingTests/testParsesRemoteRunOptions'
git diff --check -- Sources/RielaCLI/WorkflowCommands.swift Tests/RielaCLITests/WorkflowCommandTests.swift Tests/RielaCLITests/CommandParsingTests.swift impl-plans/active/swift-cli-runtime-parity-gap-closure.md
git diff --check -- README.md .codex/skills/rielflow-impl-workflow/SKILL.md impl-plans/README.md
jq -r '[.migrationStatus,.allowsTypeScriptDeletion,.typeScriptSourceDeletionReady,([.domains[].acceptedReviewNodeId]|map(select(.!=null))|length),([.domains[].reviewDecision]|unique|join(","))] | @tsv' packaging/swift-deletion-readiness.json
```
