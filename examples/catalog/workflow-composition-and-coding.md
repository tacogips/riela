# Examples: Workflow Composition and Coding Examples

### `workflow-call-simple`

Managed parent workflow reference for cross-workflow invocation in the
step-addressed authored shape:

- `riela-manager` stays on `claude-code-agent`
- `draft-write` and `apply-review` stay on `codex-agent`
- explicit `managerStepId: "riela-manager"` and `entryStepId:
"riela-manager"` define the parent entry
- `steps[]` carries the authored manager-to-draft progression directly
- `draft-write` declares a cross-workflow transition targeting
  `workflow-call-review-target` (`toStepId: "reviewer"`) with
  `resumeStepId: "apply-review"`
- the engine executes that transition using the deterministic runtime workflow-call id
  `__cw:draft-write`; session communications use
  `transitionWhen = "workflow-call:__cw:draft-write"`
- the bundled deterministic mock scenario covers both the parent and callee
  node ids so the full call chain can be run from one command

Validate it:

```bash
riela workflow validate workflow-call-simple --workflow-definition-dir ./examples
```

Inspect it:

```bash
riela workflow inspect workflow-call-simple --workflow-definition-dir ./examples --output json
```

Run it with the bundled deterministic scenario:

```bash
riela workflow run workflow-call-simple \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/workflow-call-simple/mock-scenario.json \
  --output json
```

### `workflow-call-review-target`

Worker-only callee bundle used by `workflow-call-simple`:

- no authored `managerStepId`
- explicit `entryStepId: "reviewer"`
- returns its latest succeeded worker result to the caller workflow-call
  contract
- can also be validated, inspected, and run standalone

Validate it:

```bash
riela workflow validate workflow-call-review-target --workflow-definition-dir ./examples
```

Inspect it:

```bash
riela workflow inspect workflow-call-review-target --workflow-definition-dir ./examples --output json
```

Run it standalone with the bundled deterministic scenario:

```bash
riela workflow run workflow-call-review-target \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/workflow-call-review-target/mock-scenario.json \
  --output json
```

### `workflow-call-live-echo` and `workflow-call-live-echo-callee`

Live cross-workflow dispatch smoke pair that needs **no** mock scenario and no
agent backend:

- both bundles use only command nodes (`/bin/sh` echoes), so `workflow run`
  executes fully live
- `workflow-call-live-echo` authors a `toWorkflowId` + `toStepId` +
  `resumeStepId` transition on `produce-request`; the runner dispatches
  `workflow-call-live-echo-callee` in a child session and delivers the callee
  root output to `apply-result`
- the callee echoes the caller handoff back through `{{handoff}}` templating,
  so the caller root output proves end-to-end delivery

Run it live:

```bash
riela workflow run workflow-call-live-echo \
  --workflow-definition-dir ./examples \
  --output json
```

### `design-and-implement-review-loop`

Real development workflow sample adapted from the project-local workflow catalog:

- starts with issue intake and design-document update
- can call `design-and-implement-review-loop-feature-plan` for bounded
  feature-plan fanout
- runs self-review and independent review gates before implementation
- creates and reviews an implementation plan before coding
- delegates implementation to `codex-agent`
- refreshes documentation, prepares a commit message, then uses the built-in
  `riela/git-commit` and `riela/git-push` add-ons
- includes deterministic mock scenarios for full issue resolution and
  planning-only execution

Validate it:

```bash
riela workflow validate design-and-implement-review-loop --workflow-definition-dir ./examples
```

Run the full deterministic scenario:

```bash
riela workflow run design-and-implement-review-loop \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/design-and-implement-review-loop/mock-scenario.json \
  --output json
```

Live execution note:

- this workflow can create commits and push them when run with live backends;
  use the bundled mock scenarios for deterministic sample verification

### `design-and-implement-review-loop-feature-plan`

Worker-only companion workflow used by the bounded fanout path in
`design-and-implement-review-loop`:

- no authored manager step
- starts at `step2-design-doc-update`
- loops through design self-review, independent design review, implementation
  plan creation, plan self-review, and independent plan review
- returns a feature-local design and implementation-plan result to the caller

Validate it:

```bash
riela workflow validate design-and-implement-review-loop-feature-plan --workflow-definition-dir ./examples
```

### `recent-change-quality-loop`

Real development workflow sample for reviewing recent repository changes:

- reviews committed changes from a configurable recent time window plus
  uncommitted changes
- routes through an exit gate that detects high or mid severity findings
- delegates blocking findings to `design-and-implement-review-loop` through a
  cross-workflow transition
- resumes after the delegated fix, then re-runs review until no blocking
  finding remains

Validate it:

```bash
riela workflow validate recent-change-quality-loop --workflow-definition-dir ./examples
```

Run it with the bundled deterministic scenario:

```bash
riela workflow run recent-change-quality-loop \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/recent-change-quality-loop/mock-scenario.json \
  --output json
```

Live execution note:

- because this workflow delegates to `design-and-implement-review-loop`, live
  execution can also create commits and push them through that delegated
  workflow

### `loop-engineer-quality-loop`

Loop engineer focused workflow for making a repeated automation pass observable
and reviewable:

- captures the loop symptom and acceptance target
- maps entry, repeated step, progress state, and exit condition
- defines counters, trace fields, and regression probes for the next pass
- repeats planning once when the probe shows missing exit-path evidence
- finishes through a required `workflow.loop` review gate that records loop
  evidence with no blocking findings

Validate it:

```bash
riela workflow validate loop-engineer-quality-loop --workflow-definition-dir ./examples
```

Run it with the bundled deterministic scenario:

```bash
riela workflow run loop-engineer-quality-loop \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/loop-engineer-quality-loop/mock-scenario.json \
  --output json
```

### `required-loop-gate-failure`

Minimal required-loop fail-closed reference:

- one `implementation-review` step
- `workflow.loop.required` is `true`
- one required `implementation-review` gate with `maxHighFindings` and
  `maxMediumFindings` set to `0`
- deterministic rejected mock scenario returns a high finding
- CLI exits non-zero while preserving loop evidence for `riela loop gates`

Validate it:

```bash
riela workflow validate required-loop-gate-failure --workflow-definition-dir ./examples
```

Run the rejected deterministic scenario:

```bash
riela workflow run required-loop-gate-failure \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/required-loop-gate-failure/mock-scenario-rejected.json \
  --session-store ./tmp/required-loop-gate-failure/sessions \
  --artifact-root ./tmp/required-loop-gate-failure/artifacts \
  --output json
```

### Loop engineering operations examples

Five focused bundles demonstrate the loop convergence/operations surface, and
`loop-ci-gate-check` covers CI gating. Each bundle carries its own `README.md`
and `EXPECTED_RESULTS.md` with the exact commands and stable assertions.

- `loop-stall-guard` — `loop.convergence` repeated-finding stall detection:
  identical rejected findings for `maxRepeatedFindingRounds` rounds emit a
  `loop_stall` event and fail the session closed with
  `failureKind: loopNotConverging`; a second scenario shows that changed
  findings never false-stall.
- `loop-budget-guard` — `loop.budget` step-boundary enforcement: an
  impossible `maxWallClockMs: 1` deterministically emits one
  `budget_exceeded` event and fails the session with
  `failureKind: budgetExceeded`.
- `loop-baseline-regression-ops` — the operations tour: `loop start` (policy
  panel + `--var`), `loop baseline set|show|clear`, `loop regress` (exit 3 on
  regression), `loop diff --baseline`, `loop stats`,
  `loop findings --format json`, and `loop promote` readiness.
- `loop-outcome-notifications` — `loop.notifications` terminal-outcome
  dispatch to a workflow-relative command channel (payload on stdin) and an
  env-indirected webhook channel, with persisted dispatch diagnostics.
- `loop-concurrency-lease` — `loop.concurrency` advisory single-flight
  lease: a concurrent run is refused at preflight with a
  `loop_concurrency_busy` record and no session; includes `run-demo.sh`.
- `loop-ci-gate-check` — CI gating with `loop gates --check` pinned exit
  codes and SARIF 2.1.0 export via `loop findings --format sarif`.

### `subworkflow-chained-simple`

Minimal runnable reference for two sequential grouped lanes in the
step-addressed authored shape. The directory name is historical; this is not
the structural sub-workflow compatibility reference.

- explicit `managerStepId: "riela-manager"` and `entryStepId: "riela-manager"`
- `steps[]` carries the alpha-to-beta execution order directly
- grouped lane payloads live under `workflows/alpha/` and `workflows/beta/`

Validate it:

```bash
riela workflow validate subworkflow-chained-simple --workflow-definition-dir ./examples
```

Inspect it:

```bash
riela workflow inspect subworkflow-chained-simple --workflow-definition-dir ./examples --output json
```

Run it with the bundled deterministic scenario:

```bash
riela workflow run subworkflow-chained-simple \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/subworkflow-chained-simple/mock-scenario.json \
  --output json
```

### `claude-riela-codex-coding`

Recommended mixed-backend reference:

- explicit `managerStepId: "riela-manager"` and `entryStepId: "riela-manager"`
- `steps[]` expresses the execution order directly while `nodes[]` stays a reusable registry
- `riela` manager nodes use `claude-code-agent`
- implementation planning/finalization stays on `claude-code`
- the actual coding node uses `codex-agent`
- the workflow-level `rielaPromptTemplate` explicitly prefers `riela graphql`
- node prompt templates can read resolved upstream workflow message data through
  `{{inbox.*}}`
- long node prompts live in `prompts/*.md` and are referenced by
  `node-{id}.json.promptTemplateFile`

Validate it:

```bash
riela workflow validate claude-riela-codex-coding --workflow-definition-dir ./examples
```

Inspect it:

```bash
riela workflow inspect claude-riela-codex-coding --workflow-definition-dir ./examples --output json
```

Run it with the bundled deterministic scenario:

```bash
riela workflow run claude-riela-codex-coding \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/claude-riela-codex-coding/mock-scenario.json \
  --output json
```
