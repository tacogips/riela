# Issue 117: installed external local-command dependencies

## Executable contract

- planId: `issue-117-installed-local-command`
- planPath: `impl-plans/active/issue-117-installed-local-command.md`
- dependsOn: `[]`; one coupled implementation unit, serial task DAG below.
- writePaths: exact files in the ownership table below, plus ignored evidence root.
- sharedPaths: `[]` between implementation workers; serial-only paths listed below.
- workflowMode: `issue-resolution`
- issueReference: https://github.com/tacogips/riela/issues/117
- designReference: `design-docs/specs/design-installed-package-workflow-resolution.md`, section `Issue #117 follow-up: installed local-command dependencies`.
- acceptedDesignReview: Step 3 `comm-000004`, accepted, no findings; intake `comm-000002`.
- codexAgentReferences: `[]`; Cursor behavior mapping and intentional divergences: none.
- branch: `fix/example-contract-migration`; preserved WIP baseline `7435d6ce735ebc0a02609d7dcf14e10205d6aba0`.
- progressPath: `impl-plans/progress/issue-117-installed-local-command.md`.
- evidenceRoot: `tmp/issue-117-local-command/`.

User intent: finish the narrow installed local-command portion of #117 from
pushed WIP 7435d6c. The verifier and projection already exist; the historical
12 focused and 22 host tests passed, but 79/81 CLI positives (exit 1) is a failed
gate. Preserve this history and the missing pre-production baseline limitation.
The remaining work is missing coverage, corrected direct-selection commands,
source-matched gates and independent review, not a fresh implementation. Validate/inspect must accept a synthetic valid
installation with explicit execution kind and executable readiness, while legacy
locks missing the kind remain rejected. The accepted design, effective workflow
input, and runtime provenance are authoritative. Intake could not retrieve latest
issue comments; do not invent their contents or block implementation on them.

Non-goals: changes to the running workflow installation, registry rediscovery,
legacy package migration, changes to riela-packages or sibling worktrees, new
worktrees/branches, schema/protocol changes, execution engine changes, provider
calls, payload execution, general resolver frameworks, unrelated cleanup, release,
or merge. This plan replaces the prior dispatch target, not the historical
completed plan or its evidence. No Codex reference repository inspection applies.

## File ownership and intended changes

One implementation owner owns all coupled edits. These are bounded permissions;
do not touch an optional path unless the specified condition requires it.

| writePath | Precise intended change |
| --- | --- |
| `Sources/RielaCLI/WorkflowInstalledAddonRequirements.swift` | Preserve the existing verified executable-path result; do not add duplicate descriptor storage. Repair only defects demonstrated by remaining accepted tests. Count reference/version candidates before filtering execution-kind validity. Accept explicit local-command only after existing identity/lock/integrity checks and contained executable-file readiness. |
| `Sources/RielaCLI/WorkflowValidateInspectCommands.swift` | Preserve existing verified dependency executable requirements and availability; repair only defects demonstrated by accepted tests. Preserve required environments and callee-local context; retain native/container and package-owned local-command behavior. |
| `Sources/RielaCLI/WorkflowAddonHostRequirements.swift` (only if needed) | Move the coherent host requirement/availability helper group from the command file if edits would exceed 1000 lines. No new abstraction or unrelated extraction. |
| `Tests/RielaCLITests/WorkflowInstalledAddonMetadataTests.swift` | Extend the installed fixture for explicit local-command descriptors, locks, registry values, and filesystem executable checks; add selection and fail-closed tests. |
| `Tests/RielaCLITests/WorkflowInstalledLocalCommandTests.swift` (only if needed) | Cohesive local-command cases/fixture support if the existing suite would exceed 1000 lines. Keep test names filterable by `WorkflowInstalledLocalCommandTests`; avoid duplicating fixture generation. |
| `Tests/RielaCLITests/WorkflowHostCapabilityTests+AddonRequirements.swift` | Add deterministic executable/environment host assertions if unsuitable for the installed fixture suite; retain existing tests. |
| `impl-plans/progress/issue-117-installed-local-command.md` | Owner-only task status, evidence, changed files, failures, drift, and next action. |
| `tmp/issue-117-local-command/` | Existing verify.py driver, isolated project/home fixtures, and plan-owned attempt directories with immutable intent snapshots, hashes, complete logs and numeric status records; never stage. |

Read-only references: `Sources/RielaCLI/WorkflowResolution.swift`,
`Sources/RielaCore/WorkflowRequirements.swift`,
`Sources/RielaCLI/HostCapabilityResolver.swift`, the existing manifest validation
and digest APIs in `Sources/RielaAddons/`, and
`Tests/RielaCLITests/WorkflowHostCapabilityTests.swift`. Keep Core's unresolved
external-add-on guard; no Core change is expected; WorkflowResolution.swift must not be extended for package-root selection. If a concrete
accepted requirement needs edits outside this allowlist, report the evidence for
plan revision instead of silently expanding scope.

Serial reconciliation/finalization owns:
`impl-plans/active/issue-117-dispatch.json`, this plan, the accepted design document,
and `README.md` only if current user-facing text becomes inaccurate. Workers do
not edit shared indexes, generate repository lockfiles, archive plans, perform
broad formatting, or run Git mutations. No packaged prompt/script/skill is edited,
so package digest regeneration is unnecessary. Review `.codex/skills/riela-impl-workflow/SKILL.md`
for affected documentation; record no change if its contract remains accurate.

## Invariants

1. Owning package context must come from the verified resolved bundle; unrelated
   authored copies cannot acquire authority by name, vendor, or nearby package.
2. Full qualified identity or exactly one unqualified reference/version candidate
   is required. Missing-kind competing declarations remain ambiguity, not a way
   to select a valid candidate. Omitted node versions bind to the unique lock.
3. Explicit local-command lock kind must agree with installed descriptor and
   package-lock summary. Keep owner integrity/containment, selected scope,
   dependency identity/version/registry/checksum/integrity, content digest,
   source path and summary matching checks. Never repair evidence to make a
   negative case pass or infer kind from a vendor/name.
4. Resolve the nonempty entrypoint beneath the installed dependency add-on source
   directory. Canonical containment must hold; reject escapes, missing files,
   directories and non-executable files before host projection. Do not use PATH
   fallback or execute an entrypoint during validation.
5. A verified dependency uses the canonical executable path as both host
   requirement and local-availability key. Two equal basenames in different
   dependencies cannot share authority. Preserve package/node environment union.
6. Each reachable callee uses its own package context. Local availability applies
   only to local snapshots; remote snapshots must independently satisfy required
   executable and environment capabilities. Preserve strict-host rejection.
7. Preserve native/container/declarative/built-in and package-owned local-command
   semantics, scope precedence, JSON/exit conventions, and independent runtime
   diagnostics. Scope conflict/ambiguity cannot fall through to a valid user copy.

## Tasks, deliverables and dependencies

### LC-01: resume fixture and coverage audit — dependsOn []

Fresh-read design, source helpers, tests, preserved progress and Swift skill. Reuse
and audit the existing filesystem fixture using current manifest/checksum/lock-generation APIs. Use package ID
`@issue117/youtube-flow`, workflow ID `youtube-flow`, workflow directory
`workflows/youtube-flow`, and dependency `@issue117/youtube-tools` with explicit
registry `local`, explicit local-command lock, matching package-lock summary,
content digest and a harmless executable shell entrypoint. Represent all three
YouTube-style dependencies in the positive fixture, with distinct references.
The shell body must not be run. Installed layout is under project
`.riela/packages/`; no test-only aliases or workflow-root manifest copies.

Unit fixtures use unique directories under the evidence root's `issue-117-installed-local-command/tests/`; use
`CLIRuntimeEnvironment.$overrides` for isolated test home. The deterministic CLI
fixture uses `project/` and `home/` below the evidence root. Do not assign shell
HOME; the matrix driver supplies child HOME in its subprocess environment.

Run focused tests on the preserved WIP before any further production edits and
retain the current baseline logs. Do not revert WIP or manufacture the historical
pre-production failure. Append a resumption section to the existing progress log:
record historical 79/81 as failed, the declared-directory correction, and a table
mapping each LC-03 case to an existing assertion or a missing test. The three
existing local-command methods cover selections, a subset of negatives, and host
capabilities; native-only tests do not prove local-command negative coverage.
Deliver the coverage audit, current baseline and preserved-history annotation.

### LC-02: verified matching and projection — dependsOn [LC-01]

Audit the WIP against the invariants; retain it when correct. Make only repairs
justified by failing accepted cases in the ownership table. Verify reference uniqueness before
execution-kind authorization, retaining qualified disambiguation. Resolve the
matched installed descriptor/root through existing checks; carry the optional
verified executable path in the existing verification value. Native inspection
must continue to select native entries only. Feed the same verification contract
to host requirement and availability helpers; thread working directory only as
needed. Never turn an invalid dependency into a host-neutral resolved node.

Use a regular executable-file check with canonical containment inside the add-on
source root. Preserve current package manifest validation instead of creating a
second integrity system. Keep touched Swift files at most 1000 lines using only
the cohesive optional extractions listed above. Run focused tests and record
exact edits and reasons. Deliver an explicit retained-or-repaired decision and passing focused tests; no
production edit is required merely to complete this task.

### LC-03: adversarial and host coverage — dependsOn [LC-02]

Complete deterministic tests; each invalid fixture must isolate its intended
failure by recomputing unrelated metadata as necessary, without repairing the
field under test. Assert nonzero result AND relevant diagnostic for both validate
and inspect, and assert actual identity and executable projection on positives.

| Cases | Required assertions |
| --- | --- |
| Package ID, workflow name, direct manifest-declared workflow-directory | Same verified package/locks; successful validate and inspect; canonical executable paths retained for all three dependency references. |
| Qualified and unique unqualified references, omitted/explicit node version | Exact dependency selection; wrong explicit version fails. |
| Missing kind, differing descriptor/lock kind, wrong package identity/version | No default authorization; unresolved/integrity diagnostics. |
| Dependency registry mismatch; package-lock registry mismatch | Both independent mismatches fail. |
| Content digest, package integrity, lock summary digest/kind/sourcePath mismatch | No projection from inconsistent installed evidence. |
| Missing, non-executable, directory entrypoint; absolute/traversal/symlink escape | Failure even without --host; no PATH substitution. |
| Unknown/ambiguous reference; missing-kind competing unqualified declaration | Unique qualified match may pass; ambiguous unqualified match fails. |
| Unrelated authored copy | Same names cannot borrow installed authority. |
| Project/user collision, explicit conflicting lock scope, missing project dependency with valid user copy | Preserve project precedence; conflict and substitution fail; selected-scope ambiguity does not fall through. |
| Required package/node environment and host executable | Strict host succeeds only when all requirements satisfied; absent environment or executable fails. |
| Same basename in two dependencies | Distinct canonical keys; one capability cannot satisfy both. |
| Remote snapshot without executable capability | Local readiness cannot make remote host ready; matching remote capabilities can satisfy projection. |
| Reachable callee and native/container baseline | Callee context is independent; existing native/container tests remain passing; unrelated runtime diagnostics stay visible. |

Host tests use injected snapshots to avoid network/provider probes. When an
existing unsupported transition makes a callee command fail independently,
assert the intended projection directly and retain the independent diagnostic;
do not claim overall CLI success for that case.

### LC-04: source CLI matrix and full gates — dependsOn [LC-03]

Fresh-read and revise the existing `tmp/issue-117-local-command/verify.py` as a foreground
verification driver. It must build the deterministic fixture with matching
manifest/digests/lock metadata, enumerate the exact 75-example inventory below,
and run the commands below with captured stdout/stderr and numeric final exits.
It must fail on inventory mismatch, missing/truncated output, malformed JSON,
unexpected success/failure, diagnostic mismatch, or any failed positive command.
Keep the driver throwaway under tmp; production fixture tooling is not required.

Run all gates in the verification section. Matrix deliverable: six successful
installed-selection commands plus 75 successful example validations, minimum
81/81 positive results, and negative CLI cases for every rejection row in LC-03: missing kind; descriptor
kind, node/package version and identity mismatches; dependency/package-lock
registry mismatches; content digest, checksum/integrity and lock-summary
digest/kind/sourcePath mismatches; missing/non-executable/directory/absolute/
traversal/symlink entrypoints; unknown/ambiguous/missing-kind competing references;
unrelated copy; conflicting scope and missing selected-scope dependency with a
valid lower-priority copy. Execute validate and inspect for each fixture mutation
using workflow-name selection with --scope project (direct selection for the
unrelated authored copy). Record case IDs, exact argv and expected diagnostic.
Use host-injected unit tests for host/environment rows, not network probes. Restore/rebuild fixtures between mutations.
Each negative result must have the expected nonzero numeric exit and diagnostic.
Existing native/container regression tests must also pass. No historical log can
substitute for current source-tree evidence. Require at least 81/81 positives;
79/81 remains failure even if all historical negative cases pass.

### LC-05: serial reconciliation and review handoff — dependsOn [LC-04]

After implementation/test-integrity work joins, compare every planned intent
snapshot, pre/post hash, actual diff and acceptance requirement. Repair overwritten
or missing changes serially; rerun affected gates after repairs. Record final tree
hashes, all tasks/evidence and outstanding issues in the owner progress log.
Independent adversarial review and combined-tree integration review occur in the
workflow after this implementation handoff. No high/mid issue or failed gate may
be hidden as completion.

Post-review serial owner refreshes the accepted design's status/evidence and
reviews README/affected workflow skill documentation for accuracy. Update only
inaccurate text within scope. Archive this plan only during finalization and
update dispatch paths together then. These downstream review/documentation/
commit tasks remain explicitly pending at implementation handoff and do not
self-block LC-01 through LC-05 when their own requirements have passed.

## Same-tree edit safety and dispatch ordering

Before native Riela implementation/review fanout, workflow checkpoint must commit
and non-force push the accepted design, this plan, and current dispatch metadata.
A rejected review or failed checkpoint push stops dispatch. This authoring step
does not claim that checkpoint has occurred. No concurrent Git operations,
private branches, or worktrees. One production owner is appropriate because the
verification value and both projections form one coupled change. Read-only
independent test-integrity investigation may run concurrently under Riela; avoid
simultaneous build/test commands sharing .build or mutable fixtures.

Before EACH edit, reread the current file, record its SHA-256 (or explicit
absent marker), and save an immutable copy plus intent (path, requirement, planned
change) under `evidenceRoot/snapshots/<attempt>/<task>/<edit>/`. After editing,
record post-hash and diff. Before the next write, compare current hash to the last
observed hash; on drift reread and integrate instead of replacing the file from
an old buffer. Snapshots cannot be overwritten by retries. Each worker writes
only its own assigned progress log; read-only reviewers store evidence in their
own tmp subdirectory and return findings. Shared indexes, lockfiles, plan archive,
and documentation finalization stay serial. Serial reconciliation after join is
mandatory even when drift was not reported.

## Exact verification and evidence contract

Run from repository root with Xcode's toolchain. A foreground Python subprocess
wrapper may capture each command into separate stdout/stderr files; record argv,
cwd, start/end, numeric exit, expected exit, assertions, and complete log paths
in `tmp/issue-117-local-command/issue-117-installed-local-command/attempt-N/verification.json`.
Never discard failures or overwrite previous attempts. Start at the next unused
attempt number (existing attempts 1 and 2 remain immutable). Record `git rev-parse
HEAD`, `git diff --binary` plus its SHA-256, touched-source SHA-256 values, and
`shasum -a 256 .build/debug/riela` alongside every final gate batch. After any
source repair, rebuild and rerun affected tests and the complete CLI matrix;
review must match that source/binary identity. Poll any tool session
through terminal exit; incomplete output is not passing evidence.

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'WorkflowInstalledAddonMetadataTests|WorkflowInstalledLocalCommandTests'
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter WorkflowHostCapabilityTests
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint
python3 tmp/issue-117-local-command/verify.py
git diff --check
```

Focused/host suites must select nonzero tests and have zero failures; list test
names/counts proving the new cases ran. Build is Swift compilation/typechecking;
no web typecheck applies. SwiftLint must exit zero with no introduced warnings;
classify any existing warnings by path rather than broad cleanup. All 75 examples
and six positive selection commands must pass; do not accept unexplained failures.

The driver resolves repository root to an absolute path, source executable to
`.build/debug/riela` under that root, child HOME to evidenceRoot/home, and cwd to
evidenceRoot/project. The following relative commands are exact from that cwd:

```bash
../../../.build/debug/riela workflow validate @issue117/youtube-flow --scope project --output json
../../../.build/debug/riela workflow inspect @issue117/youtube-flow --scope project --output json
../../../.build/debug/riela workflow validate youtube-flow --scope project --output json
../../../.build/debug/riela workflow inspect youtube-flow --scope project --output json
../../../.build/debug/riela workflow validate youtube-flow --workflow-definition-dir .riela/packages/@issue117/youtube-flow/workflows/youtube-flow --output json
../../../.build/debug/riela workflow inspect youtube-flow --workflow-definition-dir .riela/packages/@issue117/youtube-flow/workflows/youtube-flow --output json
```

For every inventory name, run argv `[absoluteSourceExecutable, "workflow",
"validate", name, "--workflow-definition-dir", absoluteRepositoryExamples,
"--output", "json"]` with repository cwd and isolated child HOME. Equivalent
repository-root command is `.build/debug/riela workflow validate NAME
--workflow-definition-dir examples --output json`. These commands test synthetic
fixtures and checked-in examples, never rediscover the running workflow package.

Exact example inventory (compare set and count with discovered workflow.json):

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

## Progress and completion

The owner appends a resumption section to its existing progress file; preserve
all historical failure evidence and do not replace or reset that log. Use a row for each
LC task with pending/in_progress/completed/blocked, dependencies, edited paths,
commands, numeric exits, complete log paths, findings and next action. Distinguish
historical missing baseline, current WIP baseline, expected negative checks, and
final passing gates.
Include immutable snapshot paths, drift/reconciliation decisions, reviewed
residual risks, and downstream tasks pending independent review. Never claim
review, commit or push based on implementation tests.

Implementation completion requires LC-01 through LC-05, complete positive and
negative evidence, native/container compatibility, no unauthorized writes, no
unresolved high/mid findings, and a reviewable diff. Workflow completion also
requires independent reviews, documentation refresh, serial archive/index
updates, and accepted source commit plus non-force branch push. Do not release
or merge. Preserve evidence until downstream consumers finish, then remove
throwaway artifacts; never stage tmp.
