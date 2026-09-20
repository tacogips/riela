# Agent-Node Output Contract Implementation Plan

**Status**: Planned — design accepted, no code written (this plan authored in a planning-only run)
**Workflow Mode**: feature
**Feature Fanout**: false — one feature, one work package
**Design Reference**: `design-docs/specs/design-agent-node-output-contract.md` (all sections)
**Created**: 2026-09-21
**Last Updated**: 2026-09-21

## Accepted Design And Review

- Source of truth: `design-docs/specs/design-agent-node-output-contract.md`.
- Decisions D1–D4 recorded there with rejected alternatives; runtime vs
  bundle assignment is section 2's table.
- Brief correction carried from analysis: the empty-commit-message guard is
  `Sources/RielaCLI/ProductionNodeAdapter+GitAddons.swift:73`
  (`renderedCommitMessage`), called from
  `ProductionNodeAdapter+GitCommit.swift:24` — not GitCommit.swift itself.
- No backward compatibility anywhere: no warning phases, no opt-out flags,
  no tolerant decoding of the replaced no-contract envelope sniffing.
- Applicable prior knowledge: team knowledge-base recall for
  `agent-node-output-contract` returned zero results (2026-09-21); no prior
  knowledge applies. Repository-level operational knowledge that DOES apply
  to the implementation session: run `swift test` from an arm64 shell
  (`arch -arm64 /bin/zsh -lc`), and register any new/edited example
  workflows in `rielaExampleWorkflowNames()` and mock counts, then run
  `RielaCLITests`.

## Scope

### Included (riela runtime — this repository)

- Two new validation rules in `Sources/RielaCore/WorkflowValidation.swift`
  (D1 sandbox rule, D2a schema rule).
- No-contract path simplification and schema-default retry budget in
  `Sources/RielaAdapters/AgentGatewayNodeAdapter.swift` and
  `Sources/RielaCore/DeterministicWorkflowRunner+Prompting.swift` (D2b).
- Strict addon config/inputs rendering with a typed template-resolution
  error in `Sources/RielaAddonSupport/WorkflowAddonSupport.swift` plus its
  error type and publication classification (D3).
- Repairs to in-repo example workflows/fixtures that the new validation
  rules reject (they are part of this tree, hence this work package).
- Tests for every rule and path change; docs/skills text that states the
  contract.

### Excluded (riela-packages — separate follow-up work package, D4)

- `packages/fable-and-improve-opus/workflows/fable-and-improve-opus`:
  add `agentSandbox` to all 16 agent nodes; add `output.jsonSchema` (+
  `maxValidationAttempts` where flaky) to every payload-referenced or
  label-driving node (at minimum `plan-checkpoint`,
  `step9-commit-message`); `commitMessage` schemas use `minLength: 1`;
  update `EXPECTED_RESULTS.md` and mock scenario. The riela-packages
  repository was read-only evidence in the planning run and is not touched
  by this plan's tasks. The same treatment applies to the sibling
  `fable-and-improve-codex` / `fable-and-improve` packages when D4 lands.

## Task Table

| Task | Deliverables | Primary write scope | Depends on | Parallelizable |
| ---- | ------------ | ------------------- | ---------- | -------------- |
| T1 D1 sandbox validation | Error diagnostics for omitted `agentSandbox` on codex/claudeCode/cursor backends and for declared `agentSandbox` on API backends; backend→vendor sandbox-consumption table lives beside the rule | `Sources/RielaCore/WorkflowValidation.swift`, `Tests/RielaCoreTests/` (validation suite) | — | Yes (with T3, T4) |
| T2 D2a schema validation | Error diagnostics: templated payload without producer schema; referenced first-segment field missing from `schema.properties`; conditional transition labels without schema. Template scanning over addon `config`/`inputs` and node `variables` of one-transition successors | `Sources/RielaCore/WorkflowValidation.swift`, `Tests/RielaCoreTests/` | T1 (same file — serialize edits) | No (shares WorkflowValidation.swift with T1) |
| T3 D2b answer path + retry default | Delete opportunistic `{`-prefix envelope sniffing in `normalizeGatewayOutput` (no-contract branch = pure text wrap); `maxValidationAttempts` default 2 when `output.jsonSchema != nil` | `Sources/RielaAdapters/AgentGatewayNodeAdapter.swift`, `Sources/RielaCore/DeterministicWorkflowRunner+Prompting.swift`, adapter/runner tests | — | Yes (with T1, T4) |
| T4 D3 template resolution error | Typed `templateResolutionFailed` error carrying producer step (`_rielaInput.latest.fromStepId`), template path, consumer step/node/addon; strict rendering for addon `config`/`inputs` before any addon side effect; prompt rendering stays lenient; error surfaces through the existing adapter-failure publication path | `Sources/RielaAddonSupport/WorkflowAddonSupport.swift`, new error type (RielaCore or RielaAddonSupport), `Sources/RielaCLI/ProductionNodeAdapter+GitAddons.swift` call sites only if signatures force it, addon-support tests | — | Yes (with T1, T3) |
| T5 Example/fixture reconciliation | Every in-repo example workflow and test fixture validates under T1+T2 rules; `rielaExampleWorkflowNames()` registration + mock counts intact; `RielaCLITests` green | `Sources/`/`Tests/` example + fixture JSON, `Tests/RielaCLITests/` | T1, T2, T3, T4 | No (sweeps the whole tree after rules land) |
| T6 Docs | Contract stated in the workflow authoring docs/skills text this repo owns (riela-workflow skill sources, design-doc cross-links) | `skills/` or `docs/` workflow-authoring text in this tree | T1–T4 | Yes (with T5) |
| T7 (follow-up package) D4 bundle | Listed for traceability only — executed as its own work package in `tacogips/riela-packages`, per Excluded section | riela-packages (NOT this repo) | T1–T6 released | — |

Dependency waves: wave 1 = T1, T3, T4 (disjoint files); wave 2 = T2 (same
file as T1, serial); wave 3 = T5, T6; T7 external. Shared file:
`WorkflowValidation.swift` (T1→T2 strictly ordered, fresh read before T2).

## Per-Task Completion Evidence

Record evidence per box when implementation runs; all boxes unchecked at
authoring time (planning-only run — no code written).

- [ ] T1: validation tests cover omitted-sandbox error per backend and
      declared-sandbox-on-API-backend error; full `swift test` green (arm64
      shell); evidence = test names + run output.
- [ ] T2: validation tests cover the three D2a error shapes plus green
      compliant fixtures; evidence = test names + run output.
- [ ] T3: adapter test proves `{`-prefixed malformed no-contract answer
      yields `{text}` with no envelope; runner test proves schema-default
      retry of exactly 2 and declared value wins; evidence = test names +
      run output.
- [ ] T4: addon-support test proves missing config path fails with
      producer/path/consumer in the message and the addon body never ran;
      prompt lenient test unchanged; evidence = test names + run output.
- [ ] T5: full `swift test` from repo root green, including `RielaCLITests`
      example suites; evidence = summary counts.
- [ ] T6: docs text states the contract (answer shape, retry budget,
      operator-visible failures, validate rules); evidence = file paths.

## Verification Plan

1. `arch -arm64 /bin/zsh -lc 'swift test'` from repo root — zero failures
   (known interleaved-submit timing flake excepted, rerun to confirm).
2. `swift run riela workflow validate` against an in-repo example that
   deliberately violates each rule (temporary fixture) — the three error
   messages name node, field, and rule.
3. Read-back of `normalizeGatewayOutput`: no-contract branch contains no
   JSON parsing.
4. For this planning run itself: `git diff --stat` proof below — no
   `Sources/` or `Tests/` path modified.

## Completion Criteria

- All D1–D3 rules implemented with the exact error shapes in the design;
  D2b behavior changes (sniffing deleted, default 2 attempts) in place.
- Full test suite green; in-repo examples validate.
- Docs updated; D4 follow-up package task filed for riela-packages.

## Progress Log

### 2026-09-21 — Plan authored (planning-only run; no code written)

First entry, recorded per acceptance criteria: **no production code and no
test code were written in this run.** The run's changes are exactly the
design document, this plan, and the `impl-plans/README.md` index row, on
branch `design/agent-node-output-contract` (base branch identical), off
`main` at `ca1ce34`.

**Diff-proof correction.** The verification hint asked for
`git diff --stat main..HEAD`, but local `main` has advanced past this
branch's base (`main` = `c33a783`, merge-base(main, HEAD) = HEAD =
`ca1ce34`), so bare `main..HEAD` shows main's own later commits
(control-surface-parity et al.), not this run's changes. The correct
this-run-only proof is against the recorded base:

```
$ git merge-base main HEAD
ca1ce34235e5d2d358ea32a45e7d435d272763b4
$ git diff --stat ca1ce34..HEAD
(empty — no commits unique to this branch at authoring time)
$ git status --porcelain   # working tree after authoring, before checkpoint
 M impl-plans/README.md
?? design-docs/specs/design-agent-node-output-contract.md
?? impl-plans/active/agent-node-output-contract.md
```

No `Sources/` or `Tests/` path appears. After the checkpoint commit,
`git diff --stat ca1ce34..HEAD` must list exactly these three doc paths;
the checkpoint records that output here:

```
<checkpoint: paste git diff --stat ca1ce34..HEAD after committing>
```
