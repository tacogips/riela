# Gateway SDK: schema cli integration

```json
{
  "planId": "gateway-sdk-04",
  "planPath": "impl-plans/active/gateway-sdk-addons-04-schema-cli-integration.md",
  "dependsOn": [
    "gateway-sdk-02",
    "gateway-sdk-03"
  ],
  "writePaths": [
    "Sources/RielaCLI/GatewaySchemaService.swift",
    "Sources/RielaCLI/AddonSchemaCommand.swift",
    "Sources/RielaCLI/RielaClientCommandRouter.swift",
    "Sources/RielaCLI/RielaCommand.swift",
    "Sources/RielaCLI/RielaCLIApplication.swift",
    "Sources/RielaCLI/WorkflowValidateInspectCommands.swift",
    "Sources/RielaCLI/ProductionNodeAdapter.swift",
    "Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayAdminAddons.swift",
    "Sources/RielaAddons/RielaAddons.swift",
    "Tests/RielaCLITests/GatewaySchemaTests.swift",
    "Tests/RielaCLITests/CommandParsingTests.swift",
    "Tests/RielaCLITests/AppleGatewayAdminAddonTests.swift",
    "Tests/RielaAddonsTests/AddonExecutionContractsTests.swift",
    "impl-plans/progress/gateway-sdk-04.md"
  ],
  "sharedPaths": [
    "Sources/RielaCLI/ProductionNodeAdapter.swift",
    "Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayAdminAddons.swift",
    "Tests/RielaCLITests/AppleGatewayAdminAddonTests.swift"
  ],
  "progressLog": "impl-plans/progress/gateway-sdk-04.md",
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

- [ ] New GatewaySchemaService.swift owns the closed catalog lookup and common
  static search service. Use catalog-native tiers from the design, no credentials,
  provider requests, or authenticated service construction. Return sorted known
  values on unknown gateway/tier. Unavailable modules fail with requires macOS.
  Convert available catalogs to plan 02's Core projection; parity-test vocabularies.
- [ ] Implement the narrow (?i) ASCII-literal adapter exactly as accepted: only
  letters/digits/spaces/underscore/hyphen/dot after the prefix, letter classes and
  escaped literal dots, then kit search validation. Other extensions and complex
  case-insensitive expressions remain invalid. Share across CLI and both add-ons.
- [ ] Register gateway-schema version 1 in RielaAddons.swift and dispatch in
  ProductionNodeAdapter.swift. New service emits status/addon/stepId/gateway/tier,
  matches/count/replyText and sdl only without pattern. Count after filters,
  references, and limit. Match fields are kind/name/optional tier/matchedOn/sdl.
  Validate kinds, Boolean includeReferencedTypes, positive limit and regex.
  Reject credential/environment inputs.
- [ ] In AppleGatewayAdminAddons add pattern search using that same service;
  preserve current no-pattern schema print, payload and role precedence. Extend
  AppleGatewayAdminAddonTests without overwriting plan 03 operation tests.
- [ ] New AddonSchemaCommand.swift holds options and execution; wire addon schema
  in RielaClientCommandRouter.swift, internal command/parser in RielaCommand.swift,
  and dispatch/help in RielaCLIApplication.swift. Required gateway and --tier;
  optional --grep, comma-separated --kinds, --include-referenced-types, --limit,
  --output json|sdl. Default JSON uses stepId=""; omitted pattern returns full
  SDL, empty matches, count 0; search-only options remain type-checked. SDL
  prints deterministic fragments when searching. Successful output has one
  trailing newline; usage/search/unavailable errors give nonzero exit and stderr.
- [ ] Inject the catalog projection into explicit validation in
  WorkflowValidateInspectCommands.swift. Preserve shape-only Core callers.
  Add GatewaySchemaTests for catalog/add-on/CLI/injection behavior,
  CommandParsingTests for all routes/options/errors, and AddonExecutionContractsTests
  for new catalog registration. Avoid a workflow-runner dependency for CLI lookup.

## Invariants and acceptance

Trace: design Static schema discovery, CLI behavior, Workflow validation.
Assert no provider/credential access during lookup, all provider/tier parity,
no-pattern versus search payloads, kind/reference/limit processing, regex bridge
acceptance and rejection, deterministic ordering, unavailable-catalog behavior,
CLI defaults/newlines/nonzero exits, and real CLI validator injection rejecting
unknown operations. Existing Core callers and Apple no-pattern behavior remain
compatible. Mock scenarios use recorded node results on all platforms.

## Verification commands and evidence

```bash
swift test --filter 'GatewaySchemaTests|CommandParsingTests|AppleGatewayAdminAddonTests|AddonExecutionContractsTests|WorkflowGatewayValidationTests'
git diff --check
```

Exit 0 with nonzero selected counts and tests proving the assertions above.
Plan 05 additionally tests the built release command, not just internal dispatch.

## Scheduling

Wave 2 after BOTH wave-1 plans. Shared files are sequential ownership, not
parallel edits. Read their current contents and preserve both accepted intents.
