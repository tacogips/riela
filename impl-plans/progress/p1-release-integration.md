# p1-release-integration — Step 6 progress

Mode: `issue-resolution`. Issue: `tacogips/riela` Draft PR #113,
`comm-000002`. Plan: `impl-plans/active/work-runtime-p1-release-integration.md`;
design: `design-docs/specs/design-work-runtime-consolidation.md` §17.13.
Native Step 6 agent: `/root`, workflow execution
`nested-v1-12f27a3a2ea934101ea3b725ef55ed10c1fec772473b33f6317de919f1242f2a`.
Read-only Codex audits: `/root/intent_audit`, `/root/ledger_audit`,
`/root/docs_audit`. Runtime-owned accepted predecessors:
`p1-release-cli`, `p1-release-runtime`. Branch:
`fix/work-runtime-p1-release`; checkpoint HEAD:
`65c5eddb3fa7ef4d64c3474c98fe5852d6290cb8`.

## I1–I2: join and reconciliation — complete

The immutable CLI and runtime after:branch-evidence snapshots match all 14
owned file postimages on the current tree; see
`tmp/p1-release-remediation/p1-release-integration/catalog-continuation/intent-audit.json`.
The native dispatch drift in `Sources/RielaAddons/RielaAddons.swift`,
`Tests/RielaAddonsTests/AddonExecutionContractsTests.swift`, and
`impl-plans/progress/p1-release-cli.md` is the intended CLI catalog
continuation. The catalog descriptor resolves `riela/chat-reply-worker` version
1 and the regression preserves version 2 and unknown-name rejection. The two
runtime test postimages and other CLI fixture changes survived. All 12 shared
source/test paths were accounted for; no lost intent or repair was found. No
shared source or test file was edited by integration.

The 21-row cause/contract/path/regression ledger is
`tmp/p1-release-remediation/p1-release-integration/catalog-continuation/21-row-ledger.json`.
IDs 01–07 cover doctor dates; 08 persisted inactivity; 09–10 current CLI
subprocess discovery; 11 sandboxed fanout; 12 and 15–18 strict inspect and
validate diagnostics; 13 callable metadata; 14 chat-reply catalog; 19
admission ordering; 20–21 resolvable temporary add-ons. Each row has a focused
gate, and no historical assertion remains unclassified. The historical
Work/CLI/Core and full receipts under
`tmp/work-runtime-p1-7a-native-a2-a5/plans/p1-dispatch/attempt-6/` remain
failed evidence, not passing gates.

## I3: current-source verification — complete

All commands below ran serially in the foreground from the repository root
with the Xcode Swift toolchain environment specified by the plan. Complete
logs and terminal JSON receipts are under
`tmp/p1-release-remediation/p1-release-integration/catalog-continuation/attempt-1/`;
each receipt records argv, cwd, checkpoint, timestamps, exit and the tracked
source/test diff SHA-256
`0407c0e625f81da03c2553443d96f2c5b5f20e2314bc65702caf3465ccd5b025`.
No source/test edit occurred during the gates.

| Command suffix after `swift` | Exit | XCTest result | Log |
| --- | ---: | --- | --- |
| `build --scratch-path tmp/p1-release-remediation/build --product riela` | 0 | build passed | `build.log` |
| `test --scratch-path tmp/p1-release-remediation/build --filter AddonExecutionContractsTests` | 0 | 6 tests, 0 failures | `catalog.log` |
| `test --scratch-path tmp/p1-release-remediation/build --filter WorkflowHostCapabilityTests` | 0 | 20 tests, 0 failures | `host.log` |
| `test --scratch-path tmp/p1-release-remediation/build --filter 'WorkGuardDispatcherTests\|WorkflowRunnerAdmissionTests'` | 0 | 16 tests, 0 failures | `runtime.log` |
| `test --scratch-path tmp/p1-release-remediation/build --filter 'DoctorCommandTests\|WorkflowCommandCatalogTests\|WorkflowCommandTests\|WorkflowTemporaryRegistrationTests'` | 0 | 165 tests, 0 failures | `cli.log` |
| `test --scratch-path tmp/p1-release-remediation/build --filter 'DoctorCommandTests\|WorkGuardDispatcherTests\|WorkflowCommandCatalogTests\|WorkflowCommandTests\|WorkflowTemporaryRegistrationTests\|WorkflowRunnerAdmissionTests'` | 0 | 181 tests, 0 failures | `p1.log` |
| `test --scratch-path tmp/p1-release-remediation/build --filter 'TaskDispatcherIntegrationTests\|TaskRuntimeExampleTests\|TaskDispatcherTests\|WorkGuardDispatcherTests\|AgentDirectorTests\|AgentDirectorStoreTests\|DeterministicDirectorTests'` | 0 | 101 tests, 0 failures | `native.log` |
| `test --scratch-path tmp/p1-release-remediation/build --filter 'RielaAdaptersTests\|RielaServerTests\|RielaGraphQLTests'` | 0 | 194 tests, 1 skipped, 0 failures | `remote.log` |
| `test --scratch-path tmp/p1-release-remediation/build --filter 'RielaWorkTests\|RielaCLITests\|RielaCoreTests'` | 0 | 2,062 tests, 0 failures | `work-cli-core.log` |
| `test --scratch-path tmp/p1-release-remediation/build --no-parallel` | 0 | 2,719 XCTest cases, 2 skipped, 0 failures; 19 additional Swift Testing cases passed | `full.log` |

The remote and full suites skipped
`SurfaceParityGraphQLTests.testRegenerateGeneratedSDLWhenRequested` because
SDL regeneration belongs to `scripts/surface-parity/generate-sdl.sh`. The full
suite also skipped
`WorkflowEditorLiveAgentTests.testLiveCodexProducesIntermediateGraph`, an
opt-in live-provider check. Neither skip masks a ledger row. Native selection
includes remote dispatch/receiving tests; the remote selection includes
adapter, server and GraphQL coverage.

`changed-swift.nul` under `catalog-continuation/` contains the exact 11 changed
Swift paths. `xargs -0 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache
< tmp/p1-release-remediation/p1-release-integration/catalog-continuation/changed-swift.nul`
exited 0 (`lint-changed.log`). The plan's explicit 12-path strict SwiftLint
allowlist also exited 0 (`lint-allowlist.log`). The current scratch-built CLI
`workflow usage matrix-chat-reply --workflow-definition-dir examples --output json`
with isolated `HOME` exited 0 (`matrix-usage.log`). `git diff --check` and
`git diff --cached --check` exited 0 (`diff-check.log`,
`diff-cached-check.log`). The latter is an unstaged-tree check only; no Step 6
staging or Git write occurred.

## Pending downstream gates

I4 independent test-integrity, Sol adversarial and Astra combined-tree reviews;
I5 review-dependent shared docs, archival and indexes; and I6 Draft PR #113
body, exact-file commit, non-force push and local/remote/PR head equality are
owned by later workflow steps. They are not claimed by Step 6. No material
implementation finding or verification gap remains on the assigned I1–I3
scope. Source/test changes and predecessor progress files remain dirty for
review and exact-file finalization.

## Step 7–8 review and documentation

Independent test-integrity, Sol adversarial and Astra integration reviews
accepted the final combined tree with no findings. Step 7b `comm-000033`
skipped browser E2E: `git diff --name-only HEAD -- web && git diff --cached
--name-only -- web && git status --short -- web` exited 0 with no web paths.
The accepted source and tests have no browser-facing change.

Step 8 reviewed `README.md` and `.codex/skills/riela-impl-workflow/SKILL.md`.
The skill's documentation-refresh contract needs no edit. `README.md`,
`design-docs/specs/design-work-runtime-consolidation.md` §17.13,
`impl-plans/README.md`, and `impl-plans/progress/p1-dispatch.md` now describe the
current evidence. Completed predecessor plans moved to
`impl-plans/completed/work-runtime-p1-release-cli.md` and
`impl-plans/completed/work-runtime-p1-release-runtime.md`; the integration plan
stays active for I6. The accepted dispatch manifest retains its original
checkpoint and active plan paths as historical dispatch provenance. Draft PR
#113 body, exact-file commit, non-force push, and local/remote/PR head equality
remain pending. Complete command logs and terminal exits for source verification
are under `tmp/p1-release-remediation/p1-release-integration/catalog-continuation/attempt-1/`.
Step 8 `git diff --check && git diff --cached --check` exited 0; complete log
`tmp/p1-release-remediation/step8-docs/diff-check.log` and terminal status
`tmp/p1-release-remediation/step8-docs/diff-check.exit` record this docs gate.
