# Gateway SDK: examples final verification

```json
{
  "planId": "gateway-sdk-05",
  "planPath": "impl-plans/active/gateway-sdk-addons-05-examples-final-verification.md",
  "dependsOn": [
    "gateway-sdk-04"
  ],
  "writePaths": [
    "examples/gmail-operation-thread-digest/workflow.json",
    "examples/gmail-operation-thread-digest/prompts/summarize.md",
    "examples/gmail-operation-thread-digest/mock-scenario.json",
    "examples/gmail-operation-thread-digest/README.md",
    "examples/gmail-operation-thread-digest/EXPECTED_RESULTS.md",
    "examples/gateway-schema-lookup/workflow.json",
    "examples/gateway-schema-lookup/prompts/explain-schema.md",
    "examples/gateway-schema-lookup/mock-scenario.json",
    "examples/gateway-schema-lookup/README.md",
    "examples/gateway-schema-lookup/EXPECTED_RESULTS.md",
    "examples/wrike-project-kanban-agent/workflow.json",
    "Tests/RielaCLITests/RielaExampleCatalog.swift",
    "Tests/RielaCLITests/RielaExampleParityTests.swift",
    "README.md",
    ".agents/skills/riela-node-addons/SKILL.md",
    "Package.resolved",
    "impl-plans/README.md",
    "impl-plans/PROGRESS.json",
    "impl-plans/progress/plans-index.json",
    "impl-plans/progress/gateway-sdk-05.md"
  ],
  "sharedPaths": [
    "Package.resolved",
    "Tests/RielaCLITests/RielaExampleCatalog.swift",
    "Tests/RielaCLITests/RielaExampleParityTests.swift",
    "impl-plans/README.md",
    "impl-plans/PROGRESS.json",
    "impl-plans/progress/plans-index.json"
  ],
  "progressLog": "impl-plans/progress/gateway-sdk-05.md",
  "status": "planned; independent plan review pending; implementation not authorized"
}
```

## Authority, intent, and execution rules

Issue: `docs/briefs/gateway-sdk-addons-2026-09-04.md` (no GitHub issue).
Source of truth: `design-docs/specs/design-gateway-sdk-addons.md` and
`design-docs/user-qa/qa-gateway-sdk-worktree-dependencies.md`. Current Step 3
`comm-000004`, execution `step3-design-review-attempt-1-exec-4`, accepted both
with no findings. This is distinct from the historical rejected review recorded
in QA. No codex-agent reference or Cursor behavior mapping applies.

Intent: add typed operation mode beside compatible passthrough, static schema
lookup, CLI discovery, and validation using public gateway SDKs. Google Documents
0.3.3 supersedes the historical 0.3.1 gap; never rewrite that historical finding.
This plan is authored in planning-only mode. Execute its implementation tasks only
in a later implementation-authorized run after independent plan acceptance.
Commit the accepted design and ALL five plans before native Riela fanout. Use the
same branch and working directory; no worktrees, private branches, concurrent git
operations, or background shell processes. No merge to main is authorized here.

Non-goals: gateway/kit source changes, local dependency substitutions, new provider
operations, credential/file-policy options, container or google-service changes,
unrelated Apple families, generalized frameworks, broad cleanup, releases, or
workflow registry/provenance rediscovery. Preserve unrelated Riela/Monja work.

Read this plan and the accepted design fresh before every edit. Before editing a
file, record SHA-256 (or ABSENT for a new file), save its preimage and a write-once
intent snapshot identifying the exact requirement and intended change under
`tmp/gateway-sdk-implementation/<planId>/<attempt>/`. Recheck the prehash immediately
before applying the edit; if changed, reread and reconcile, never overwrite from
an old snapshot. Record posthash and patch. At join compare current files with
worker posthashes and accepted intent snapshots; investigate drift, including
changes in sequentially shared files. Stop overlapping ownership until the serial
integration owner repairs from current contents and reruns affected checks. Do
not use reset/checkout to discard another worker's changes.

Each worker writes only its own progress log named in metadata: timestamp, task
status, requirement, changed paths, pre/post hashes, intent/evidence paths, exact
commands, full stdout/stderr logs, terminal exit status, findings, and remaining
work. Initialize it on implementation start; do not mark implementation complete
while planning. Shared indexes, lockfile generation, formatting across owners,
and global archiving belong only to serial preparation/finalization. Do not
reformat unrelated code. Workers do not stage, commit, push, or change Git state.

Run every command in the foreground from the repository root. Save complete
stdout/stderr under that worker's scratch directory and record final status in
its progress log; poll any yielded session to exit. A truncated log, zero selected
tests, blocked command, or missing exit status is not a pass. Swift build supplies
compiler/type checking; SwiftLint and the full suite are serial gates in plan 05.
Focused Swift tests sharing `.build` must be scheduled serially by the owner even
when source edits are parallel. New tests must exercise behavior, not echo code.

Completion requires all listed deliverables and acceptance assertions, passing
relevant verification with complete evidence, no unresolved high/mid findings,
and a handoff of hashes/patches to serial integration. Do not update global plan
indexes or archive other plans. Any necessary new path beyond writePaths requires
an explicit bounded ownership update before editing, not silent scope expansion.

## Tasks and file-level deliverables

- [ ] New gmail-operation-thread-digest files: reader threads operation with typed
  workflow input arguments, subject/from selection validated against the pinned
  catalog, then an LLM summary prompt. New gateway-schema-lookup files: draft
  catalog (?i)draft search feeding an agent prompt. Each workflow gets one
  deterministic mock-scenario.json, README with runnable commands and
  EXPECTED_RESULTS.md asserting relevant payloads, step order, and final output.
  Match existing worker-only/node-runtime fixture shapes; do not call providers.
- [ ] Convert exactly one suitable Wrike node in the existing workflow.json to
  operation mode, preserving its semantics and bindings. Select its operation and
  arguments from the pinned catalog, not guessed names.
- [ ] Serial index update: alphabetically register both examples in
  RielaExampleCatalog.swift. Increase expectedMockScenarioCount by exactly 2
  in RielaExampleParityTests.swift; reconcile expectedNodeMockScenarioCount
  with the two new node-runtime fixtures rather than masking assertion failures.
- [ ] README Local Gateway/Apple sections document both modes, Gmail variables,
  gateway-schema and addon schema.
- [ ] Plan 05 owns `.agents/skills/riela-node-addons/SKILL.md`: create the
  repository directory and skill file if absent, or update the existing file
  while preserving unrelated guidance. Include valid skill name/description
  frontmatter and concise instructions covering passthrough versus operation
  config examples, typed arguments and optional GraphQL selection, Gmail
  variablesTemplate support, Documents command/argsTemplate compatibility,
  credential-free riela/gateway-schema usage, and the riela addon schema command
  with --tier and --grep. Explain fixed roles, unchanged environment restrictions, and Documents
  exact 0.3.3. This is a required documentation deliverable, not conditional on
  the directory already existing.
  If a workflow/prompt/script/skill is covered by a tracked riela-package.json,
  refresh its declared digests using its existing tooling serially; this checkout
  currently has no tracked riela-package.json. Do not discover workflow registries
  or invent a package manifest. New example files do not justify registry work.
- [ ] Serial join: compare every worker hash and immutable intent snapshot with
  the combined tree. Repair lost edits in prior owned files only after recording
  explicit transferred ownership in this progress log. Rerun affected focused
  suites. Keep dependency resolution and lockfile repair serial; no unrelated
  upgrades. Update only this feature's entries in shared plan indexes at final
  acceptance; do not archive this planning-only package as implemented.
- [ ] Run full verification below, collect independent adversarial review of
  combined execution authority, error classification, provenance, static lookup,
  platform guards and graph. Fix all high/mid findings before completion.

## Invariants and acceptance

Trace: design Examples, documentation, rollout and Verification contract.
No fake success from mocks substitutes for SDK stand-in behavior tests; retain
both. Every example must parse and reach expected terminal results. Release CLI
must exercise the public parser/dispatch path and return matching draft entries.
Independent review must accept the combined implementation. Record exact timing
flake test names: only focused success plus isolated rerun can classify a known
interleaved-submit flake; otherwise leave failed, not waived.

Skill-documentation acceptance requires the file to exist, valid frontmatter,
and accurate examples for both modes, Gmail variables, and both schema surfaces.
Compare examples against the accepted design and the plan 03/04 tested contracts;
record this content review in `impl-plans/progress/gateway-sdk-05.md`. Keyword
presence alone is insufficient. Missing or inaccurate skill documentation blocks
completion even if code tests pass.

## Verification commands and evidence

Run serially; save each full log and final exit status separately. For the two
mock runs use fresh, unique attempt directories below the shown scratch root;
never delete or reuse another execution's session artifacts.

```bash
arch -arm64 /bin/zsh -lc 'swift build -c release'
arch -arm64 /bin/zsh -lc "swift test --filter 'WrikeGatewayAddonTests|GmailGatewayAddonTests|GoogleAnalyticsGatewayAddonTests|GoogleDocumentsGatewayAddonTests|AppleGatewayAdminAddonTests|AddonExecutionContractsTests|RielaExampleParityTests|WorkflowValidation|WorkflowGatewayValidationTests|GatewaySchemaTests|CommandParsingTests'"
arch -arm64 /bin/zsh -lc 'swift test'
.build/release/riela workflow run gmail-operation-thread-digest --workflow-definition-dir examples --mock-scenario examples/gmail-operation-thread-digest/mock-scenario.json --session-store tmp/gateway-sdk-implementation/gateway-sdk-05/gmail-sessions --output jsonl
.build/release/riela workflow run gateway-schema-lookup --workflow-definition-dir examples --mock-scenario examples/gateway-schema-lookup/mock-scenario.json --session-store tmp/gateway-sdk-implementation/gateway-sdk-05/schema-sessions --output jsonl
.build/release/riela addon schema gmail-gateway --tier draft --grep '(?i)draft'
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint
swift package show-dependencies --format json
test -s .agents/skills/riela-node-addons/SKILL.md
cat .agents/skills/riela-node-addons/SKILL.md
rg -n 'queryTemplate|operation|arguments|selection|variablesTemplate|command|argsTemplate|riela/gateway-schema|riela addon schema|--tier|--grep|0\.3\.3' .agents/skills/riela-node-addons/SKILL.md
git diff --check
git status --short
```

The skill existence, full-content read, and coverage search commands must exit 0;
retain full logs and a checklist mapping every documentation acceptance item to
its actual section/example. Review frontmatter and semantic correctness manually
against the design; do not treat one matching keyword as complete coverage.

Require release compilation/typechecking, all focused assertions and full-suite
results, expected mock terminal outputs, nonempty matching draft search output,
SwiftLint status/diagnostics, unchanged accepted graph and scope. On Linux run
`swift test --filter 'WorkflowGatewayValidationTests|RielaExampleParityTests'`
in existing CI if available; retain Core's import independence and fail-closed
catalog behavior tests even if Linux execution is unavailable. Record any such
platform gap explicitly for reviewer disposition, not as a passing run.
No browser/type-script gate is required: no browser source is in scope.

## Completion and publication boundary

All five progress logs must show completed deliverables, intact merged intent,
complete verification evidence and independent implementation acceptance before
claiming implementation complete. This current run may publish only accepted
planning artifacts on feat/gateway-sdk-addons after Step 5 plan review; it cannot
execute these tasks, change Swift, merge to main, or claim their gates passed.
Later implementation commit/push follows that later run's explicit authority.

## Step 5 revision response

`comm-000006` identified one mid finding: missing ownership and completion checks
for the required skill documentation when its repository directory is absent.
Plan 05 now owns creation/update of the exact SKILL.md path and requires both
existence checks and semantic coverage review. Design acceptance is unchanged;
independent plan re-review remains pending. No skill or Swift implementation is
created during this planning-only revision.
