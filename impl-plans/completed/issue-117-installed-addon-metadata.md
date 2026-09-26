# Issue 117: Installed package add-on metadata

## Contract

- planId: `issue-117-installed-addon-metadata`
- planPath: `impl-plans/completed/issue-117-installed-addon-metadata.md`
- dependsOn: `[]` (single implementation unit; tasks below form a serial DAG)
- workflowMode: `issue-resolution`
- issueReference: https://github.com/tacogips/riela/issues/117
- designReference: `design-docs/specs/design-installed-package-workflow-resolution.md#issue-117-preserve-locked-add-on-metadata-during-validateinspect`
- designReview: `accept`, Step 3, `comm-000004`; no findings or revisions.
- codexAgentReferences: `[]`; Cursor behavior mapping/divergences: not applicable.
- branch: `fix/example-contract-migration`; intake source HEAD: `0c66cb19ffa2619af440ab640701756d35b443a4`.
- progressPath: `impl-plans/progress/issue-117-installed-addon-metadata.md`.
- evidenceRoot: `tmp/issue-117/implementation/`.
- sharedPaths: `[]`; one implementation owner, no concurrent file writers.

User intent: ordinary validate/inspect must retain the owning installed workflow
package's locked external native/container add-on metadata, including YouTube-style
references, without allowing unrelated or mismatched add-ons. Preserve #116 and
the 75-example schema correction already in the branch. The accepted runtime input
is authoritative; the issue body was unavailable at intake. This plan does not
require rediscovering the running workflow's installation or provenance.

Non-goals: provider/model calls, native/container execution, release, merge,
changes in riela-packages, schema migration, new registry protocols, global vendor
allowlists, generalized resolver frameworks, broad cleanup, and new worktrees.
Do not edit existing isolated-project evidence in the package repository.

## Write paths and intended changes

These are bounded permissions, not a requirement to change every source file.
Record the exact subset selected after reproduction in the progress log.

| Path | Intended change |
| --- | --- |
| `Sources/RielaCLI/WorkflowResolution.swift` | Preserve/recover verified owning-package metadata when the selected installed workflow resolves; preserve candidate precedence and scope. |
| `Sources/RielaWorkflowRegistry/WorkflowRegistryBundleLoader.swift` | If the loss occurs here, carry verified manifest and package directory together into the resolved bundle; never attach metadata by name alone. |
| `Sources/RielaCLI/WorkflowValidateInspectCommands.swift` | Consume the retained metadata; require unique verified dependency matching and keep native inspection summaries consistent with host projection. |
| `Sources/RielaCLI/WorkflowInstalledAddonRequirements.swift` (new only if needed) | Small responsibility-based extraction of installed-dependency projection/verification from the nearly 1000-line command file; no new framework or parallel lookup policy. |
| `Tests/RielaCLITests/WorkflowInstalledAddonMetadataTests.swift` (new) | Real filesystem-resolution fixtures and positive/negative CLI regression matrix. |
| `Tests/RielaCLITests/WorkflowHostCapabilityTests.swift` | Only adjust existing assumptions affected by verified matching; retain built-in/local-command checks. If edited, extract a coherent test group to the following companion so this file falls below 1000 lines. |
| `Tests/RielaCLITests/WorkflowHostCapabilityTests+AddonRequirements.swift` (new only if needed) | Moved add-on requirement tests with no unrelated behavior changes. |
| `design-docs/specs/design-installed-package-workflow-resolution.md` | Post-review implementation/evidence status update within the accepted addendum. |
| `README.md` | Only a directly affected installed-workflow validate/inspect clarification, if existing text is inaccurate; otherwise record review/no change. |
| `impl-plans/completed/issue-117-installed-addon-metadata.md` | Task completion/evidence pointers only, under serial ownership. |
| `impl-plans/progress/issue-117-installed-addon-metadata.md` | Owner's progress, findings, commands, exit statuses, and evidence pointers. |
| `tmp/issue-117/` | Isolated fixtures, verification driver, snapshots, logs; never stage. |

`Sources/RielaCore/WorkflowRequirements.swift` is a read-only invariant reference:
retain its `unresolvedAddonExecutable` guard and neutral host requirement model.
Read existing RielaAddons manifest/integrity/native resolver code and reuse its
validation mechanisms. Do not copy an alternative lock-validation system. If an
additional production file is demonstrably necessary, document the concrete
accepted requirement and obtain plan revision through the workflow before editing
outside the allowlist. No lockfile, shared index, package digest, or broad formatting
change is expected. Documentation-only edits do not require package digest refresh.

## Invariants and implementation decisions

1. Package ownership requires canonical directory equality with the manifest's
   declared workflow directory and package containment. Do not use a name/vendor
   prefix as evidence. Keep full scoped IDs, package version and integrity identity.
2. Carry manifest and package directory as one consistent context. Direct selection
   of a proven installed workflow retains context; a copied/unrelated workflow
   with the same workflow/add-on name does not inherit it. Do not globally scan
   installations to authorize unrelated direct workflows.
3. Match dependencies uniquely using full package identity, locked package and
   add-on versions, declared digests, execution kind, and existing scope rules.
   Missing metadata or mismatches fail closed. Omitted node version binds to the
   lock; ambiguous unqualified references fail. Do not use `first`/`contains` to
   turn multiple matches into a successful dependency authorization.
4. Verified native/container dependencies need no invented host executable.
   Preserve required package/node environment bindings and independent readiness
   checks. Built-ins, declarative add-ons, and local-command executability keep
   their current contracts. Do not start helpers/containers to validate metadata.
5. Resolve each reachable callee with its own package context. Caller locks must
   not authorize callee nodes. Keep validate/inspect diagnostics and provenance
   consistent without changing existing JSON or exit semantics.
6. Scope precedence, activation, package mutability, containment and integrity
   checks remain intact. This change must not weaken native bundle/closure checks.

## Tasks and dependencies

### TASK-117-01 — Reproduce and freeze evidence (dependsOn: [])

Fresh-read the listed source boundaries and the accepted design. Inspect repository
Swift conventions and apply the local Swift coding skill during implementation.
Use `CLIRuntimeEnvironment.$overrides` in in-process tests for an isolated home;
never change the agent shell's HOME. All fixtures live under `tmp/issue-117/`.

Create the new test suite and deterministic fixture builder using actual package
manifest validation/integrity APIs. Fixture layout is
`tmp/issue-117/implementation/project/.riela/packages/@issue117/youtube-flow/`,
with `workflowDirectory: workflows/youtube-flow`, workflow ID `youtube-flow`,
and a `@issue117/youtube-tools` dependency containing locked native/container
add-ons. Use exact internally consistent package versions and digest fields
computed from synthetic content. Set up isolated user scope at
`tmp/issue-117/implementation/home/`. Tests can use unique children beneath
`tmp/issue-117/tests/` for concurrency safety; retain the deterministic CLI fixture.

Run the new tests before the fix and retain the failing command/JSON/diagnostic.
Trace where package context is absent or inconsistent, recording observed bundle
manifest/directory and selected workflow path. Test ordinary package target,
installed workflow-name selection, and direct installed-directory selection.
A failing stub-only test is insufficient. Do not alter production code until the
baseline proves the accepted bug or records a precise contradictory observation.
If the positive baseline unexpectedly passes, isolate the missing case instead of
asserting reproduction. Deliver baseline log and a brief causal trace.

### TASK-117-02 — Narrow metadata correction (dependsOn: [TASK-117-01])

Repair the confirmed source boundary with the smallest allowed change. Preserve
metadata from a verified owning package through bundle resolution; validate the
selected dependency using existing installed-package/add-on metadata checks before
projecting a host requirement. Keep ownership association and matching separate
from host executability. Update native inspection summaries if necessary so they
do not select a different or ambiguous lock from the host projection.

The command file currently has 994 lines. Extract only the related requirement
projection responsibility if edits would exceed 1000 lines. Do not expand the
1081-line host test file; prefer the new focused test suite. If existing tests
must change, extract their add-on group as specified above. Run focused tests after
edits and record the actual changed-file subset and rationale.

### TASK-117-03 — Complete regressions and verification (dependsOn: [TASK-117-02])

The real-resolver test matrix must assert both commands' JSON diagnostics, not only
exit codes. Cover all rows:

| Case | Required evidence |
| --- | --- |
| Valid native and container dependencies | Package identity/locks preserved; no false unresolvedAddonExecutable; no runtime execution. |
| Scoped package IDs and omitted node version | Exact scoped identity and locked version used. |
| Name and direct-directory selection | Same verified ownership; existing source scope preserved. |
| Unrelated/copied direct workflow with identical names | No inherited dependency authorization; unresolved diagnostic. |
| Unknown or missing dependency | No resolved host requirement; specific diagnostic. |
| Ambiguous unqualified add-on | Reject multiple permitted matches; qualified reference resolves only its exact package. |
| Wrong package identity/version, add-on version, digest, execution kind | Each mutation independently rejected; never silently choose another installed version. |
| Project/user collisions | Existing precedence retained for workflow and dependency selection; lower-priority metadata cannot substitute for the selected package. |
| Required package/node environment | Bindings survive projection and strict host validation. |
| Cross-workflow callee | Callee uses its own locks; caller-only lock does not authorize it. |
| Built-in, declarative, local-command | Existing catalog behavior and executable availability checks remain covered. |

Author `tmp/issue-117/implementation/verify.py` as a throwaway foreground driver,
not production tooling. It must execute the exact command matrix below with
argument arrays, explicit cwd and child-only HOME for CLI fixtures, separate
stdout/stderr logs, final numeric exit status, and JSON parsing/assertions. It must
wait for every child. Preserve failed attempt directories; no log overwrites.
The build binary is `.build/debug/riela` resolved from this source checkout after
a successful source build, never the installed `riela` on PATH.

### TASK-117-04 — Serial reconciliation and implementation handoff (dependsOn: [TASK-117-03])

Re-read all final files and compare intent snapshots and pre/post hashes. Repair
lost or conflicting changes serially; rerun only affected gates after repairs.
Review README and the design against the implemented behavior; record any needed
post-review documentation task. Record completed implementation/test tasks and
all precisely classified failures in the progress log. No high/mid implementation
finding or missing required implementation verification may be called complete.
Formal independent review, final documentation, commit and push remain downstream;
their pending status alone does not make Step 6 implementation incomplete.
After Step 7 `comm-000013`, TASK-117-04 also requires explicit ambiguous
same-scope workflow rejection before lower-priority package selection and
declared dependency-registry equality with installed/locked metadata. Both
repairs and final-source evidence are recorded in the plan-local progress log;
independent rereview accepted them in `comm-000017`.

### TASK-117-05 — Reviewed finalization (dependsOn: [TASK-117-04, external-independent-review-accept])

Downstream workflow owner records the independent review decision and addresses
all high/mid findings, updates design/README only within accepted scope, and reruns
affected checks. Serial finalization owns staging/index access and any plan
archiving. Commit the exact accepted source/test/doc allowlist and non-force push
`fix/example-contract-migration` to origin using the workflow's authorized Git
gates. Verify committed files and local/remote commit equality. No release/merge.
Leave migration verification to the package repository owner; do not modify it.

## Exact verification commands and evidence

Run from the repository root unless otherwise stated. Use the Xcode toolchain:

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter WorkflowInstalledAddonMetadataTests
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter WorkflowHostCapabilityTests
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint
python3 tmp/issue-117/implementation/verify.py
git diff --check
```

Swift tests must report a nonzero selected test count and zero failures. The first
new-suite baseline is expected to fail for the reproduced bug; label it baseline,
never a passing gate. Build is the Swift compile/typecheck gate. SwiftLint must
run; classify pre-existing warnings/errors separately and repair introduced ones.
No web typecheck is required because no web files change.

The driver executes these concrete CLI commands with cwd
`tmp/issue-117/implementation/project` and child HOME set to the absolute path of
`tmp/issue-117/implementation/home` (resolve both relative to repository root):

```bash
../../../../.build/debug/riela workflow validate @issue117/youtube-flow --scope project --output json
../../../../.build/debug/riela workflow inspect @issue117/youtube-flow --scope project --output json
../../../../.build/debug/riela workflow validate youtube-flow --scope project --output json
../../../../.build/debug/riela workflow inspect youtube-flow --scope project --output json
../../../../.build/debug/riela workflow validate youtube-flow --workflow-definition-dir .riela/packages/@issue117/youtube-flow/workflows/youtube-flow --output json
../../../../.build/debug/riela workflow inspect youtube-flow --workflow-definition-dir .riela/packages/@issue117/youtube-flow/workflows/youtube-flow --output json
```

Create only the installation layout/linkage that actual installation uses; do not
invent a test-only name alias or insert the manifest at the workflow root to hide
the bug. Record fixture package identities and computed digests before commands.
For native/container variants, run the same six commands against separately
rebuilt fixture states, preserving results under distinct case names.

From repository root, the driver executes `.build/debug/riela workflow validate
NAME --workflow-definition-dir examples --output json` for EACH name in the exact
inventory below, once per final attempt. Compare discovered workflow.json paths
against this inventory and fail on count/set mismatch. Require 75 complete JSON
results and statuses; report valid/invalid counts and every diagnostic. Do not
reuse the older #116 74/75 report: intake says its schema failure was corrected.
All passing is preferred; any remaining failure needs exact command, diagnostic,
baseline evidence when available, and review disposition. An introduced failure
or unexplained missing result blocks implementation acceptance.

```text
apple-calendar-fetch
apple-clock-alarms-list
apple-gateway-admin
apple-gateway-packaging-plan
apple-mail-list
apple-note-create
apple-note-read
apple-notes-list
apple-notifications
apple-reminders-list
chat-event-attachment-judgement
chat-reply-webhook
chat-supervisor-collaboration
claude-riela-claude-worker
claude-riela-codex-coding
codex-codex-topic-debate
design-and-implement-review-loop
design-and-implement-review-loop-feature-plan
discord-agent-trio-chat
discord-codex-chat
discord-persona-chat
dispatcher-llm-resolver-stub
enterprise-matrix-agent-personas
enterprise-matrix-customer-escalation
enterprise-matrix-security-incident
enterprise-matrix-vendor-onboarding
file-markdown-convert
first-four-arithmetic-pipeline
gemini-ocr-worker
gemini-sdk-worker
gmail-latest-mail-digest-telegram
kaiba-document-intake
loop-baseline-regression-ops
loop-budget-guard
loop-ci-gate-check
loop-concurrency-lease
loop-engineer-quality-loop
loop-outcome-notifications
loop-stall-guard
matrix-agent-trio-chat
matrix-chat-reply
memory-consolidation
monja-agent-collaboration
monja-typescript-sdk
node-combinations-showcase
note-agent
note-link-extract
note-rag-retrieval-fusion
open-model-provider-codex
recent-change-quality-loop
required-loop-gate-failure
riela-default-workflow-supervisor
routine-chat-manager
routine-task-runner
same-node-session-echo
scheduled-sleep
seatbelt-sandboxed-worker
shared-agent-trio-personas
slack-agent-trio-chat
slack-codex-chat
subworkflow-chained-simple
task-agent-director
task-repair-loop
telegram-agent-trio-chat
telegram-agent-trio-time-signal
telegram-sdk-trio-chat
worker-only-single-step
workflow-call-live-echo
workflow-call-live-echo-callee
workflow-call-review-target
workflow-call-simple
workflow-knowledge-base
wrike-project-kanban-agent
x-follower-ai-business-digest
x-incremental-posts-kv
```

The driver's `summary.json` contains command argv, cwd, case, source HEAD/binary,
complete stdout/stderr paths, final exitCode, assertions, and classification.
Logs live under `tmp/issue-117/implementation/verification/attempt-N/`. A timeout,
running session, truncated output, skipped test, or absent status is not a pass.
Any tool-returned process handle remains owned and polled to terminal exit.

## Same-branch edit discipline and progress

Before each edit: fresh-read the file, compute SHA-256, and save the immutable
pre-edit file plus intended change note under `tmp/issue-117/implementation/intents/`
using a unique task/attempt path. After each edit: save SHA-256, diff and task
intent result. Compare current hashes before subsequent edits and before handoff.
Unexpected drift requires a fresh read and deliberate integration, never restoring
an older whole file. No concurrent Git operations, private branches or worktrees.
Only this implementation owner writes this plan's progress log. Independent review
is read-only; reserve shared indexes, lockfiles, broad formatting and global plan
archiving for serial reconciliation/finalization.

The workflow checkpoints the accepted design and ALL Step 5-accepted plans in one
commit and non-force push before native implementation/review fanout. A failed
checkpoint push stops dispatch. Step 4 does not preempt Step 5 by committing an
unreviewed plan. There are no parallel implementation tasks in this coupled unit.

Progress log records each task as pending/in_progress/completed/blocked, exact
changed files, pre/post hashes, decisions, findings with severity, verification
commands and final exit codes/log paths. TASK-117-05 stays explicitly downstream
for integration review and publication; do not claim final push from implementation evidence.
Retain scratch evidence until downstream consumption, then remove it without
staging it. Durable progress/doc references must include essential outcomes even
when scratch is later removed.

## Completion criteria

Implementation handoff: TASK-117-01 through TASK-117-04 complete; baseline and final
behavior demonstrated with the real resolver; required matrix and all command
results present; no introduced failures or unresolved high/mid findings; exact
changed-file allowlist and evidence delivered. Overall issue completion additionally
requires TASK-117-05, independent acceptance, current documentation, and matching
local/remote source commit. No unresolved user decisions or design defects are
known. No Step 5 feedback has been supplied for this first plan authoring pass.

## Step 6 implementation handoff

TASK-117-01 through TASK-117-04 are complete on the shared working tree. The
real resolver baseline failed workflow-name selection (`notFound("youtube-flow")`),
while the final source passed 9 focused installed-metadata tests, 22 existing
host-capability tests, strict selected-file SwiftLint, source build, 12 installed
native/container CLI selections, and all 75 example validations. Full command
logs, numeric exits, fixture identities, per-edit intentions/hashes, and the
87-command final summary are under `tmp/issue-117/implementation/`; durable
details are in `impl-plans/progress/issue-117-installed-addon-metadata.md`.
Step 8 refreshed README's installed add-on validate/inspect contract and the
implementation-plan index, then archived this accepted implementation plan.
The implementation workflow skill was reviewed and needs no issue-specific
instruction change.
The branch's independent test-integrity and adversarial rereview decisions in
`comm-000017` accepted the final implementation with no findings. Combined-tree
integration acceptance, exact-file staging, commit, and
non-force push remain TASK-117-05 downstream work.
Archiving records accepted implementation, not overall issue publication.
