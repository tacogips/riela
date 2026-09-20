# Agent-node output contract: sandbox declaration, payload validation, and template resolution failures

Status: accepted design, 2026-09-21. Not implemented. Plan:
`impl-plans/active/agent-node-output-contract.md`. This design closes the
execution-contract gap that made two real `fable-and-improve-opus` runs
(riela 0.1.38, package 0.4.0, observed 2026-09-21) die several steps away
from their causes. Related: `design-docs/specs/design-work-runtime-consolidation.md`
(evidence quality depends on steps failing at their cause),
`design-loop-engineering-convergence-and-operations.md` (routing labels).

## 1. Problem

Three defects, each verified in this tree at `ca1ce34`:

1. **Omitted `agentSandbox` silently strips write permission.**
   `Sources/RielaAdapters/AgentGatewayNodeAdapter.swift:660`
   (`claudePermissionMode(for:)`) maps `readOnly → "plan"`,
   `workspaceWrite → "acceptEdits"`, `dangerFullAccess → "bypassPermissions"`,
   and `nil → nil`; line 608 appends `--permission-mode` only when the mapping
   is non-nil. A `claude-code-agent` node without `agentSandbox` launches
   headless claude with no permission flag, which denies writes and mkdir.
   `Sources/RielaCore/WorkflowModel.swift:777` declares
   `agentSandbox: AgentSandboxMode?` optional, and
   `Sources/RielaCore/WorkflowValidation.swift` contains no diagnostic that
   mentions it. In the affected bundle
   (`riela-packages/packages/fable-and-improve-opus/workflows/fable-and-improve-opus`,
   read-only evidence) only 5 of 16 `claude-code-agent` node files declare
   `agentSandbox`; `nodes/node-plan-checkpoint.json` — the node that blocked —
   declares neither `agentSandbox` nor any `output` contract.

2. **Schema-less answers become `{text: …}` with no validation and no
   retry.** `Sources/RielaAdapters/AgentGatewayNodeAdapter.swift:719`
   (`normalizeGatewayOutput`): when the node has no output contract and the
   trimmed answer does not start with `{`, the whole answer is wrapped by
   `normalizeTextBusinessPayload` (`Sources/RielaCore/AdapterContracts.swift:295`,
   `["text": .string(text)]`) with `completionPassed: true` and routing
   `when: ["always": true]`. An answer that does start with `{` but fails
   envelope normalization is swallowed by `try?` back to the same text wrap.
   `DefaultWorkflowOutputValidator.validate`
   (`Sources/RielaCore/RuntimeOutputValidation.swift:41`) accepts any payload
   when `contract == nil`. `maxValidationAttempts(from:)`
   (`Sources/RielaCore/DeterministicWorkflowRunner+Prompting.swift:17`)
   defaults to 1, and the attempt loop
   (`Sources/RielaCore/DeterministicWorkflowRunner.swift:875`) retries only on
   `.validationRejected` — which can never fire without a schema. In the
   bundle, only 4 of 16 agent nodes declare `output.jsonSchema` (the same 4
   declare `maxValidationAttempts`); `nodes/node-step9-commit-message.json`
   has an `output.description` asking for `commitMessage` but no schema, so
   nothing enforces it.

3. **A missing template path silently renders `""` and surfaces as the
   consumer's domain error.** `Sources/RielaCore/PromptTemplate.swift:21`:
   `lookupPath(path, in: variables).map(formatTemplateValue) ?? ""` — a
   missing path becomes the empty string with no diagnostic.
   `Sources/RielaAddonSupport/WorkflowAddonSupport.swift:18`
   (`addonVariables`) builds `inbox.latest.output.payload` from
   `_rielaInput.latest.payload`; `exactTemplateValue` / `lookupTemplatePath`
   in the same file return nil silently. The rendered empty string then hits
   `renderedCommitMessage` (`Sources/RielaCLI/ProductionNodeAdapter+GitAddons.swift:63-76`),
   which throws `policyError("riela/git-commit commit message is empty or
   invalid")` at line 73 — the operator sees a git-add-on policy error for a
   contract violation committed steps upstream. The bundle consumes
   `{{inbox.latest.output.payload.commitMessage}}` at `workflow.json:127` and
   `:159`.

**Brief correction (recorded per mandate).** The task brief attributed the
empty-commit-message error to `Sources/RielaCLI/ProductionNodeAdapter+GitCommit.swift`.
The guard actually lives in `Sources/RielaCLI/ProductionNodeAdapter+GitAddons.swift:73`
inside `renderedCommitMessage(_:variables:)`; `ProductionNodeAdapter+GitCommit.swift:24`
is its caller. Everything else in the brief matched the source exactly,
including the permission-mode mapping and the 5-of-16 / 4-of-16 bundle counts.

A second discovered fact the brief did not know: tolerant extraction already
exists. `parseJSONObjectCandidate` (`Sources/RielaCore/RuntimeOutputExtraction.swift:3`)
extracts complete JSON, a balanced `{…}` prefix, a fenced block (json-tagged
fences preferred over untagged), and an embedded object — but it only runs
when the node has an output contract (or opportunistically when the answer
starts with `{`). The tolerant-vs-strict decision below is therefore about
when that extractor runs, not about building one.

## 2. Decision summary and runtime/bundle assignment

A runtime fix repairs every package at once; a bundle fix repairs one. Each
defect splits accordingly:

| # | Decision | Where |
| - | -------- | ----- |
| D1 | `workflow validate` **error** when a node on a sandbox-consuming agent backend omits `agentSandbox` (and when a node on a non-sandbox backend declares it) | riela runtime |
| D2a | `workflow validate` **error** when a node's payload is referenced by a downstream template, or its step has conditional transition labels, and the node declares no `output.jsonSchema` | riela runtime |
| D2b | With a contract: keep tolerant extraction + strict envelope + schema validation + retry; default validation attempts become **2** when a schema is present. Without a contract (now provably inconsequential): pure `{text: …}` wrap; the opportunistic `try?` envelope sniffing at `AgentGatewayNodeAdapter.swift:728-731` is deleted | riela runtime |
| D3 | Addon `config`/`inputs` template rendering fails with a typed template-resolution error naming producing step, field path, and consuming step; the addon never executes. Prompt-template rendering stays lenient | riela runtime |
| D4 | Add `agentSandbox` to all 16 agent nodes; add `output.jsonSchema` + `maxValidationAttempts` to every payload-referenced or label-driving node | riela-packages bundle (separate follow-up work package; that repo is read-only in this run) |

No backward compatibility anywhere: no warnings-instead-of-errors phase, no
opt-out flag, no tolerant decoding of the replaced no-contract envelope
sniffing. Consequences of each break are stated inline below.

## 3. D1 — agentSandbox becomes mandatory on sandbox-consuming backends

### Decision

`WorkflowValidation.validate(_:nodePayloads:)`
(`Sources/RielaCore/WorkflowValidation.swift:102`) gains a rule:

- For every node whose `executionBackend` resolves to a gateway vendor that
  consumes `agentSandbox` in the CLI argument builder — today `codex`,
  `claudeCode`, and `cursor` per `AgentGatewayNodeAdapter.swift:601-611` —
  omitting `agentSandbox` is a **validation error**:
  `workflow.nodes.<id>.agentSandbox — agent nodes on <backend> must declare
  agentSandbox (readOnly | workspaceWrite | dangerFullAccess); omitting it
  launches the agent with no permission flag and silently denies writes`.
- For every node on a backend that ignores the field (`openAI`, `anthropic`,
  `gemini`, `openRouter`, `cursorAPI`), declaring `agentSandbox` is also a
  validation error — a declared sandbox that is silently dropped is the same
  class of lie the rule exists to kill.

The adapter mapping itself does not change: `nil` can no longer reach it from
a validated workflow.

### Why validation, not a default

- **Rejected: per-backend default (`workspaceWrite`).** Silently widens
  permissions for every existing node that omitted the field — today those
  nodes cannot write; after the default they can. A permission grant should
  never be an implicit side effect of an upgrade.
- **Rejected: per-backend default (`readOnly`).** Preserves today's effective
  deny-writes behavior but perpetuates the exact trap observed: the
  plan-checkpoint node would still be unable to write, only now the denial is
  baked in rather than accidental. The run still dies far from the cause.
- **Rejected: warning-level diagnostic.** Warnings do not stop a run;
  the observed failure mode is precisely a run that proceeds into a
  far-from-cause death. Also forbidden by the no-back-compat mandate as a
  de-facto deprecation window.

### Cost (stated, migration-free)

Every installed workflow with an agent node lacking `agentSandbox` fails
`workflow validate` — and therefore `workflow run` — immediately after
upgrade, until its bundle adds the field. This includes 11 of 16 nodes in
`fable-and-improve-opus` (D4). This is intentional: the failure moves from
mid-run, steps-from-cause, to before the run starts, naming the node and the
field.

## 4. D2 — the agent-node output contract

### The contract, stated precisely

- **What an answer must look like to become a payload.** For a node with
  `output.jsonSchema`: the answer must contain exactly one extractable JSON
  object — the whole answer, a balanced `{…}` prefix, a fenced block
  (```json preferred), or an embedded object, in
  `parseJSONObjectCandidate`'s existing order
  (`RuntimeOutputExtraction.swift:3`). The object passes envelope
  normalization (`normalizeOutputContractEnvelope`), and its business payload
  must satisfy the schema per `DefaultWorkflowOutputValidator`
  (`RuntimeOutputValidation.swift`). Prose around a fence is tolerated; the
  fence's content is the candidate. This keeps the existing tolerant
  extractor and rejects the strict-rejection-of-fenced-answers alternative:
  agents demonstrably wrap JSON in prose, and the fence is unambiguous —
  rejecting it buys retries without buying correctness.
- **What happens to an answer that does not.** The attempt is rejected
  (`.validationRejected`) with the validator's reason. The runner's existing
  loop (`DeterministicWorkflowRunner.swift:875-983`) re-invokes the node with
  attempt context (`AdapterOutputAttemptContext`) up to the attempt budget;
  the schema-example prompt injection at
  `DeterministicWorkflowRunner+Prompting.swift:153` already tells the agent
  what shape was expected.
- **How many attempts a node gets.** `max(1, declared maxValidationAttempts)`
  when declared. Undeclared **with** a schema: **2** (one retry) — the retry
  is the point of declaring a schema, and a runtime default repairs every
  package at once. Undeclared without a schema: 1, unchanged and irrelevant
  (no rejection can occur). This changes `maxValidationAttempts(from:)` at
  `DeterministicWorkflowRunner+Prompting.swift:17`. Behavior change stated:
  schema-bearing nodes that previously failed on the first malformed answer
  now retry once; runs get slower on the failure path and succeed more often.
- **What the operator sees when a node breaks the contract.** The producing
  step itself fails with `validationRejected`, carrying node id, attempt
  count (`attempt/maxAttempts`), and the schema-path reason (e.g.
  `output contract $.commitMessage required property is missing`). No
  downstream step runs. This is existing plumbing; D2a's job is to guarantee
  the contract exists wherever a downstream step depends on it.

### D2a — validate-time schema requirement

New rule in `WorkflowValidation.validate(_:nodePayloads:)`, **error** when
either holds for a node N and it declares no `output.jsonSchema`:

1. **Payload referenced downstream.** Some step S is reachable from a step of
   N by one transition, and S's addon `config` or `inputs` (or S's node
   `variables`) contain a template referencing
   `inbox.latest.output.payload.<field>` (or `input.<field>` sourced from the
   inbox). The validator additionally checks that each referenced
   first-segment `<field>` appears in N's `schema.properties`; a referenced
   field absent from the schema is its own error (the schema would validate
   the wrong shape). All template strings are already present in
   `workflow.json`/node payloads at validate time — no new inputs needed.
2. **Conditional routing.** N's steps have outgoing transitions with labels
   other than `always`. Labels come from the answer envelope's `when`; without
   a contract, `normalizeGatewayOutput`'s fallback fabricates
   `when: ["always": true]`, so a malformed answer silently takes the
   `always`-ish route instead of failing. Requiring a schema (a permissive
   `{"type":"object"}` suffices) flips the node onto the strict path where a
   malformed envelope rejects and retries.

Costs, stated: existing workflows with templated payloads or labeled
transitions and no schemas fail validation after upgrade until schemas are
added (in `fable-and-improve-opus`: 12 of 16 nodes, including
`step9-commit-message` and `plan-checkpoint`). Rejected alternatives:
**warning** (run proceeds into the exact observed failure), **allowed**
(status quo), **runtime-only enforcement** (fails mid-run instead of before
the run; validate-time is strictly earlier and names the node while the
operator is still at the terminal).

### D2b — the no-contract path becomes honest

After D2a, a schema-less node is provably one whose payload nobody reads and
whose routing is unconditional. Its answer is wrapped as
`{text: <full answer>}` with `completionPassed: true` — unchanged. The
opportunistic envelope sniffing for `{`-prefixed answers
(`AgentGatewayNodeAdapter.swift:728-731`, including its `try?` silent
fallback) is **deleted**: with D2a in force, any node that needs the envelope
has a schema, and a half-tolerant path whose parse failures silently degrade
to a text wrap is exactly the contract this design replaces. Consequence: a
schema-less node that today emits a JSON envelope to drive `when` routing
loses that ability — validation now directs its author to declare a schema.

## 5. D3 — template resolution failure contract

### Decision

Rendering addon `config` and `inputs` (the machine-consumed surfaces —
`renderJSONTemplates` / `renderAddonInputs` in
`Sources/RielaAddonSupport/WorkflowAddonSupport.swift`) becomes **strict**: a
template path that resolves to nothing raises a typed error instead of
rendering `""`. The error is a new category (template-resolution failure,
distinct from the addon's own `policyError` domain) and must carry:

- the **producing step**: `_rielaInput.latest.fromStepId` (present in the
  resolved input payload `addonVariables` already receives; verified in live
  payloads — `latest` carries `fromStepId` and `sourceStepExecutionId`),
- the **field path** as written in the template
  (`inbox.latest.output.payload.commitMessage`),
- the **consuming step / node / addon** (`stepId`, `nodeId`, `addonName` are
  already in the variables object at `WorkflowAddonSupport.swift:52-55`).

Shape: `templateResolutionFailed: step '<consumer>' addon '<addon>' template
'{{<path>}}' resolved to nothing; the producing step '<producer>' did not
publish payload field '<field>'`. The addon body never executes — the failure
is raised during variable/config rendering, before any side effect. The step
fails with this error; it is not the consumer's domain error, and with D2a in
force it indicates a schema that lied (the field was in `properties` but the
producer omitted it and the schema didn't `require` it) — the message says
where to look.

Prompt-template rendering (`renderPromptTemplate` used for agent prompts)
stays lenient (missing → `""`): prose prompts legitimately reference optional
context, and an error there would make every optional variable mandatory.
This boundary — strict for machine-consumed JSON, lenient for model-consumed
prose — is the deliberate line, not an oversight.

Rejected alternatives: **strict everywhere** (breaks every prompt that
references optional context; prompts degrade gracefully by construction);
**leave lenient, rely on D2a schemas alone** (a schema with a non-required
property still lets an absent field render `""` — the observed
`git-commit` death remains reachable); **consumer-side emptiness checks**
(that is exactly today's `GitAddons.swift:73` behavior — the error names the
wrong actor and every addon would need its own guard).

## 6. Interfaces and data flow

- `WorkflowValidation.validate(_:nodePayloads:)` — two new diagnostic rules
  (D1, D2a). Signature unchanged; the function already receives every input
  it needs (steps, transitions, node payloads with `executionBackend`,
  `agentSandbox`, `output`, addon `config`/`inputs`).
- `AgentGatewayNodeAdapter.normalizeGatewayOutput` — no-contract branch
  reduced to the text wrap (D2b). Contract branch unchanged.
- `DeterministicWorkflowRunner+Prompting.maxValidationAttempts(from:)` —
  default 2 when `output.jsonSchema != nil` (D2b).
- `RielaAddonSupport` — strict rendering entry points for addon config and
  inputs returning either rendered JSON or the typed resolution failure;
  `addonVariables` additionally surfaces the producer step id for the error
  (D3). All addon families route through this one seam, so every builtin
  addon (git, kv, kaiba, gateway addons) gains the contract at once.
- Error surfacing: the new failure appears in session status/progress/logs as
  the consuming step's failure with category `templateResolutionFailed`,
  reusing the existing `AdapterExecutionError`-style publication path so
  export/GraphQL views need no schema change beyond the new reason text.

Data flow after the change, for the observed scenario: `plan-checkpoint`
(now with `agentSandbox: workspaceWrite` and a schema requiring
`commitMessage` on acceptance) either publishes a valid payload, retries
once, or fails **at plan-checkpoint** with the schema reason. If a field
still goes missing, `step9-commit` fails with `templateResolutionFailed`
naming `plan-checkpoint` — never with `commit message is empty or invalid`.

## 7. Edge cases

- Node with schema whose `when` labels are consumed but payload is not:
  covered by D2a rule 2.
- Fan-in steps (multiple producers): `inbox.latest` is the most recent;
  the D2a check applies to **every** one-transition predecessor whose edge
  can be the latest — all predecessors need the schema-declared field.
- `{{input.<field>}}` templates resolve against the merged resolved input;
  the same missing-path strictness applies in addon config/inputs.
- An answer with two fences: json-tagged fence wins (existing extractor
  order); two json-tagged fences: first wins — documented, not an error.
- `output` block with `description` but no `jsonSchema` (today's
  `step9-commit-message`): D2a treats it as schema-less; the description
  alone enforces nothing.
- Empty string vs missing: a producer that publishes `commitMessage: ""`
  passes template resolution; the schema must say `minLength: 1` (the
  supported dialect includes it) — the bundle follow-up (D4) does so.

## 8. Security

D1 makes permission grants explicit and reviewable in the bundle; no node can
gain `bypassPermissions` implicitly, and validation rejects sandbox
declarations on backends that would silently drop them. D3 fails before addon
side effects, so a half-resolved config can never reach `git commit`.

## 9. Tests

Runtime (all in existing suites, same targets as the seams):

- `WorkflowValidation` tests: D1 error on omitted sandbox per backend; D1
  error on declared sandbox for API backends; D2a error for templated payload
  without schema, for referenced-field-not-in-properties, for conditional
  labels without schema; green fixtures for compliant workflows.
- Adapter tests: no-contract prose answer → `{text}` unchanged; no-contract
  `{`-prefixed malformed answer → `{text}` (sniffing removed, no silent
  envelope); contract + fenced answer → extracted and validated.
- Runner tests: schema without declared attempts retries exactly once;
  declared attempts still win; final rejection surfaces node id + reason.
- Addon-support tests: missing path in config → typed error naming
  producer/path/consumer; addon body not executed; prompt rendering still
  lenient; `{{input.…}}` strictness.
- Mock-scenario regression: `rielaExampleWorkflowNames()` examples and
  packaged fixtures must validate under the new rules (they will need the
  same D4-style edits in-repo where they violate them — that is part of the
  runtime work package, since examples live in this tree).

Bundle (D4 follow-up, riela-packages): mock-scenario run of
`fable-and-improve-opus` green under new validation; EXPECTED_RESULTS updated.

## 10. Rollout

Single runtime release. No flags, no phases. The release notes must state:
workflows failing the two new validation rules stop running until edited —
the errors name the node, field, and rule. The D4 bundle release ships with
or before the runtime release so the flagship package validates on day one.

## 11. Rejected-alternative index

- D1: default `workspaceWrite` (implicit permission grant), default
  `readOnly` (perpetuates the trap), warning (run proceeds to die far from
  cause).
- D2: strict rejection of fenced answers (extractor already exists, fences
  are unambiguous), warning/allowed for missing schema (observed failure
  survives), runtime-only enforcement (later and worse than validate-time),
  keeping opportunistic envelope sniffing (silent `try?` degradation is the
  replaced contract).
- D3: strict prompts (breaks optional prose context), schemas-alone
  (non-required fields still render `""`), per-consumer emptiness guards
  (today's wrong-actor error).
