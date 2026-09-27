# Gateway SDK: dependency preparation

```json
{
  "planId": "gateway-sdk-01",
  "planPath": "impl-plans/active/gateway-sdk-addons-01-dependency-preparation.md",
  "dependsOn": [],
  "writePaths": [
    "Package.swift",
    "Package.resolved",
    "impl-plans/progress/gateway-sdk-01.md"
  ],
  "sharedPaths": [
    "Package.resolved"
  ],
  "progressLog": "impl-plans/progress/gateway-sdk-01.md",
  "status": "planned; design accepted; implementation authorized; plan review pending"
}
```

## Authority, intent, and execution rules

Issue: `docs/briefs/gateway-sdk-addons-2026-09-04.md` (no GitHub issue).
Source of truth: `design-docs/specs/design-gateway-sdk-addons.md` and
`design-docs/user-qa/qa-gateway-sdk-worktree-dependencies.md`. Session 5 Step 3
`comm-000022` accepted both with no findings. This is distinct from the historical rejected review recorded
in QA. No codex-agent reference or Cursor behavior mapping applies.

Intent: add typed operation mode beside compatible passthrough, static schema
lookup, CLI discovery, and validation using public gateway SDKs. Google Documents
0.3.3 supersedes the historical 0.3.1 gap; never rewrite that historical finding.
The effective workflow input authorizes implementation now on
`feat/remaining-impl-plans-20260927`; obtain independent plan acceptance before
native Riela implementation fanout. Commit the accepted design and ALL five
plans before fanout. Use the
same branch and working directory; no worktrees, private branches, concurrent git
operations, or background shell processes. No merge to main is authorized here.

Non-goals: gateway/kit source changes, local dependency substitutions, new provider
operations, credential/file-policy options, container or google-service changes,
unrelated Apple families, generalized frameworks, broad cleanup, releases, or
workflow registry/provenance rediscovery. Preserve unrelated Riela/Monja work.

Read this plan and the accepted design fresh before every edit. Before editing a
file, record SHA-256 (or ABSENT for a new file), save its preimage and a write-once
intent snapshot identifying the exact requirement and intended change under
`tmp/remaining-impl-plans/gateway-sdk/<planId>/<attempt>/`. Recheck the prehash immediately
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

- [ ] Serial preparation: in `Package.swift`, add unconditional `GatewaySDKKit`
  product to RielaCLI and its public exact dependency. Set only the five gateway
  versions below; keep existing products and macOS conditions. Do not change
  Core target dependencies or unrelated package versions.
- [ ] Generate `Package.resolved` once, serially, with the manifest changes.
  Compare against its preimage; reject unrelated upgrades and local/mirror URLs.
- [ ] Preserve the existing session 1 changes in `Package.swift`,
  `Package.resolved`, and `impl-plans/progress/gateway-sdk-01.md`. Recheck the
  recorded posthashes before any edit. The graph, lockfile, and lint checks
  already recorded in the progress log are evidence, but do not complete this
  plan. Run the focused gateway behavioral filter below and append its actual
  positive selected test count, zero failures, complete log path, and final exit
  code to that progress log. Re-evaluate the plan gate from all evidence before
  releasing dependent plans; do not invent counts or rerun resolution merely
  because this plan was revised.

| Public dependency URL | Exact version |
| --- | --- |
| https://github.com/tacogips/gateway-sdk-kit.git | 0.1.0 |
| https://github.com/tacogips/wrike-gateway.git | 0.2.4 |
| https://github.com/tacogips/google-analytics-gateway.git | 0.1.1 |
| https://github.com/tacogips/gmail-gateway.git | 0.1.11 |
| https://github.com/tacogips/google-documents-gateway.git | 0.3.3 |
| https://github.com/tacogips/apple-gateway.git | 0.1.7 |

## Invariants and acceptance

Trace: design Dependency and platform boundary. Five gateway identities and one
unique kit identity/version; shared references in tree output may repeat, but
not conflicting versions. Google Documents revision must equal
`4baeb285f459adb9031273490b922abc8204dedb`. Preserve RielaCore's SDK-free boundary.
No release build or dependent implementation starts until graph checks pass.
The runner's workflow provenance is already authoritative and is not this gate.
The plan 01 completion gate also requires a passing focused behavioral test
that compiles and exercises the changed gateway dependency integration. Zero
selected tests, a missing final exit code, or an incomplete log is not a pass.

## Verification commands and evidence

```bash
swift package resolve
swift package show-dependencies --format json
swift test --filter 'WrikeGatewayAddonTests|GmailGatewayAddonTests|GoogleAnalyticsGatewayAddonTests|GoogleDocumentsGatewayAddonTests|AppleGatewayAdminAddonTests'
git diff -- Package.swift Package.resolved
git diff --check
```

Both SwiftPM commands must exit 0 without conflicting-identity warnings. Inspect
the complete graph and lockfile for all table URLs/versions and the Documents
commit; record the comparison in this plan's progress log. Diff must show only
requested dependency edits; whitespace check must pass. These commands are
required implementation gates. Session 1 recorded graph and lockfile success;
the focused test has not yet run. Its log must show a positive actual test count
and zero failures. Record each command's complete stdout/stderr log and terminal
exit code in `impl-plans/progress/gateway-sdk-01.md`; retain the prior records.

## Scheduling

Wave 0, serial owner only. Then release plans 02 and 03. Plan 05 alone may repair
the lockfile at join if evidence proves it necessary; no worker regenerates it.
