# Agent-node output contract: sandbox declaration, payload validation, and template resolution failures

Status: accepted design, 2026-09-21; revised the same day after independent
review, twice (D2a extended to bare payload references; D3 rescoped from
surface to path class; the classifier's exclusions made per surface after the
node-`variables` escape proved unreachable on the addon path; then `config`
and `inputs` split into separate classifier surfaces and the inert
node-`variables` scan dropped; then, after a third review, the output contract
restated as the runtime's three states rather than two, D2a's one-transition
scan replaced by a producer walk through forwarding addon nodes, and §6's
single-seam claim retracted in favour of an enumerated 16-site conversion —
see the plan's progress log). Not implemented.
Plan:
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

2. **Contract-less answers become `{text: …}` with no validation and no
   retry.** The switch is `requiresOutputContract`, and it keys on the
   **`output` block, not on `output.jsonSchema`**:
   `Sources/RielaAdapters/AgentGatewayNodeAdapter.swift:125` passes
   `requiresOutputContract: input.node.output != nil`, and
   `workflowOutputContract(from:)`
   (`Sources/RielaCore/DeterministicWorkflowRunner+Prompting.swift:10-15`)
   returns a non-nil `WorkflowOutputContract(schema: output.jsonSchema,
   requiredObject: true)` whenever `output` is non-nil — with a `nil` schema
   inside it when none was declared. So the runtime has **three** states, not
   two (see §4):
   (1) `output == nil` → text wrap, no enforcement;
   (2) `output != nil, jsonSchema == nil` → strict envelope **is** enforced
   (`normalizeGatewayOutput:725` takes the `parseJSONObjectCandidate` +
   `normalizeOutputContractEnvelope` branch and throws `.invalidOutput` on
   prose), business payload unconstrained;
   (3) both → strict envelope **and** schema validation.
   State 1 is the one that produced the observed failure:
   `Sources/RielaAdapters/AgentGatewayNodeAdapter.swift:719`
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
   `.validationRejected` — which can never fire without a schema, and which
   also never fires for a **state-2 or state-3 envelope failure**, because
   that failure is thrown as `AdapterExecutionError(.invalidOutput, …)` from
   `normalizeGatewayOutput` rather than as a publication rejection. In the
   bundle, only 4 of 16 agent nodes declare `output.jsonSchema` (the same 4
   declare `maxValidationAttempts`); `nodes/node-step9-commit-message.json`
   has an `output.description` asking for `commitMessage` but no schema, so
   it sits in state 2: the envelope **is** enforced and only the
   `commitMessage` field shape is not. That node is still the observed
   defect's carrier, because an envelope with no `commitMessage` key passes
   state 2 untouched.

3. **A missing template path silently renders `""` and surfaces as the
   consumer's domain error.** `Sources/RielaCore/PromptTemplate.swift:20`:
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

**Self-correction (recorded per the same mandate; raised as review F10).** An
earlier revision of this document asserted, in defect 2 above and in §7, that
a node with `output.description` and no `jsonSchema` has *nothing* enforcing
its answer — "so nothing enforces it" and "the description alone enforces
nothing". Source contradicts both: `requiresOutputContract` is
`input.node.output != nil` (`AgentGatewayNodeAdapter.swift:125`), so such a
node is on the strict path and a prose answer throws. Both claims are
retracted and replaced by the three-state statement above; §4 and §7 are
rewritten around it. The mistake mattered — it would have licensed an
implementer to re-key the switch to `jsonSchema != nil` and thereby *loosen*
every description-only node into the text wrap.

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
| D2a | `workflow validate` **error** when a node's payload is referenced by a downstream template — dotted (`inbox.latest.output.payload.*`, `input.*`) **or bare** (`{{field}}`, the dominant in-repo idiom) — or its step has conditional transition labels, and the node declares no `output.jsonSchema` | riela runtime |
| D2b | With an `output` block (the runtime's real switch, `AgentGatewayNodeAdapter.swift:125`): keep tolerant extraction + strict envelope, schema validation when a `jsonSchema` is declared, and a default of **2** validation attempts — with the extraction/envelope failure raised as a retryable rejection so the budget is reachable. Without an `output` block (now provably inconsequential): pure `{text: …}` wrap; the opportunistic `try?` envelope sniffing at `AgentGatewayNodeAdapter.swift:728-731` is deleted | riela runtime |
| D3 | Addon `config`/`inputs` rendering of a **payload reference** that resolves to nothing fails with a typed template-resolution error naming producing step, field path, and consuming step; the addon never executes. Context namespaces (`event.*`, `workflowInput.*`, `runtime.*`, `_rielaInput.*`, and those same roots spelled under `input.`) stay lenient, as does all prompt-template rendering | riela runtime |
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
- **The description-only state (state 2), stated because the runtime has it.**
  A node with an `output` block and no `jsonSchema` is on the same strict path
  as state 3: the answer must still be one extractable JSON object that
  normalizes as an envelope, and prose still fails. The only difference is
  that no schema constrains the business payload, so *any* envelope passes.
  This state is **preserved verbatim** — see the rejected alternative below —
  and it is a real contract, not an absence of one. What it does **not** give
  you is a guarantee about fields, which is why D2a's predicate is
  `jsonSchema` and not `output`.
- **How many attempts a node gets.** `max(1, declared maxValidationAttempts)`
  when declared. Undeclared with **any** `output` block — states 2 and 3
  alike: **2** (one retry). The predicate is `output != nil`, matching the
  envelope switch at `AgentGatewayNodeAdapter.swift:125`, not
  `jsonSchema != nil`: a state-2 node can fail the envelope exactly as a
  state-3 node can, so budgeting them differently would leave the strict path
  half-retried. `output == nil`: 1, unchanged and irrelevant (no rejection can
  occur). This changes `maxValidationAttempts(from:)` at
  `DeterministicWorkflowRunner+Prompting.swift:17`.
- **Making that retry reachable (a second, required change).** Today the
  budget alone would not help either strict state, because the attempt loop
  retries only `WorkflowPublicationError.validationRejected`
  (`DeterministicWorkflowRunner.swift:976` — `guard case .validationRejected =
  error, attempt < maxAttempts`), while an extraction or envelope failure
  leaves the adapter as `AdapterExecutionError(.invalidOutput, …)` from
  `normalizeGatewayOutput` (`AgentGatewayNodeAdapter.swift:725`) and is never
  retried. So on the contract path (`output != nil`) the extraction/envelope
  failure is raised as a validation rejection carrying the same reason text,
  and the existing loop handles it. The `.invalidOutput` classification is
  kept for every other adapter failure and for every other adapter. Behavior
  change stated, migration-free: a contract-bearing node that today dies on
  its first malformed answer now gets a second attempt with
  `AdapterOutputAttemptContext`; runs are slower on the failure path and
  succeed more often. No flag, no way to restore the single-attempt behavior
  other than declaring `maxValidationAttempts: 1`.
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
   N by the **producer walk defined below**, and S's addon `config` or
   `inputs` contain a template that is a **payload reference** (defined
   below). Those two are the whole scanned set.

   **The producer walk (one transition is not enough).** Addon nodes
   *republish their whole upstream payload*: `addonForwardedApplicationPayload`
   (`Sources/RielaAddonSupport/WorkflowAddonSupport.swift:12-16`) removes only
   `_rielaInput`, `upstream` and `runtime`, and the result becomes the
   published payload at `Sources/RielaCLI/ProductionNodeAdapter.swift:790`,
   `ProductionNodeAdapter+WorkflowTaskAddon.swift:177` and
   `ProductionNodeAdapter+PersonaMemory.swift:126`. A field therefore survives
   an arbitrary number of addon hops, so a rule that looked back exactly one
   transition would leave the real producer schema-less whenever an addon step
   sits between it and the consumer — and would then let D3 fail at run time
   blaming the relay. The walk is instead: from consuming step S, follow
   incoming transitions backwards; a step whose node is an **agent node**
   (i.e. the node has a payload in `nodePayloads`) terminates that path and is
   a **required producer**; a step whose node is an **addon node** is a relay
   and the walk continues through it; a visited set bounds the walk, which
   matters because workflows may loop (`WorkflowLoopMetadata`,
   `WorkflowModel.swift:593`). Every required producer found on every path must
   carry the schema and the referenced field.

   **An addon-node predecessor is never itself the target of this rule.** It
   structurally cannot satisfy it: `output` lives on `AgentNodePayload`
   (`WorkflowModel.swift:765`, `:777`) while `addon` lives on
   `WorkflowNodeRegistryRef` (`:336`) and `WorkflowNodeRef` (`:536`), and
   `WorkflowValidation.validate(_:nodePayloads:)` (`:102-113`) iterates
   `nodePayloads` only, so an addon node has nowhere to put a `jsonSchema`.
   Erroring on one would emit a diagnostic no author could clear. Rejected
   alternatives: **stop at one transition** (the rule would guarantee nothing
   across the relay pattern the repository actually uses, and would hand D3 the
   wrong node to name); **error on the addon-node predecessor** (unsatisfiable
   diagnostic); **require addon nodes to gain an `output` declaration**
   (a model change, a feature, and far wider than a contract fix).

   **A path with no agent node at all** — S is reachable only from the entry
   step or from an event-fed step — requires no schema from anyone, because
   there is no producer that could publish one. D3 remains the backstop there:
   the reference still renders strictly at run time and fails naming the step
   that delivered the input. Stated so the guarantee is not overclaimed: D2a
   moves *most* of this class of failure to validate time, not all of it.

   A node's declared `variables` are deliberately **not** scanned: their
   values are never template-rendered. `promptVariables` seeds them as
   substitution *values* (`DeterministicWorkflowRunner+Prompting.swift:52`),
   the adapters read them as configuration knobs
   (`AgentGatewayNodeAdapter.swift:93`, `:575`, `:593`,
   `AdapterUtilities.swift:34`), and `renderPromptTemplate`
   (`PromptTemplate.swift:3-24`) makes one non-recursive pass over the prompt
   *text* only — so `{{commitMessage}}` written inside a variable value is
   emitted literally. Erroring on such a string would demand a producer schema
   for a reference that adding the schema cannot make resolve.

   The validator additionally checks that each referenced first-segment
   `<field>` appears in N's `schema.properties`; a referenced field absent
   from the schema is its own error (the schema would validate the wrong
   shape). All template strings are already present in
   `workflow.json`/node payloads at validate time — no new inputs needed.

   **Payload reference, defined.** Three forms, not one:
   `inbox.latest.output.payload.<field>`, `input.<field>`, and a **bare**
   first segment `{{<field>}}` / `{{<field>.<rest>}}`. The bare form is not a
   nicety — `addonVariables` merges the entire resolved input payload into
   the flat variable namespace (`WorkflowAddonSupport.swift:20-22`) before
   adding `inbox` (`:23-33`) and `input` (`:34`), so `{{queryPlan}}` reaches
   exactly the value `{{inbox.latest.output.payload.queryPlan}}` reaches.
   It is also the dominant in-repo idiom:
   `examples/note-rag-retrieval-fusion/workflow.json:117-120` passes
   `{{queryPlan}}`, `{{notebookId}}`, `{{noteIds}}`, `{{pageCount}}` through
   `kaiba/note-search` config, and `:136-145` passes `{{seededNotebookId}}`,
   `{{seededNoteIds}}`, `{{seededPageCount}}`, `{{resultCount}}`,
   `{{results}}`. A rule that scanned only the two dotted forms would leave
   these producers schema-less and would not deliver the guarantee this
   section claims.

   **Classifier, and why its exclusions are per surface.** A bare first
   segment is *not* a payload reference when it is a runtime-provided root.
   Those roots reach the namespace by three different routes, and the
   citation must say which:
   `inbox` (`WorkflowAddonSupport.swift:23-33`), `input` (`:34`),
   `workflowId`/`stepId`/`nodeId`/`addonName` (`:35-38`) are set by
   `addonVariables` itself; `event` and `workflowInput` arrive inside
   `request.variables` (`WorkflowInputFilterEvaluation.swift:191-194`);
   `_rielaInput`, `upstream` and `runtime` arrive inside
   `resolvedInputPayload` and are merged flat at `:20-22` — which is exactly
   why `addonForwardedApplicationPayload` strips those three at `:12-16`.
   Every other bare first segment **is** presumed a payload reference.

   The exclusion set is **computed per surface, and the two addon surfaces are
   not the same surface** — because `addonVariables` builds the namespace in
   an order that makes them differ:

   - **`config`**: reserved roots **+ that addon's own `inputs` keys.** By the
     time an addon renders its `config`, `addonVariables` has already rendered
     the addon's `inputs` and merged them into the namespace
     (`WorkflowAddonSupport.swift:39-41`), so `{{results}}` there resolves to
     the rendered input named `results`, not to the payload — and, if both
     exist, the rendered input **shadows** the payload field of that name.
   - **`inputs`**: reserved roots **only, never the `inputs` keys.**
     `renderAddonInputs` (`:45-48`) renders every `inputs` value against the
     *pre-`inputs`* namespace that `addonVariables` passes it at `:39`, so an
     `inputs` key is not yet in scope while `inputs` render. Inside `inputs`,
     `{{results}}` is a payload reference (the payload was merged flat at
     `:20-22`) — or, if no such payload field exists, an unresolvable path.
     Excluding `inputs` keys here would be exactly the F6 mistake again:
     granting an exclusion on a surface where the mechanism behind it is not
     present, which would let a real payload reference render `""` and put an
     empty machine-consumed field into the addon.

   A node's declared `variables` are excluded on **neither** surface, and are
   not scanned at all (rule 1 above): they never reach `addonVariables`, whose
   inputs are `input.variables` + `resolvedInputPayload` + `inbox`/`input`/ids
   + `addon.inputs`, and the addon dispatch branch has no node payload to take
   them from (`DeterministicWorkflowRunner.swift:511-532` passes none;
   `WorkflowAddonExecutionInput`, `WorkflowAddonExecution.swift:341-349`, has
   no such field).

   Consequence, stated because it removes an escape a reader would expect:
   on the addon surface, declaring `variables: {"teamName": …}` on the
   consuming node does **not** make `{{teamName}}` legal. It is a payload
   reference at validate time and at render time alike, so D2a errors and D3
   would too — the two never disagree. The only escape on that surface is
   `{{workflowInput.<name>}}`, which does resolve because `workflowInput` is
   an ordinary key inside `request.variables`.

   **This is not fully decidable, and the rule errs toward the error.**
   `WorkflowDefinition` (`WorkflowModel.swift:582-593`) declares no names for
   run-supplied variables, and `request.variables`
   (`DeterministicWorkflowRunner+Addons.swift:58`) is whatever the operator
   passed to `--variables`. A bare identifier fed by a run variable is
   therefore indistinguishable at validate time from one fed by an upstream
   payload, and the classifier will attribute it to the producer. The rule
   errs that way deliberately: a false positive costs one permissive schema
   on the producer, or one reference rewritten as `{{workflowInput.<name>}}` —
   both visible at validate time with the node named. (Declaring the key in
   the node's `variables` is *not* a third option on this surface; see the
   per-surface rule below.) A false negative reproduces the original defect at
   run time, steps from its cause. Stated migration-free consequence:
   workflows that today reach run-level variables through bare identifiers in
   addon config must namespace them as `{{workflowInput.<name>}}`; there is no
   flag to opt out.
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
`step9-commit-message` and `plan-checkpoint`). In-repo examples pay the same
cost — `note-rag-retrieval-fusion` is the worked case — and T5 of the plan
reconciles them. Rejected alternatives:
**scanning only the dotted forms** (`inbox.latest.output.payload.*` /
`input.*`), which reads tidy but misses the idiom this repository actually
uses and would ship a rule that quietly guarantees nothing;
**warning** (run proceeds into the exact observed failure), **allowed**
(status quo), **runtime-only enforcement** (fails mid-run instead of before
the run; validate-time is strictly earlier and names the node while the
operator is still at the terminal).

### D2b — the contract-less path becomes honest, and the three predicates stay apart

**The switch does not move.** `requiresOutputContract` stays
`input.node.output != nil` (`AgentGatewayNodeAdapter.swift:125`). Three
predicates, deliberately different, each stated so no implementer collapses
them:

| Concern | Predicate | Seam |
| ------- | --------- | ---- |
| Strict envelope required | `output != nil` | `AgentGatewayNodeAdapter.swift:125` (unchanged) |
| Business payload validated | `output.jsonSchema != nil` | `RuntimeOutputValidation.swift:41-45` (unchanged) |
| Retry budget defaults to 2 | `output != nil` | `…+Prompting.swift:17` (changed) |
| D2a demands a producer contract | `output.jsonSchema != nil` | new rule (§4 D2a) |

Re-keying the first row to `jsonSchema != nil` is **forbidden**: it would move
every description-only node (state 2) off the strict path and into the text
wrap — a loosening, in a design whose entire purpose is to tighten, and one
that would silently convert a today-failing prose answer into an accepted
`{text: …}` payload.

**What changes in the `output == nil` branch.** After D2a, a node with no
`output` block is provably one whose payload nobody reads and whose routing is
unconditional. Its answer is wrapped as `{text: <full answer>}` with
`completionPassed: true` — unchanged. The opportunistic envelope sniffing for
`{`-prefixed answers (`AgentGatewayNodeAdapter.swift:728-731`, including its
`try?` silent fallback) is **deleted**: with D2a in force, any node that needs
the envelope declares a contract, and a half-tolerant path whose parse
failures silently degrade to a text wrap is exactly the contract this design
replaces. Consequence: a contract-less node that today emits a JSON envelope
to drive `when` routing loses that ability — validation now directs its author
to declare a schema.

**Rejected: deleting state 2 by making an `output` block without `jsonSchema`
a validation error.** This is the tidier reading of the no-back-compat mandate
— after it, `output != nil` and `jsonSchema != nil` would coincide and the
predicate table above would collapse to one row. It is rejected on measured
cost and on direction. Cost: 88 of the 125 agent-node `output` blocks in
`examples/` declare a description and no schema, as do 6 of the 10 in
`fable-and-improve-opus` (`node-fable-design`, `node-fable-goal-review`,
`node-final-output`, `node-opus-implementation`, `node-opus-review`,
`node-step9-commit-message`) — an 88-file sweep in this tree alone. Direction:
the mandate forbids keeping a contract this design *replaces*; state 2 is not
replaced by anything here, it is a coherent stricter-than-nothing declaration
("give me the envelope; I do not constrain the payload"), and an author who
answered the error by deleting the `output` block instead of adding a schema
would end up *looser* than before. D2a already reaches every state-2 node that
matters — any one whose payload is referenced or whose step drives labels —
and errors there on the `jsonSchema` predicate.

## 5. D3 — template resolution failure contract

### Decision

Rendering addon `config` and `inputs` (the machine-consumed surfaces —
`renderJSONTemplates` / `renderAddonInputs` in
`Sources/RielaAddonSupport/WorkflowAddonSupport.swift`) becomes **strict for
payload references only**: a template whose path is a payload reference and
resolves to nothing raises a typed error instead of rendering `""`. The
boundary is the **path class**, not the surface.

**Strict classes** (an unresolved path is an error): the three payload-
reference forms D2a defines — `inbox.latest.output.payload.*`, `input.<field>`,
and a bare first segment that D2a's classifier attributes to the upstream
payload. These are exactly the paths a producing node is contractually
obliged to publish, so an absent one is always a broken contract. The two
rendering entry points classify with **different surfaces**: `config` renders
under `.addonConfig(addonInputKeys:)` and `inputs` under `.addonInputs`
(§4, §6), so a bare name matching one of the addon's own `inputs` keys is
context in `config` and a payload reference in `inputs`.

**Lenient classes** (an unresolved path still renders `""`, as today):
`event.*`, `workflowInput.*`, `runtime.*`, `upstream.*`, `_rielaInput.*` — and
the same three runtime roots spelled under the `input.` prefix, namely
`input._rielaInput.*`, `input.upstream.*` and `input.runtime.*`. That last
exclusion is not a nicety: `variables["input"]` is the whole
`resolvedInputPayload` (`WorkflowAddonSupport.swift:34`), which carries those
three runtime views — which is precisely why
`addonForwardedApplicationPayload` strips them at `:12-16`. Without the
exclusion, `{{input._rielaInput.latest.fromStepId}}` would be strict while the
bare `{{_rielaInput.latest.fromStepId}}` stayed lenient, and two spellings of
one path would disagree. These carry *context*, whose absence is legitimate
and per-invocation.

**Not a lenient class: the consuming node's declared `variables`.** They do
not exist on this surface (section 4), so on the addon surface such a key is a
payload reference at validate time and at render time alike — D2a errors
before the run rather than D3 erroring during it, and the two never disagree.

**Worked case that fixes the boundary.**
`examples/telegram-sdk-trio-chat/workflow.json:31-48` is a
`riela/memory-save` addon whose `config.payloadTemplate` reads
`{{event.conversation.threadId}}` (`:41`), `{{event.input.historySource}}`
(`:42`), `{{event.input.attachments}}` (`:43`), `{{event.input.imagePaths}}`
(`:44`) and `{{event.input.attachmentText}}` (`:45`). A plain-text message in
a non-forum chat with no attachments supplies none of them. Today
`exactTemplateValue` (`WorkflowAddonSupport.swift:64-75`) returns nil,
`renderJSONTemplates` (`:53-54`) falls through to `renderPromptTemplate`, and
the record is stored with empty strings. Under a surface-wide strict rule the
common case would become a hard failure and this shipped example would break.
Under the path-class rule it keeps rendering `""`, because `event.*` is a
context namespace and never a producer's obligation. Machine-consumed config
is therefore *not* uniformly obligatory — the earlier framing of this section
asserted it was, and the repository contradicts that.

The error is a new category (template-resolution failure, distinct from the
addon's own `policyError` domain) and must carry:

- the **delivering step**: `_rielaInput.latest.fromStepId`, written by
  `resolvedInputMessageMetadata`
  (`Sources/RielaCore/RuntimeMessageInputResolver.swift:107`) into the
  `_rielaInput` metadata that `addonVariables` already receives (`latest` is
  attached at `:102`, and also carries `sourceStepExecutionId`). The key is
  **conditional** — `if let fromStepId = message.fromStepId` at `:118` — so a
  message with no originating step (a seed or externally injected input) has
  no `fromStepId`. The renderer therefore resolves the producer in order:
  `_rielaInput.latest.fromStepId`, else the sole entry of
  `_rielaInput.sourceStepIds` (`:98`) when there is exactly one, else the
  literal `an upstream step`. The error must never fail to render because its
  producer is unknown; an unknown producer still names path and consumer,
- the **field path** as written in the template
  (`inbox.latest.output.payload.commitMessage`),
- the **consuming step / node / addon** (`stepId`, `nodeId`, `addonName` are
  already in the variables object at `WorkflowAddonSupport.swift:36-38`).

Shape: `templateResolutionFailed: step '<consumer>' addon '<addon>' template
'{{<path>}}' resolved to nothing; step '<deliverer>' delivered this input
without payload field '<field>'`.

**Delivering, not necessarily authoring — a stated limit.** The renderer
cannot walk the graph the way D2a does: `WorkflowAddonExecutionInput`
(`WorkflowAddonExecution.swift:341-349`) carries `workflowId`, `stepId`,
`nodeId`, `addon`, `variables`, `resolvedInputPayload`, `attachments` and
`executionIdentity` — and no workflow definition. So when the delivering
step is a **forwarding addon relay** (§4's producer walk), D3 names the
relay, which is not the node that owed the field. The design does not
pretend otherwise and does not widen that wire type to fix it (§11 rejects
the same widening for node `variables`). Two mitigations, both stated:
D2a's producer walk is what guarantees the node that *does* owe the field
was made to declare it, so this case should mean a schema that lied rather
than a missing contract; and the message says which relationship it is
asserting — `'<deliverer>' delivered this input without payload field
'<field>'` — so an operator reading it is not told that a `kv-set` step
failed to produce a `commitMessage` it was never asked for. Naming the
authoring node at render time is possible only by threading the producer
chain into the addon wire type, which is a feature, not a contract fix.

**The addon body must not execute — which is work, not a property of the
seam.** The intent is that the failure is raised during variable/config
rendering, before any side effect. Most addons already render their config up
front, but this is not universal today and the design must not claim it is:
`ProductionNodeAdapter+AppleGatewayNotifications.swift:279` renders the
dismiss document *inside* `dismissOutput(input:envelope:)`, which is reached
from `:87` only after `:72` has built the envelope from the gateway process
output — that is, after the gateway mutation has already run. Converting that
call site to a strict render without moving it would turn a resolution failure
into a failure *after* the side effect, which is worse than today. T4
therefore owns hoisting late renders ahead of their side effects at the sites
where they occur, and the guarantee is stated as: after T4, every strict
render happens before its addon's first side effect, with
`+AppleGatewayNotifications.swift:279` named as the known case to hoist.

The step
fails with this error; it is not the consumer's domain error, and with D2a in
force it indicates a schema that lied (the field was in `properties` but the
producer omitted it and the schema didn't `require` it) — the message says
where to look.

Prompt-template rendering (`renderPromptTemplate` used for agent prompts)
stays lenient for **every** class, payload references included: prose prompts
legitimately reference optional context, an error there would make every
optional variable mandatory, and the in-repo assertions that a missing path
renders `""` in a prompt (`Tests/RielaCoreTests/PromptTemplateTests.swift:8`,
`DeterministicWorkflowRunnerTests.swift:365`) stay green unchanged.

So there are two axes, and both matter: **surface** (addon config/inputs
strict-capable, prompts always lenient) and **path class** (payload
references obligatory, context namespaces optional). A path is an error only
where the two coincide.

Rejected alternatives: **making declared node `variables` a lenient class by
threading them into `WorkflowAddonExecutionInput`** (widens a public `Codable`
wire type serialized for placed/distributed execution, and hands addon nodes a
capability they never had — a feature, not a contract fix; see section 11);
**strict over all config paths** (the first draft of
this decision — it generalizes from a missing *upstream payload* field, which
is what actually broke the observed run, to absent *event context*, which is
routine; it would turn the common plain-text Telegram message into a
`memory-save` failure at `telegram-sdk-trio-chat/workflow.json:41-45`, and
would have shipped that regression past a validate-only example check);
**strict everywhere** (breaks every prompt that
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
  default 2 when `output != nil` (D2b; **not** `jsonSchema != nil` — the
  budget must cover the description-only state, which is on the same strict
  path).
- `AgentGatewayNodeAdapter.normalizeGatewayOutput` / the runner's attempt loop
  — on the contract path, extraction and envelope failures are raised as
  `WorkflowPublicationError.validationRejected` rather than
  `AdapterExecutionError(.invalidOutput, …)`, so the loop's existing guard
  (`DeterministicWorkflowRunner.swift:976`) retries them (D2b). Every other
  adapter and every other failure keeps `.invalidOutput`.
- **Shared template classifier** — one function in RielaCore, used by both D2a
  and D3, returning per `{{path}}` whether it is a payload reference or a
  context reference (the rule in section 4). Its signature must be expressible
  at both call sites, which do **not** see the same things, so the surface is
  passed explicitly rather than inferred from a node payload the render side
  does not have:

  ```
  enum TemplateSurface {
    case addonConfig(addonInputKeys: Set<String>)   // inputs already merged
    case addonInputs                               // inputs not yet in scope
  }
  func classifyTemplateReference(_ path: String, surface: TemplateSurface)
    -> TemplateReferenceClass   // .payload | .context
  ```

  Two cases, not one, because `addonVariables` merges the addon's rendered
  `inputs` at `WorkflowAddonSupport.swift:39-41` — that is, *after*
  `renderAddonInputs` (`:45-48`) has already rendered every `inputs` value
  against the pre-`inputs` namespace — so an `inputs` key is visible while
  `config` renders and invisible while `inputs` render (§4).

  Call-site inputs: **validate time** reads `WorkflowNodeAddonRef.inputs` off
  the node payload; **render time** reads the same `addon.inputs` off
  `WorkflowAddonExecutionInput` (`WorkflowAddonExecution.swift:341-349`). Both
  sides can construct both cases from the same data, which is the mechanism
  behind the invariant rather than an exhortation. State the invariant **per
  surface**: for a given surface, a path D2a forced a schema for is exactly a
  path D3 refuses to render empty. It does not hold *across* the split, and
  must not be claimed to — `{{results}}` may legitimately be context in
  `config` and a payload reference in `inputs` on the very same node, which is
  why both sides must pass the surface they are actually rendering.

  There is no prompt case. Node `variables` are not a scanned surface (§4
  rule 1) and prompt rendering is never strict, so the classifier has no
  agent-side call site at all.
- `RielaAddonSupport` — strict rendering entry points for addon config and
  inputs returning either rendered JSON or the typed resolution failure, strict
  only for classifier-payload paths, with `config` classified under
  `.addonConfig(addonInputKeys:)` and `inputs` under `.addonInputs`;
  `addonVariables` additionally surfaces the producer step id for the
  error (D3).

  **Corrected (review F12): addon families do *not* route through one seam
  today.** `renderJSONTemplates` is a free function called from **16 sites in
  12 files across two targets beyond `RielaAddonSupport`** — `RielaCLI`
  (`ContainerWorkflowAddonResolver.swift:128`,
  `ProductionNodeAdapter+AppleGatewayAdminAddons.swift:320`,
  `+LocalGatewaySupport.swift:178`/`:260`/`:313`, `+GitAddons.swift:67`/`:82`,
  `+GitPush.swift:118`, `+AppleReminderAddons.swift:100`,
  `+GoogleDocumentsGatewayAddons.swift:295`, `+MemoryAddonCore.swift:26`,
  `+KeyValueStoreAddon.swift:15`) and `RielaKaibaAddons`
  (`KaibaRemoteGraphQLAddon.swift:58`, `KaibaNoteAddons.swift:366`,
  `KaibaInputValidation.swift:9`/`:14`). Each renders its own config ad hoc.
  Adding a strict function *beside* the lenient one would therefore convert
  only the sites someone remembered, and D2a would error at validate time on
  references D3 does not enforce at render time — the two disagreeing on
  exactly the surfaces §4 works to keep in agreement. So the strict,
  surface-aware, throwing function becomes the **only public render entry
  point** and the lenient `renderJSONTemplates` is privatized to
  `RielaAddonSupport`, making every unconverted site a compile error rather
  than a review omission. T4 of the plan carries the full site list.
- Error surfacing: the new failure appears in session status/progress/logs as
  the consuming step's failure with category `templateResolutionFailed`,
  reusing the existing `AdapterExecutionError`-style publication path so
  export/GraphQL views need no schema change beyond the new reason text.

Data flow after the change, for the observed scenario: `plan-checkpoint`
(now with `agentSandbox: workspaceWrite` and a schema requiring
`commitMessage` on acceptance) either publishes a valid payload, retries
once, or fails **at plan-checkpoint** with the schema reason. If a field
still goes missing, `plan-git-commit` fails with `templateResolutionFailed`
naming `plan-checkpoint` — never with `commit message is empty or invalid`.

## 7. Edge cases

- Node with schema whose `when` labels are consumed but payload is not:
  covered by D2a rule 2.
- Fan-in steps (multiple producers): `inbox.latest` is the most recent;
  the D2a check applies to **every** required producer the walk reaches on
  every path — all of them need the schema-declared field.
- Producer separated from consumer by a forwarding addon step (agent →
  `riela/kv-set` → `riela/git-commit` reading `{{commitMessage}}`): the walk
  passes through the addon step and requires the schema on the agent node
  (§4 rule 1). Without the walk, D2a would raise nothing and D3 would fail at
  run time naming `kv-set` — an addon node that was never asked for
  `commitMessage` and structurally cannot be given a schema. If the field is
  nevertheless absent at run time, D3 names `kv-set` as the *deliverer*, with
  the wording chosen so it does not read as an accusation (§5).
- A cycle in the producer walk (loop workflows, `WorkflowLoopMetadata`):
  the visited set terminates it; every distinct agent node reached is a
  required producer.
- `{{input.<field>}}` templates resolve against the merged resolved input and
  are a payload reference, so addon config/inputs render them strictly — except
  `input._rielaInput.*`, `input.upstream.*` and `input.runtime.*`, which are the
  runtime's own views reached through the `input` alias
  (`WorkflowAddonSupport.swift:34`, strip list at `:12-16`) and stay lenient so
  that the dotted and bare spellings of one path agree.
- Bare identifier fed by a run-level `--variables` key: the classifier cannot
  tell it from a payload reference (section 4), so D2a errors and D3 renders
  strictly. The author namespaces it as `{{workflowInput.<name>}}`. Accepted
  false-positive direction.
- Declaring the key in the consuming node's `variables` is **not** an escape on
  the addon surface: those variables never reach `addonVariables`, so the key
  would still be unresolved at render time. The classifier therefore refuses to
  exclude it there (section 4), which keeps the failure at validate time where
  it names the node, instead of letting it become a run-time
  `templateResolutionFailed` that would blame an upstream producer for a field
  it was never asked to publish. Nor are node `variables` scanned as a source
  of payload references — their values are inert text (section 4, rule 1).
- An `inputs` entry referencing **another `inputs` key of the same addon**
  (`inputs: {"a": "…", "b": "{{a}}"}`) can never resolve: `renderAddonInputs`
  renders every entry against the pre-`inputs` namespace
  (`WorkflowAddonSupport.swift:39`, `:45-48`), so `a` is not in scope. Under
  `.addonInputs` the classifier calls it a payload reference and D2a raises a
  validation error naming the node — the right outcome, since the alternative
  is a permanently empty field. Authors chain through `config` or through the
  producing node instead.
- A payload field whose name **collides** with one of the addon's `inputs`
  keys is protected on the `inputs` surface (payload reference, strict) and
  shadowed on the `config` surface (the rendered input wins, because `inputs`
  are merged last at `:39-41`). Same spelling, two meanings, decided by which
  surface is rendering — documented, not an error.
- Context path inside an otherwise payload-driven config object: classification
  is per `{{path}}`, not per config file, so one object may hold both a strict
  `{{commitMessage}}` and a lenient `{{event.input.attachmentText}}`.
- An answer with two fences: json-tagged fence wins (existing extractor
  order); two json-tagged fences: first wins — documented, not an error.
- `output` block with `description` but no `jsonSchema` (today's
  `step9-commit-message`) — **corrected, was stated wrongly**: this is state 2
  (§1, §4 D2b). The description enforces nothing *about fields*, but the
  `output` block itself puts the node on the strict envelope path
  (`AgentGatewayNodeAdapter.swift:125`), so a prose answer already fails
  today. D2a still errors on it whenever its payload is referenced or its step
  drives labels, because D2a's predicate is `jsonSchema`; and its attempt
  budget becomes 2, because D2b's budget predicate is `output`.
- Empty string vs missing: a producer that publishes `commitMessage: ""`
  passes template resolution; the schema must say `minLength: 1` (the
  supported dialect includes it) — the bundle follow-up (D4) does so.

## 8. Security

D1 makes permission grants explicit and reviewable in the bundle; no node can
gain `bypassPermissions` implicitly, and validation rejects sandbox
declarations on backends that would silently drop them. After T4, D3 fails
before addon side effects, so a half-resolved config can never reach
`git commit`.

## 9. Tests

Runtime (all in existing suites, same targets as the seams):

- `WorkflowValidation` tests: D1 error on omitted sandbox per backend; D1
  error on declared sandbox for API backends; D2a error for templated payload
  without schema via each of the three reference forms — dotted
  `inbox.latest.output.payload.*`, `input.*`, and **bare** `{{field}}` — for
  referenced-field-not-in-properties, and for conditional labels without
  schema; classifier tests proving reserved roots are excluded on both
  surfaces, that a same-addon `inputs` key is excluded under `.addonConfig` but
  classified as a payload reference under `.addonInputs`, that a declared node
  `variables` key is neither scanned nor excluded, and that
  `input._rielaInput.*` / `input.upstream.*` / `input.runtime.*` are context;
  producer-walk tests — the schema is demanded of the agent node **across** a
  forwarding addon step, an addon-node predecessor never receives the
  diagnostic itself, a path with no agent node raises nothing, and a cyclic
  workflow terminates; green fixtures for compliant workflows.
- Adapter tests: `output == nil` prose answer → `{text}` unchanged;
  `output == nil` `{`-prefixed malformed answer → `{text}` (sniffing removed,
  no silent envelope); contract + fenced answer → extracted and validated;
  and the state-2 regression guard — **a node with `output.description` and no
  `jsonSchema` still rejects a prose answer** and never reaches the text wrap.
- Runner tests: a contract without declared attempts retries exactly once, for
  a schema-bearing node **and** for a description-only one; declared attempts
  still win; an extraction/envelope failure on a contract-bearing node is
  retried (not surfaced as a terminal `.invalidOutput`); final rejection
  surfaces node id + reason.
- Addon-support tests: missing **payload reference** in config → typed error
  naming producer/path/consumer; addon body not executed; producer fallback
  when `_rielaInput.latest.fromStepId` is absent; missing **context**
  reference (`event.*`) in config → still renders `""`, addon executes, with
  `telegram-sdk-trio-chat`'s `memory-save` payloadTemplate as the fixture
  shape; prompt rendering lenient for every class; `{{input.…}}` strictness;
  and a **coverage** test over the converted call sites — with the lenient
  function privatized, a `grep -rn` assertion that no addon outside
  `RielaAddonSupport` renders config through a lenient path, so the 16 sites
  of §6 cannot silently regress.
- Mock-scenario regression, two layers: every `rielaExampleWorkflowNames()`
  example and packaged fixture must (a) **validate** under the new rules and
  (b) **execute** green under its `mock-scenario.json` for the examples that
  carry addon `config`/`inputs`, because D3 is a render-time rule that
  validate alone cannot exercise. `note-rag-retrieval-fusion` (bare payload
  references) and `telegram-sdk-trio-chat` (optional event context) are the
  two that pin the D2a and D3 boundaries and are mandatory. In-repo examples
  will need D4-style edits where they violate the rules — part of the runtime
  work package, since examples live in this tree.

Bundle (D4 follow-up, riela-packages): mock-scenario run of
`fable-and-improve-opus` green under new validation; EXPECTED_RESULTS updated.

## 10. Rollout

Single runtime release. No flags, no phases. The release notes must state:
workflows failing the two new validation rules stop running until edited —
the errors name the node, field, and rule — and that a bare `{{name}}` in
addon config which the classifier cannot attribute to a run variable is now
read as a payload reference, so such references must be namespaced
(`{{workflowInput.name}}`) — declaring the key in the node's `variables` is not
an escape on that surface, because addon rendering never sees node variables.
Two further behavior changes belong in the same notes, both migration-free and
neither reversible by a flag: every node with an `output` block — including a
description-only one — now gets **two** validation attempts instead of one,
and an extraction or envelope failure on such a node is retried rather than
failing the step immediately; and a producer separated from its consumer by
forwarding addon steps is now required to declare the schema, so workflows
that relay payloads through `riela/kv-set` and friends will surface D2a errors
on the *agent* node behind the relay. The D4 bundle release ships with
or before the runtime release so the flagship package validates on day one.

## 11. Rejected-alternative index

- D1: default `workspaceWrite` (implicit permission grant), default
  `readOnly` (perpetuates the trap), warning (run proceeds to die far from
  cause).
- D2b: deleting the description-only state by erroring on an `output` block
  without `jsonSchema` — rejected on measured cost (88 of 125 in-repo example
  output blocks and 6 of 10 bundle ones are description-only) and on
  direction (the state is a coherent stricter-than-nothing contract this
  design does not replace, and the natural way to clear the error — deleting
  the `output` block — would *loosen* the node); re-keying
  `requiresOutputContract` to `jsonSchema != nil` (same loosening, silently).
- D2a/D3: a one-transition producer scan — rejected because addon nodes
  republish the whole payload (`addonForwardedApplicationPayload`,
  `WorkflowAddonSupport.swift:12-16`, used at `ProductionNodeAdapter.swift:790`,
  `+WorkflowTaskAddon.swift:177`, `+PersonaMemory.swift:126`), so the rule
  would guarantee nothing across a relay; erroring on an addon-node
  predecessor (it cannot declare `output`, so the diagnostic is
  unsatisfiable); threading the producer chain into
  `WorkflowAddonExecutionInput` so D3 could name the authoring node across a
  relay (same wire-widening objection as node `variables`, below).
- D3/§6: adding a strict render function beside the lenient
  `renderJSONTemplates` — rejected because 16 call sites in 12 files across
  two targets render addon config ad hoc, so the unconverted remainder would
  make validate and render disagree; the lenient function is privatized
  instead, which makes the compiler enumerate the work.
- D2: strict rejection of fenced answers (extractor already exists, fences
  are unambiguous), warning/allowed for missing schema (observed failure
  survives), runtime-only enforcement (later and worse than validate-time),
  keeping opportunistic envelope sniffing (silent `try?` degradation is the
  replaced contract), scanning only the dotted template forms (misses the bare
  idiom that dominates this repository, so the rule would guarantee nothing —
  `note-rag-retrieval-fusion/workflow.json:117-120`).
- D2a: scanning node `variables` values for payload references (their values
  are never template-rendered — `Prompting.swift:52` seeds them as substitution
  values, the adapters read them as knobs, and `renderPromptTemplate` makes one
  non-recursive pass over prompt text; the error would demand a schema that
  cannot make the reference resolve); and extending rule 1 to **prompt
  templates** — rejected because prompts are exactly where optional context
  lives, so a payload-reference rule over prompt text would repeat the
  over-reach that `strict over all config paths` was rejected for, only this
  time before the run rather than during it.
- D2a/D3: one exclusion set across `config` and `inputs` — rejected because
  `inputs` render before they are merged (`WorkflowAddonSupport.swift:39`,
  `:45-48`), so excluding `inputs` keys inside `inputs` would let a real
  payload reference render `""`.
- D3: threading the consuming node's declared `variables` into
  `WorkflowAddonExecutionInput` so they could serve as a lenient class and an
  escape hatch — rejected because that type is public, `Codable` with explicit
  `CodingKeys` (`WorkflowAddonExecution.swift:341-349`, `:371`) and is
  serialized for placed/distributed addon execution (guarded at
  `DeterministicWorkflowRunner+Addons.swift:24`); widening that wire format
  would grant addon nodes a capability they have never had, which is a feature
  request, not a contract fix. The classifier instead declines to exclude node
  `variables` on the addon surface, so validate and render agree.
- D3: strict over all config paths (breaks optional event context in shipped
  examples — `telegram-sdk-trio-chat/workflow.json:41-45`), strict prompts
  (breaks optional prose context), schemas-alone (non-required fields still
  render `""`), per-consumer emptiness guards (today's wrong-actor error).
