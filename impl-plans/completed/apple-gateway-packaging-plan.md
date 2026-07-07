# Apple Gateway Packaging Plan Implementation Plan

**Status**: Implemented
**Design Reference**: design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md#packaging-coverage-decision
**Created**: 2026-07-07
**Last Updated**: 2026-07-07

---

## Design Document Reference

**Source**:
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`

### Summary

Implement the accepted documentation-only Riela coverage for Apple Gateway
packaging workflows. The accepted design explicitly rejects a new built-in
`riela/apple-gateway-packaging-*` add-on and instead requires command-node
recipes plus one deterministic read-only example bundle for the dry-run
packaging plan.

### Scope

**Included**:
- Keep the catalog design decision as the source of truth.
- Add `examples/apple-gateway-packaging-plan/` as a deterministic mock dry-run
  workflow bundle.
- Use a command node that emits exactly one JSONL object through a wrapper or
  mock script.
- Document how operators can swap the mock for a real local
  `task build:homebrew-cask -- --dry-run` command in an Apple Gateway checkout.
- Document that signed/notarized Cask builds and release publishing remain
  human-run commands outside Riela.
- Validate the new example bundle and run `swift build` even though no Swift
  source should change.

**Excluded**:
- No new built-in add-on id.
- No changes to `BuiltinWorkflowAddonResolver`, `RielaBuiltinAddonCatalog`,
  add-on execution-contract tests, or `AppleGatewayProcessRunner`.
- No live Apple app access, no real `task` dependency, and no signing
  credentials in automated validation.
- No changes to the pre-existing dirty RielaApp timeline files.

### Traceability

- Workflow mode: `issue-resolution`.
- Issue source: `workflowInput.issueTitle/requestedBehavior`; no GitHub issue
  URL or repo-plus-number was provided.
- Step 3 accepted the design in
  `design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`.
- `codexAgentReferences` is empty, so there are no Codex-reference adapter
  behaviors to map or intentionally diverge from.
- Accepted divergence from the initial candidate add-on shape: the final design
  is documentation-only plus command-node recipe because packaging uses `task`
  and unstructured plan text, not the shared `apple-gateway graphql` JSON
  envelope.

---

## Task Breakdown

### TASK-001: Confirm Existing Example Shapes

**Status**: COMPLETED
**Write Scope**: none
**Parallelizable**: yes, with read-only inspection only

**Tasks**:
- Inspect `examples/node-combinations-showcase/workflow.json`.
- Inspect `examples/node-combinations-showcase/nodes/node-command-worker.json`.
- Inspect `examples/apple-notes-list/nodes/node-workflow-output.json`.
- Confirm the implementation uses existing command-node authoring aliases:
  `scriptPath`, `argvTemplate`, `envTemplate`, and `workingDirectory`.

**Deliverable**: Progress-log entry naming the source examples and any schema
details reused by the new bundle.

### TASK-002: Add Packaging Plan Example Bundle

**Status**: COMPLETED
**Write Scope**:
- `examples/apple-gateway-packaging-plan/workflow.json`
- `examples/apple-gateway-packaging-plan/nodes/node-packaging-plan.json`
- `examples/apple-gateway-packaging-plan/nodes/node-workflow-output.json`

**Dependencies**: TASK-001
**Parallelizable**: no; owns the example workflow and node payload files

**Tasks**:
- Create a minimal workflow that runs the mock packaging-plan command node and
  then a workflow-output node.
- Declare `workflowInput.appleGatewayCheckout` as a string input for real-use
  documentation without requiring it during mock validation.
- Point the checked-in command node at the bundle mock script so validation
  requires no real Apple Gateway checkout, `task`, Apple app access, or
  credentials.
- Keep the output projection shape aligned with the existing Apple Notes
  workflow-output node.

**Deliverable**: A valid `apple-gateway-packaging-plan` workflow bundle with
deterministic dry-run behavior.

### TASK-003: Add Deterministic Mock Command Script

**Status**: COMPLETED
**Write Scope**:
- `examples/apple-gateway-packaging-plan/scripts/mock-task-jsonl.sh`

**Dependencies**: TASK-002 can create the directory first
**Parallelizable**: yes, after the directory exists and while TASK-004 edits
README-only scope

**Tasks**:
- Add an executable POSIX shell script.
- Ignore incoming arguments except for harmless echoing in structured fields.
- Emit exactly one JSON object line on stdout.
- Include representative dry-run plan text inside a JSON string field rather
  than printing raw `key: value` plan text directly to stdout.
- Ensure the mock output states that publish side effects are false and that
  Apple signing environment names are not values.
- Fail closed with redacted JSON and non-zero exit when
  `APPLE_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_PASSWORD`, or `APPLE_TEAM_ID`
  is present in the command environment.

**Deliverable**: A deterministic JSONL mock script with mode `0755`.

### TASK-004: Add Example Documentation

**Status**: COMPLETED
**Write Scope**:
- `examples/apple-gateway-packaging-plan/README.md`
- `examples/README.md` only if the existing example index requires a new row

**Dependencies**: TASK-002
**Parallelizable**: yes, with TASK-003 because write scopes are disjoint

**Tasks**:
- Explain that the bundle defaults to a read-only dry-run mock and never
  publishes, signs, notarizes, deletes, or overwrites data.
- Document how to set `appleGatewayCheckout` for real local use.
- Document how to swap the mock command for a real wrapper around
  `task build:homebrew-cask -- --dry-run`.
- Repeat the credential boundary: Apple credentials live only in the user's
  kinko/env and macOS keychain, never in workflow JSON, node inputs, config, or
  logs.
- Carry the accepted ambient-environment warning into the README: operators
  must run Riela packaging-plan workflows outside credential-bearing kinko
  shells, because local command execution can inherit the Riela process
  environment even when the node JSON does not name credential variables.
- Require real wrappers to fail closed or scrub `APPLE_SIGNING_IDENTITY`,
  `APPLE_ID`, `APPLE_PASSWORD`, and `APPLE_TEAM_ID` before invoking `task`.
- State that real signed Cask and release commands are human-run outside Riela.
- Include the exact validation command for the bundle.

**Deliverable**: Operator-facing README matching the accepted catalog decision.

### TASK-005: Verify No Forbidden Source Changes

**Status**: COMPLETED
**Write Scope**: none
**Dependencies**: TASK-002, TASK-003, TASK-004
**Parallelizable**: no; final verification gate

**Tasks**:
- Confirm no source/test add-on registration files changed.
- Confirm no new built-in id matching `riela/apple-gateway-packaging` exists.
- Confirm no committed machine-local absolute path appears in the new example
  or plan material.
- Confirm no Apple credential values or credential-bearing environment
  templates appear in the example bundle.

**Deliverable**: Progress-log entry with command results and any expected
pre-existing matches called out.

### TASK-006: Run Required Validation

**Status**: COMPLETED
**Write Scope**: none
**Dependencies**: TASK-005
**Parallelizable**: no; final verification gate

**Tasks**:
- Run `riela workflow validate apple-gateway-packaging-plan --workflow-definition-dir examples`.
- Run `swift build`.
- Run `git status --short`.
- Run `git diff --check -- design-docs examples impl-plans`.

**Deliverable**: Progress-log entry with pass/fail status for every command.

---

## Dependencies

| Task | Depends On | Reason |
| ---- | ---------- | ------ |
| TASK-001 | Step 3 accepted design | Implementation must follow the accepted design-doc update. |
| TASK-002 | TASK-001 | The workflow should reuse existing example schema shapes. |
| TASK-003 | TASK-002 directory creation | The script lives inside the new bundle. |
| TASK-004 | TASK-002 | README should document the actual bundle files and paths. |
| TASK-005 | TASK-002, TASK-003, TASK-004 | Forbidden-change checks need the final implementation tree. |
| TASK-006 | TASK-005 | Validation should run after source-boundary checks. |

## Parallelizable Tasks

- TASK-001 is read-only and can run in parallel with other read-only
  inspection.
- TASK-003 and TASK-004 can run in parallel after
  `examples/apple-gateway-packaging-plan/` exists because script and README
  write scopes are disjoint.
- TASK-005 and TASK-006 are not parallelizable; they are ordered verification
  gates.

## Verification

Required commands:

```bash
riela workflow validate apple-gateway-packaging-plan --workflow-definition-dir examples
swift build
git status --short
git diff --check -- design-docs examples impl-plans
env -u APPLE_SIGNING_IDENTITY -u APPLE_ID -u APPLE_PASSWORD -u APPLE_TEAM_ID examples/apple-gateway-packaging-plan/scripts/mock-task-jsonl.sh 'bad"target' | python3 -m json.tool >/dev/null
env -u APPLE_SIGNING_IDENTITY -u APPLE_TEAM_ID APPLE_PASSWORD=redacted APPLE_ID=redacted examples/apple-gateway-packaging-plan/scripts/mock-task-jsonl.sh build:homebrew-cask
rg -n "riela/apple-gateway-packaging|BuiltinWorkflowAddonResolver|RielaBuiltinAddonCatalog|AppleGatewayProcessRunner" Sources Tests examples/apple-gateway-packaging-plan design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md impl-plans/active/apple-gateway-packaging-plan.md
rg -n "/Users/[^[:space:]\"']+|APPLE_SIGNING_IDENTITY=.*|APPLE_ID=.*|APPLE_PASSWORD=.*|APPLE_TEAM_ID=.*" examples/apple-gateway-packaging-plan impl-plans/active/apple-gateway-packaging-plan.md
```

Expected verification notes:
- The `riela/apple-gateway-packaging` search may match design/plan text that
  explicitly rejects the add-on id; it must not match source registration.
- The Apple credential search may match credential names; it must not match
  assigned values or example environment templates carrying credentials.
- Existing unrelated dirty files must remain untouched.

## Completion Criteria

- [x] `examples/apple-gateway-packaging-plan/` exists with workflow, node
      payloads, README, and executable mock script.
- [x] The command mock emits exactly one JSON object line on stdout.
- [x] The command mock fails closed with redacted JSON when Apple signing
      variables are inherited from the command environment.
- [x] The bundle validates without a real Apple Gateway checkout, `task`,
      Apple app access, or signing credentials.
- [x] Documentation explains the command-node recipe, mock-to-real swap, GitHub
      Actions out-of-scope status, and credential boundary.
- [x] No Swift source, add-on resolver, built-in catalog, add-on tests, or
      Apple Gateway process runner files are modified.
- [x] `swift build` and the new example validation pass.
- [x] Progress log records changed files, verification commands, results,
      residual risks, and any deviations from this plan.

## Progress Log Expectations

Every implementation session must append a dated progress-log entry before
handoff. Each entry must include:
- Tasks completed and tasks still open.
- Files changed in that session.
- Exact verification commands run and their pass/fail results.
- Any deviations from the accepted design or this plan.
- Explicit confirmation that no signing credentials were added to workflow
  files, node inputs, config, or logs.

## Progress Log

### Session: 2026-07-07 Step 4 Implementation Plan Creation

**Tasks Completed**: Created actionable implementation plan from accepted Step
3 design.
**Tasks In Progress**: None.
**Blockers**: None.
**Notes**: Implementation must remain documentation/example-only and must not
add a built-in Apple Gateway packaging add-on.

### Session: 2026-07-07 Step 4 Plan Revision After Self-Review

**Tasks Completed**: Tightened TASK-004 README requirements for the accepted
ambient-environment credential warning.
**Tasks In Progress**: None.
**Blockers**: None.
**Notes**: The implementation README must tell operators to run Riela
packaging-plan workflows outside credential-bearing kinko shells and require
real wrappers to fail closed or scrub `APPLE_SIGNING_IDENTITY`, `APPLE_ID`,
`APPLE_PASSWORD`, and `APPLE_TEAM_ID` before invoking `task`.

### Session: 2026-07-07 Step 6 Implementation

**Tasks Completed**: TASK-001 through TASK-006.
**Tasks In Progress**: None.
**Files Changed**:
- `examples/apple-gateway-packaging-plan/workflow.json`
- `examples/apple-gateway-packaging-plan/nodes/node-packaging-plan.json`
- `examples/apple-gateway-packaging-plan/nodes/node-workflow-output.json`
- `examples/apple-gateway-packaging-plan/scripts/mock-task-jsonl.sh`
- `examples/apple-gateway-packaging-plan/README.md`
- `impl-plans/active/apple-gateway-packaging-plan.md`

**Verification**:
- PASS: `python3 -m json.tool examples/apple-gateway-packaging-plan/workflow.json`
- PASS: `python3 -m json.tool examples/apple-gateway-packaging-plan/nodes/node-packaging-plan.json`
- PASS: `python3 -m json.tool examples/apple-gateway-packaging-plan/nodes/node-workflow-output.json`
- PASS: `examples/apple-gateway-packaging-plan/scripts/mock-task-jsonl.sh build:homebrew-cask -- --dry-run | python3 -m json.tool >/dev/null`
- PASS: `riela workflow validate apple-gateway-packaging-plan --workflow-definition-dir examples`
- PASS: `riela workflow inspect apple-gateway-packaging-plan --workflow-definition-dir examples --output json`
- PASS: `swift build` (completed with existing redundant-`public` warnings in `Sources/RielaAppSupport/RielaAppDaemonWorkflowPreference.swift`)
- PASS: `git diff --check -- design-docs examples impl-plans`
- PASS: `git diff --name-only -- Sources Tests` returned no changed source or test files.
- PASS: `rg -n "riela/apple-gateway-packaging" Sources Tests examples/apple-gateway-packaging-plan` returned no source/test/example add-on id matches.
- PASS: `git ls-files 'riela-package.json' '**/riela-package.json'` returned no package manifest, so no digest refresh was applicable.
- PASS WITH EXPECTED MATCHES: `rg -n "riela/apple-gateway-packaging|BuiltinWorkflowAddonResolver|RielaBuiltinAddonCatalog|AppleGatewayProcessRunner" Sources Tests examples/apple-gateway-packaging-plan design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md impl-plans/active/apple-gateway-packaging-plan.md` matched only accepted design/plan rejection text plus pre-existing resolver/catalog/runner references.
- PASS WITH EXPECTED MATCH: `rg -n "/Users/[^[:space:]\"']+|APPLE_SIGNING_IDENTITY=.*|APPLE_ID=.*|APPLE_PASSWORD=.*|APPLE_TEAM_ID=.*" examples/apple-gateway-packaging-plan impl-plans/active/apple-gateway-packaging-plan.md` matched only the verification command text in this plan.
- PASS: `git status --short` showed the new example bundle plus existing Step 3/4 design and plan files; no `Sources/` or `Tests/` changes.

**Deviations**:
- No top-level workflow input schema was added because current example bundles use `workflowInput.*` references without an authored schema field. `appleGatewayCheckout` is documented and kept as a node variable placeholder for real-use wrapper edits.
- The optional live workflow run was not executed because the bundle intentionally ends with a live `codex-agent` projection node and has no deterministic mock scenario. The command mock itself was smoke-checked directly.

**Credential Boundary Confirmation**: No signing credential values were added
to workflow files, node inputs, config, or logs. The example README and catalog
decision document credential names only and require real wrappers to fail
closed or scrub credential variables before invoking `task`.

**Residual Risks**: Real operator wrappers remain documentation-only and must be
reviewed before use in a live checkout. Local command execution can inherit the
Riela process environment, so operators must run the packaging-plan workflow
outside credential-bearing kinko shells.

### Session: 2026-07-07 Step 6 Revision After Step 7 Adversarial Review

**Tasks Completed**: Addressed the Step 7 mid-severity finding that the real
command-node recipes used a checkout-relative `./scripts/task-jsonl-wrapper.sh`
executable together with templated `command.workingDirectory`.
**Tasks In Progress**: None.
**Files Changed**:
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`
- `examples/apple-gateway-packaging-plan/README.md`
- `impl-plans/README.md`
- `impl-plans/active/apple-gateway-packaging-plan.md`

**Review Feedback Addressed**:
- Updated dry-run and formula command-node recipes to use a workflow-owned
  `scriptPath` under the workflow bundle's `scripts/` directory.
- Passed `{{workflowInput.appleGatewayCheckout}}` as the first rendered
  argument rather than through `command.workingDirectory`.
- Documented wrapper-side checkout path validation, Apple credential
  environment scrubbing, and wrapper-owned `cd` into the validated checkout.
- Added an explicit caveat that mock bundle validation does not prove the real
  checkout recipe until a wrapper-shaped command is smoke-tested.

**Verification**:
- PASS: `riela workflow validate apple-gateway-packaging-plan --workflow-definition-dir examples`
- PASS: `swift build`
- PASS: `git diff --check -- design-docs examples impl-plans`
- PASS: `rg -n "workingDirectory\": \"\\{\\{workflowInput.appleGatewayCheckout\\}\\}|executable\": \"\\./scripts/task-jsonl-wrapper.sh" design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md examples/apple-gateway-packaging-plan` returned no rejected real-recipe pattern matches.
- PASS WITH EXPECTED MATCHES: `rg -n "/Users/[^[:space:]\"']+|APPLE_SIGNING_IDENTITY=.*|APPLE_ID=.*|APPLE_PASSWORD=.*|APPLE_TEAM_ID=.*" examples/apple-gateway-packaging-plan impl-plans/active/apple-gateway-packaging-plan.md` matched only verification-command text in this plan.
- PASS WITH EXPECTED MATCHES: `rg -n "riela/apple-gateway-packaging|BuiltinWorkflowAddonResolver|RielaBuiltinAddonCatalog|AppleGatewayProcessRunner" Sources Tests examples/apple-gateway-packaging-plan design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md impl-plans/active/apple-gateway-packaging-plan.md` matched only accepted design/plan rejection text and pre-existing source/test references; no source registration change was made.
- PASS: `git diff --name-only -- Sources Tests` returned no changed source or test files.
- PASS: `git status --short` showed only the design doc, implementation-plan index, new example bundle, and active implementation plan for this task.

**Credential Boundary Confirmation**: No signing credential values were added
to workflow files, node inputs, config, or logs. The revised real-use docs name
credential variables only to require wrapper-side scrubbing.

**Residual Risks**: The real wrapper remains a documented operator-owned file
and was not committed as reusable tooling. A live checkout smoke test is still
required before relying on the real recipe outside the deterministic mock
bundle.

### Session: 2026-07-07 Step 6 Revision After Credential-Boundary Review

**Tasks Completed**: Addressed the latest Step 7 mid-severity finding that the
deterministic mock could report success while Apple signing variables were
present in the inherited command environment.
**Tasks In Progress**: None.
**Files Changed**:
- `examples/apple-gateway-packaging-plan/scripts/mock-task-jsonl.sh`
- `examples/apple-gateway-packaging-plan/README.md`
- `impl-plans/README.md`
- `impl-plans/active/apple-gateway-packaging-plan.md`

**Review Feedback Addressed**:
- Made the deterministic mock enforce the documented credential boundary by
  rejecting `APPLE_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_PASSWORD`, and
  `APPLE_TEAM_ID` when present in the command environment.
- Added a redacted credential-boundary failure payload with non-zero exit,
  without printing credential values.
- Replaced hand-built mock JSON with encoder-produced JSON so quoted target
  arguments remain valid JSON.
- Added verification commands for the inherited-credential failure path and the
  quoted-target JSON escaping path.

**Verification**:
- PASS: `env -u APPLE_SIGNING_IDENTITY -u APPLE_ID -u APPLE_PASSWORD -u APPLE_TEAM_ID examples/apple-gateway-packaging-plan/scripts/mock-task-jsonl.sh build:homebrew-cask | python3 -m json.tool >/dev/null`
- PASS: `env -u APPLE_SIGNING_IDENTITY -u APPLE_ID -u APPLE_PASSWORD -u APPLE_TEAM_ID examples/apple-gateway-packaging-plan/scripts/mock-task-jsonl.sh 'bad"target' | python3 -m json.tool >/dev/null`
- PASS: `env -u APPLE_SIGNING_IDENTITY -u APPLE_TEAM_ID APPLE_PASSWORD=redacted APPLE_ID=redacted examples/apple-gateway-packaging-plan/scripts/mock-task-jsonl.sh build:homebrew-cask` exited non-zero and emitted redacted JSON naming only rejected env names.
- PASS: `riela workflow validate apple-gateway-packaging-plan --workflow-definition-dir examples`
- PASS: `riela workflow inspect apple-gateway-packaging-plan --workflow-definition-dir examples --output json`
- PASS: `riela workflow run apple-gateway-packaging-plan --workflow-definition-dir examples --output json` failed closed with provider error while this agent process had inherited Apple credential variables.
- PASS: `env -u APPLE_SIGNING_IDENTITY -u APPLE_ID -u APPLE_PASSWORD -u APPLE_TEAM_ID riela workflow run apple-gateway-packaging-plan --workflow-definition-dir examples --output json`
- PASS: `swift build`
- PASS: `git diff --check -- design-docs examples impl-plans`
- PASS: `git diff --name-only -- Sources Tests` returned no changed source or test files.
- PASS WITH EXPECTED MATCHES: `rg -n "/Users/[^[:space:]\"']+|APPLE_SIGNING_IDENTITY=.*|APPLE_ID=.*|APPLE_PASSWORD=.*|APPLE_TEAM_ID=.*" examples/apple-gateway-packaging-plan impl-plans/active/apple-gateway-packaging-plan.md` matched only verification-command text in this plan.
- PASS WITH EXPECTED MATCHES: `rg -n "riela/apple-gateway-packaging|BuiltinWorkflowAddonResolver|RielaBuiltinAddonCatalog|AppleGatewayProcessRunner" Sources Tests examples/apple-gateway-packaging-plan design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md impl-plans/active/apple-gateway-packaging-plan.md` matched only accepted design/plan rejection text and pre-existing source/test references; no source registration change was made.

**Credential Boundary Confirmation**: No signing credential values were added
to workflow files, node inputs, config, or logs. The mock now fails closed when
credential variables are inherited and reports only variable names plus the
literal redaction marker.

**Residual Risks**: The real wrapper remains a documented operator-owned file
and was not committed as reusable tooling. A live checkout smoke test is still
required before relying on the real recipe outside the deterministic mock
bundle.

## Related Plans

- **Related**: `impl-plans/active/apple-notes-list-addon.md`
- **Related**: `impl-plans/active/apple-gateway-admin-addons.md`
