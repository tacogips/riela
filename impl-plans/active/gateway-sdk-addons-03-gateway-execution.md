# Gateway SDK: gateway execution

```json
{
  "planId": "gateway-sdk-03",
  "planPath": "impl-plans/active/gateway-sdk-addons-03-gateway-execution.md",
  "dependsOn": [
    "gateway-sdk-01"
  ],
  "writePaths": [
    "Sources/RielaCLI/ProductionNodeAdapter.swift",
    "Sources/RielaCLI/ProductionNodeAdapter+LocalGatewaySupport.swift",
    "Sources/RielaCLI/ProductionNodeAdapter+WrikeGatewayAddons.swift",
    "Sources/RielaCLI/ProductionNodeAdapter+GoogleAnalyticsGatewayAddons.swift",
    "Sources/RielaCLI/ProductionNodeAdapter+GmailGatewayCLIAddons.swift",
    "Sources/RielaCLI/ProductionNodeAdapter+GoogleDocumentsGatewayAddons.swift",
    "Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayAdminAddons.swift",
    "Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift",
    "Tests/RielaCLITests/LocalGatewayAddonTestSupport.swift",
    "Tests/RielaCLITests/WrikeGatewayAddonTests.swift",
    "Tests/RielaCLITests/GoogleAnalyticsGatewayAddonTests.swift",
    "Tests/RielaCLITests/GmailGatewayAddonTests.swift",
    "Tests/RielaCLITests/GoogleDocumentsGatewayAddonTests.swift",
    "Tests/RielaCLITests/AppleGatewayAdminAddonTests.swift",
    "impl-plans/progress/gateway-sdk-03.md"
  ],
  "sharedPaths": [
    "Sources/RielaCLI/ProductionNodeAdapter.swift",
    "Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayAdminAddons.swift",
    "Tests/RielaCLITests/AppleGatewayAdminAddonTests.swift"
  ],
  "progressLog": "impl-plans/progress/gateway-sdk-03.md",
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

- [ ] In LocalGatewaySupport, replace the GraphQL descriptor/engine with
  LocalGatewaySDKDescriptor/LocalGatewayOperationEngine. Implement the exact
  mode matrix, recursive typed template rendering, GatewayJSONValue conversion,
  and selection union from the design. Build once with the fixed-tier catalog
  and GatewayDocumentBuilder; execute the identical document/variables through
  the SDK under the current deadline. Do not use Gmail invoke's full catalog.
- [ ] Wire Wrike, Analytics, and Gmail files to their pinned facade constructors.
  Remove the Gmail acceptsVariables exception; pass passthrough variables.
  Preserve environment allowlists, IDs, tier payloads, and canImport fallbacks.
- [ ] In ProductionNodeAdapter and LocalGatewayAddonTestSupport, replace
  localGatewayGraphQLRunner with localGatewaySDKStandIn, recording actual
  execute document/variables and returning a canned envelope. Update all three
  provider tests in this ownership set; preserve passthrough regression coverage.
- [ ] In GoogleDocumentsGatewayAddons, keep command/argsTemplate passthrough and
  the existing runner. Operation constructs the fixed-role v0.3.3 facade, calls
  throwing buildArgv once, checks auth login/revoke refusal on normalized argv,
  then sends those exact argv to the runner. Never substitute generic builder
  preview plus invoke. Record compact JSON argv; no selection support.
- [ ] In AppleGatewayAdminAddons and only necessary AppleGatewaySupport seams,
  add operation mode to apple-gateway-graphql with fixed full role. Preserve
  passthrough AppleGatewayInvoker, input/config precedence, binaryPath refusal,
  no addon.env, explicit configPath/config mapping to APPLE_GATEWAY_CONFIG and
  HOME handling in the existing sanitized environment. Do not change other
  Apple families. Schema search changes belong to plan 04, after this plan.

## Invariants and acceptance

Trace: design Add-on execution contract and Provider wiring. Keep selectFirst,
whenFlags, payloadExtras, nowVariables, requestId, replyText, namespace/tier,
and existing runtime.mode=in-process behavior. Add authoring mode, operation
(null in passthrough), and exact executed document/argv inside the namespace.
Role selection cannot be authored through arguments; no environment widening.

Construction/shape/render failures are policyBlocked, gateway failures are
providerError, malformed rawOutput is invalidOutput (parse before normalized
errors). Keep current cancellation/deadline behavior. buildArgv supplies
normalization/limits but not SDK execute/invoke file authorization or snapshots;
retain Riela's existing runner policies, without new SDK policy configuration.

Tests cover Wrike query variables, input-object mutation and fields selection;
Analytics/Gmail operation and Gmail passthrough variables; typed template values;
mode collisions/null/wrong shapes; unknown/missing arguments and bad selections;
raw malformed output versus provider errors; exact stand-in provenance; unchanged
timeouts and sanitized environments. Documents additionally covers Boolean
confirm, JSON object/array normalization, token limits, six roles, and auth-command
refusal in both paths. Apple covers precedence, passthrough regression, full role,
config environment mapping, and prohibited binaryPath/addon.env. No live provider
credentials or calls are needed.

## Verification commands and evidence

```bash
swift test --filter 'WrikeGatewayAddonTests|GmailGatewayAddonTests|GoogleAnalyticsGatewayAddonTests|GoogleDocumentsGatewayAddonTests|AppleGatewayAdminAddonTests'
rg -n 'localGatewayGraphQLRunner|LocalGatewayGraphQLRunner|acceptsVariables' Sources/RielaCLI Tests/RielaCLITests
git diff --check
```

Tests and diff exit 0 with recorded test counts; the retired-seam search should
exit 1 (no matches). Investigate any remaining match before handoff. Preserve
other existing runner seams where they serve passthrough regression tests.

## Scheduling

Wave 1, parallel with plan 02. Hand off final shared-file hashes and the new
stand-in interface to plan 04, which then owns its narrow schema additions.
