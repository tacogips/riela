# Gateway SDK: core validation

```json
{
  "planId": "gateway-sdk-02",
  "planPath": "impl-plans/active/gateway-sdk-addons-02-core-validation.md",
  "dependsOn": [
    "gateway-sdk-01"
  ],
  "writePaths": [
    "Sources/RielaCore/WorkflowValidation.swift",
    "Sources/RielaCore/WorkflowNodeValidation.swift",
    "Sources/RielaCore/WorkflowGatewayAddonValidation.swift",
    "Tests/RielaCoreTests/WorkflowGatewayValidationTests.swift",
    "impl-plans/progress/gateway-sdk-02.md"
  ],
  "sharedPaths": [],
  "progressLog": "impl-plans/progress/gateway-sdk-02.md",
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

- [ ] In new `WorkflowGatewayAddonValidation.swift`, define the small Sendable
  catalog projection (provider, tier, operation names), the closed provider/tier
  vocabulary, and shape validation for only the accepted affected add-ons.
  No SDK imports. Expose `WorkflowValidationContext.gatewayCatalog` as an optional
  lookup returning this projection, not `GatewaySchemaCatalog`.
- [ ] In `WorkflowValidation.swift`, default-inject the context into
  `DefaultWorkflowValidator` without changing `WorkflowValidating` or breaking
  current initializer callers. In `WorkflowNodeValidation.swift`, call the new
  shape/operation validator with the node's effective inputs where required.
- [ ] New `WorkflowGatewayValidationTests.swift` covers the matrix below with
  present and absent catalog lookup. Hand off the projection and initializer
  interface to plan 04 for real CLI injection; do not edit CLI files here.

## Invariants and acceptance

Trace: design Workflow validation and Modes. Presence includes null, which fails
type checks. Wrike/Analytics/Gmail require exactly one queryTemplate or operation.
Operation requires nonempty literal operation and object arguments (even empty),
permits selection (dot-path string array or brace-leading raw string), rejects
variablesTemplate/queryTemplate. Passthrough rejects operation-only keys.
Documents uses command/argsTemplate versus operation/arguments and rejects
selection in operation mode. Apple honors rendered inputs over config, existing
queryFile/query and variablesFile/variables precedence; operation is exclusive
with those four passthrough keys. Defer template-dependent effective Apple values
to runtime rather than rejecting valid input-driven workflows.

Schema validation accepts only five gateways and design-listed tiers, known kit
kind names, Boolean includeReferencedTypes, positive integer limit, string
pattern. Unknown operation diagnostics contain the requested name and a bounded,
deterministically sorted closest-name list. With no catalog, skip only existence
checking: malformed shapes still fail. Runtime validation remains necessary.

Tests must cover null/missing/wrong-type/both-mode combinations, typed arguments,
selection union, all gateway/tier pairs, invalid schema options, deterministic
unknown-operation suggestions, default initializer compatibility, and template
Apple deferral. Use a fake projection to test without macOS gateway imports.

## Verification commands and evidence

```bash
swift test --filter 'WorkflowGatewayValidationTests|WorkflowValidation'
git diff --check
```

Exit 0, nonzero selected test count, all matrix assertions passing. Record names
and counts. This focused suite must also run in an available Linux CI environment
at final verification; if unavailable, record the platform gap, never claim a
Linux run from macOS. Do not add CI infrastructure for this feature.

## Scheduling

Wave 1, parallel with plan 03, disjoint writes. No Package.swift or lockfile edits.
