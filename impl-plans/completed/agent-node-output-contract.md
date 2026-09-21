# Agent-Node Output Contract Implementation Plan

**Status**: Implemented and verified 2026-09-21
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
- Contract-less path simplification and the retry budget in
  `Sources/RielaAdapters/AgentGatewayNodeAdapter.swift` and
  `Sources/RielaCore/DeterministicWorkflowRunner+Prompting.swift` (D2b),
  keeping the envelope switch keyed on `output != nil` and keying the budget
  on the same predicate, plus making the contract path's envelope failure
  retryable.
- Strict addon config/inputs rendering with a typed template-resolution
  error in `Sources/RielaAddonSupport/WorkflowAddonSupport.swift` plus its
  error type and publication classification (D3), **and the conversion of all
  16 existing `renderJSONTemplates` call sites** in `Sources/RielaCLI` and
  `Sources/RielaKaibaAddons` — the lenient function is privatized, so this is
  compiler-enforced rather than review-enforced (T4).
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
| T2 D2a schema validation | Shared payload-reference classifier (new RielaCore file, reused by T4) with the explicit `classifyTemplateReference(_:surface:)` signature and `TemplateSurface = .addonConfig(addonInputKeys:) / .addonInputs` from design §6, covering all three reference forms — dotted `inbox.latest.output.payload.*`, `input.<field>`, and **bare** `{{field}}` — with per-surface exclusions (reserved roots on both; same-addon `inputs` keys excluded ONLY under `.addonConfig`, because `inputs` render before they are merged at `WorkflowAddonSupport.swift:39`/`:45-48`), the `input._rielaInput|upstream|runtime` context carve-out, and the documented errs-toward-the-error direction for run-variable ambiguity. Error diagnostics: templated payload without producer schema; referenced first-segment field missing from `schema.properties`; conditional transition labels without schema. Template scanning over addon `config`/`inputs`, with producers resolved by the **producer walk** (design §4 rule 1, review F11): walk incoming transitions backwards from the consuming step, terminate a path at an agent node (one with an entry in `nodePayloads`) which is then a required producer, continue THROUGH addon-node steps because they republish the whole payload (`addonForwardedApplicationPayload`, `WorkflowAddonSupport.swift:12-16`, republished at `ProductionNodeAdapter.swift:790`, `+WorkflowTaskAddon.swift:177`, `+PersonaMemory.swift:126`), bound the walk with a visited set for loop workflows, never emit the diagnostic against an addon node (it cannot declare `output` — `AgentNodePayload` `WorkflowModel.swift:765` vs `WorkflowNodeRegistryRef:336`/`WorkflowNodeRef:536`, and `validate(_:nodePayloads:)` iterates `nodePayloads` only), and raise nothing on a path with no agent node. Node `variables` are not scanned, their values being inert text (design §4 rule 1) | new `Sources/RielaCore/TemplateReferenceClassification.swift` (classifier), `Sources/RielaCore/WorkflowValidation.swift`, `Tests/RielaCoreTests/` | T1 (same file — serialize edits) | No (shares WorkflowValidation.swift with T1) |
| T3 D2b answer path + retry default | Delete opportunistic `{`-prefix envelope sniffing in `normalizeGatewayOutput` (the `output == nil` branch becomes a pure text wrap). Keep `requiresOutputContract` keyed on `input.node.output != nil` (`AgentGatewayNodeAdapter.swift:125`) — do NOT re-key it to `jsonSchema != nil`, which would loosen every description-only node onto the text wrap (design §4 D2b, review F10). `maxValidationAttempts` default 2 when **`output != nil`** (both strict states, not just schema-bearing ones), and raise the contract path's extraction/envelope failure as `WorkflowPublicationError.validationRejected` so the existing loop guard (`DeterministicWorkflowRunner.swift:976`, `.validationRejected`-only) can actually retry it; `.invalidOutput` stays for every other adapter and failure | `Sources/RielaAdapters/AgentGatewayNodeAdapter.swift`, `Sources/RielaCore/DeterministicWorkflowRunner+Prompting.swift`, adapter/runner tests | — | Yes (with T1, T4) |
| T4 D3 template resolution error | Typed `templateResolutionFailed` error carrying producer step (`_rielaInput.latest.fromStepId`, which is written conditionally at `RuntimeMessageInputResolver.swift:118` — fall back to a sole `_rielaInput.sourceStepIds` entry, then to `an upstream step`), template path, consumer step/node/addon; strict rendering for addon `config`/`inputs` **only for classifier-payload paths** before any addon side effect, with context namespaces (`event.*`, `workflowInput.*`, `runtime.*`, `upstream.*`, `_rielaInput.*`, and those roots spelled under `input.`) still rendering `""`, `config` classified under `.addonConfig(addonInputKeys:)` and `inputs` under `.addonInputs`, and declared node `variables` deliberately NOT a lenient class because they never reach `addonVariables`; prompt rendering stays lenient for every class; error surfaces through the existing adapter-failure publication path | `Sources/RielaAddonSupport/WorkflowAddonSupport.swift` (strict surface-aware throwing render becomes the ONLY public entry point; the lenient `renderJSONTemplates` is privatized to this target so the compiler, not a reviewer, enumerates the work), new error type (RielaCore or RielaAddonSupport), and **all 16 existing call sites in 12 files across two further targets** (review F12): `RielaCLI` — `ContainerWorkflowAddonResolver.swift:128`, `ProductionNodeAdapter+AppleGatewayAdminAddons.swift:320`, `+LocalGatewaySupport.swift:178`/`:260`/`:313`, `+GitAddons.swift:67`/`:82`, `+GitPush.swift:118`, `+AppleReminderAddons.swift:100`, `+GoogleDocumentsGatewayAddons.swift:295`, `+MemoryAddonCore.swift:26`, `+KeyValueStoreAddon.swift:15`; `RielaKaibaAddons` — `KaibaRemoteGraphQLAddon.swift:58`, `KaibaNoteAddons.swift:366`, `KaibaInputValidation.swift:9`/`:14`. Plus hoisting renders that currently run after their side effect, known case `+AppleGatewayNotifications.swift:279` (reached from `:87`, after the envelope is built from gateway output at `:72`). Addon-support tests | T2 (consumes its classifier by API only — no shared file) | Partly (error type, fallback and publication path can be built alongside T1/T3; the strict/lenient switch lands once the classifier exists) |
| T5 Example/fixture reconciliation | Every in-repo example workflow and test fixture (a) validates under T1+T2 rules and (b) **executes** green under its `mock-scenario.json` where it carries addon `config`/`inputs` — D3 is a render-time rule that validate cannot exercise. `examples/note-rag-retrieval-fusion` (bare payload references) and `examples/telegram-sdk-trio-chat` (optional `event.*` context in `riela/memory-save` payloadTemplate) are mandatory; `rielaExampleWorkflowNames()` registration + mock counts intact; `RielaCLITests` green | `Sources/`/`Tests/` example + fixture JSON, `Tests/RielaCLITests/` | T1, T2, T3, T4 | No (sweeps the whole tree after rules land) |
| T6 Docs | Contract stated in the workflow authoring docs/skills text this repo owns (riela-workflow skill sources, design-doc cross-links) | `skills/` or `docs/` workflow-authoring text in this tree | T1–T4 | Yes (with T5) |
| T7 (follow-up package) D4 bundle | Listed for traceability only — executed as its own work package in `tacogips/riela-packages`, per Excluded section | riela-packages (NOT this repo) | T1–T6 released | — |

Dependency waves: wave 1 = T1, T3, and T4's error type / producer fallback /
publication path (disjoint files); wave 2 = T2, which shares
`WorkflowValidation.swift` with T1 and also lands the classifier as a new
standalone file; wave 3 = T4's strict/lenient switch over the classifier, then
T5 and T6; T7 external. Shared file: `WorkflowValidation.swift` (T1→T2 strictly
ordered, fresh read before T2). Shared API: the classifier — T2 owns it, T4
consumes it, and D2a and D3 must never diverge on what counts as a payload
reference, so one implementation serves both.

## Per-Task Completion Evidence

Record evidence per box when implementation runs; all boxes unchecked at
authoring time (planning-only run — no code written).

- [x] T1: validation tests cover omitted-sandbox error per backend and
      declared-sandbox-on-API-backend error; full `swift test` green (arm64
      shell); evidence = test names + run output.
- [x] T2: validation tests cover the three D2a error shapes for each of the
      three reference forms, including the **bare** `{{field}}` case modelled
      on `examples/note-rag-retrieval-fusion/workflow.json:117-120`, plus
      classifier tests proving reserved roots are excluded on both surfaces,
      that one and the same name matching a same-addon `inputs` key is
      excluded under `.addonConfig` but classified as a payload reference
      under `.addonInputs`, that an `inputs` entry referencing another
      `inputs` key is a validation error, that a declared node `variables`
      key is neither scanned nor excluded, and that `input._rielaInput.*`,
      `input.upstream.*` and `input.runtime.*` classify as context, plus green
      compliant fixtures. Producer-walk tests (review F11): a fixture shaped
      `agent -> riela/kv-set -> riela/git-commit` reading `{{commitMessage}}`
      demands the schema on the AGENT node and never on the addon node; an
      addon-node predecessor alone yields no diagnostic; a path with no agent
      node yields none; a cyclic workflow terminates. Evidence = test names +
      run output.
- [x] T3: adapter test proves a `{`-prefixed malformed answer on a node with
      NO `output` block yields `{text}` with no envelope; a second adapter
      test is the state-2 regression guard — a node with `output.description`
      and no `jsonSchema` still REJECTS a prose answer and never reaches the
      text wrap, proving `requiresOutputContract` was not re-keyed
      (`AgentGatewayNodeAdapter.swift:125`, review F10); runner tests prove
      the default budget of 2 for a schema-bearing node AND for a
      description-only one, that a declared `maxValidationAttempts` still
      wins, and that an extraction/envelope failure on a contract-bearing
      node is retried rather than surfacing as a terminal `.invalidOutput`;
      evidence = test names + run output.
- [x] T4: addon-support test proves a missing **payload reference** in config
      fails with producer/path/consumer in the message and the addon body
      never ran; a second proves the producer fallback when
      `latest.fromStepId` is absent; a third proves an absent **context**
      reference (`{{event.input.attachmentText}}`, telegram `memory-save`
      shape) still renders `""` and the addon still executes; a fourth proves
      the chosen F6 semantics — a key declared in the consuming node's
      `variables` is classified identically at validate and render time on the
      addon surface (error both places, never a run-time-only surprise) and
      `{{workflowInput.<name>}}` is the escape that actually resolves; a fifth
      proves a payload reference inside addon `inputs` raises
      `templateResolutionFailed` rather than rendering `""`, while the same
      name inside `config` resolves to the rendered input; prompt
      lenient tests unchanged (`Tests/RielaCoreTests/PromptTemplateTests.swift:8`,
      `DeterministicWorkflowRunnerTests.swift:365`). Call-site coverage
      (review F12): `grep -rn 'renderJSONTemplates' Sources/ | grep -v
      RielaAddonSupport` returns ZERO lines — the lenient function is private
      to `RielaAddonSupport` and all 16 former sites in 12 files across
      `RielaCLI` and `RielaKaibaAddons` render through the strict entry point;
      plus a test proving the hoisted render in
      `+AppleGatewayNotifications` fails BEFORE the gateway mutation rather
      than after it (`:279` today, reached from `:87` after `:72`). Evidence =
      test names + run output + the grep result.
- [x] T5: full `swift test` from repo root green, including `RielaCLITests`
      example suites, AND a mock-scenario execution pass —
      `riela workflow run examples/note-rag-retrieval-fusion --mock-scenario
      examples/note-rag-retrieval-fusion/mock-scenario.json` and the same for
      `examples/telegram-sdk-trio-chat` — both finishing green with the
      telegram `memory-save` record still written when the event carries no
      `threadId`/`attachments`; evidence = summary counts **and** the two run
      outcomes with their session ids.
- [x] T6: docs text states the contract (answer shape, retry budget,
      operator-visible failures, validate rules); evidence = file paths.

## Verification Plan

1. `arch -arm64 /bin/zsh -lc 'swift test'` from repo root — zero failures
   (known interleaved-submit timing flake excepted, rerun to confirm).
2. `swift run riela workflow validate` against an in-repo example that
   deliberately violates each rule (temporary fixture) — the three error
   messages name node, field, and rule.
3. Read-back of `normalizeGatewayOutput`: the `output == nil` branch contains
   no JSON parsing, AND `requiresOutputContract` is still
   `input.node.output != nil` at `AgentGatewayNodeAdapter.swift:125` (the
   state-2 guard, review F10).
3b. Mock-scenario execution of the two addon-config-bearing examples (T5),
   because D3 fails at render time and `workflow validate` cannot reach it.
3c. `grep -rn 'renderJSONTemplates' Sources/ | grep -v RielaAddonSupport`
   returns zero lines (review F12) — proof that no addon still renders config
   through a lenient path.
4. For this planning run itself: `git diff --stat` proof below — no
   `Sources/` or `Tests/` path modified.

## Completion Criteria

- All D1–D3 rules implemented with the exact error shapes in the design;
  D2b behavior changes in place — sniffing deleted from the `output == nil`
  branch, the envelope switch still keyed on `output != nil`, default 2
  attempts for every `output`-bearing node, and the contract path's
  extraction/envelope failure retryable.
- D2a's producer walk traverses forwarding addon nodes and never emits a
  diagnostic an addon node cannot satisfy.
- Every former `renderJSONTemplates` call site outside `RielaAddonSupport`
  renders through the strict entry point, with the lenient function private
  and the verification-plan grep returning zero.
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
$ git rev-parse HEAD
36285f0187862a3a7d251417f96264a309a87e90
$ git diff --stat=200 --name-status ca1ce34..HEAD
A	design-docs/specs/design-agent-node-output-contract.md
M	impl-plans/README.md
A	impl-plans/active/agent-node-output-contract-dispatch.json
A	impl-plans/active/agent-node-output-contract.md
$ git diff --stat=200 ca1ce34..HEAD
 design-docs/specs/design-agent-node-output-contract.md     | 364 +++++
 impl-plans/README.md                                       |   1 +
 impl-plans/active/agent-node-output-contract-dispatch.json |  39 +++
 impl-plans/active/agent-node-output-contract.md            | 149 +++++
 4 files changed, 553 insertions(+)
```

(`+` runs elided for width; the four paths and the 553-insertion total are
verbatim.) Four documentation paths, zero `Sources/` and zero `Tests/`
paths — **AC7 satisfied**.

*Superseded snapshot.* The block above is the proof as of `36285f0` and is
kept as the historical record. The resumed run's entries asked a later
checkpoint to replace it with the final commit's numbers; the checkpoint
commit `cf5dde4` landed without doing so, so the current AC7 proof — five
paths, 1276 insertions, still zero `Sources/` and zero `Tests/` — is recorded
in the final progress-log entry below instead.

### 2026-09-21 — Step 6 read-back (still planning-only; no code written)

The assigned dispatch (`impl-plans/active/agent-node-output-contract-dispatch.json`,
`notes.planningOnly`) forbids any `Sources/` or `Tests/` change, so this step
implemented nothing. It re-verified the design against the tree and closed the
plan's own open checkpoint obligation. Evidence:
`tmp/agent-node-output-contract/plans/agent-node-output-contract/attempt-1/`
(untracked; `00-pre-edit-state.log`, `01-seam-verification.log`,
`02-intended-edits.md`, `03-post-edit-state.log`).

**Independent seam re-verification.** All 15 `file:line` citations in the
design were re-read at `36285f0` (`01-seam-verification.log`). *Corrected by
the 2026-09-21 review and by the attempt-2 recheck below: 13 of the 15 printed
the cited symbol exactly; `PromptTemplate.swift:21` was off by one (the `?? ""`
is `:20`) and `WorkflowAddonSupport.swift:35-38` was off by one at its start
(`:35` is `workflowId`; `stepId`/`nodeId`/`addonName` are `:36-38`). The blanket
"all 15 print the cited symbol" claim originally recorded here was wrong and is
retracted; both citations are fixed in the design as of attempt 2.* The
re-read list: permission-mode append at
`AgentGatewayNodeAdapter.swift:608`, `claudePermissionMode` at `:660`,
`normalizeGatewayOutput` at `:719`, the opportunistic `{`-sniff at `:728`,
`WorkflowModel.swift:777`, `WorkflowValidation.swift:102`,
`RuntimeOutputValidation.swift:41`, `RuntimeOutputExtraction.swift:3`,
`AdapterContracts.swift:295`, `…+Prompting.swift:17`,
`DeterministicWorkflowRunner.swift:875`, `PromptTemplate.swift:21`
(*wrong — the correct line is `:20`*), `WorkflowAddonSupport.swift:18`,
`ProductionNodeAdapter+GitAddons.swift:73`.
`grep -c agentSandbox Sources/RielaCore/WorkflowValidation.swift` = 0 (D1 has
no rule today); `minLength` is in the supported schema keyword list
(`RuntimeOutputValidation.swift:94`), confirming the section-7 edge case.
Bundle counts re-checked read-only: 16 node files, all 16 `claude-code-agent`,
5 with `agentSandbox`, 4 with `jsonSchema`, `node-plan-checkpoint.json` with
neither, `workflow.json:127` and `:159` consuming
`{{inbox.latest.output.payload.commitMessage}}`.

**Two citation defects found and fixed in the design (no decision changed).**

1. D3 cited `WorkflowAddonSupport.swift:52-55` for `stepId`/`nodeId`/
   `addonName`; the assignments are at `:35-38`. Corrected.
2. D3 described `_rielaInput.latest.fromStepId` as simply present. It is
   written conditionally by `resolvedInputMessageMetadata`
   (`RuntimeMessageInputResolver.swift:107`, guard at `:118`) and is absent
   for a message with no originating step, while D3's mandated error text
   names the producer. The design now specifies the resolution order
   (`latest.fromStepId` → sole `_rielaInput.sourceStepIds` entry → literal
   `an upstream step`), and T4's deliverable and completion evidence carry it.

**Acceptance criteria status.** AC1–AC7 PASS (AC7 proof pasted above; AC6 row
present at `impl-plans/README.md:46` with unchecked count 6, matching the six
`- [ ]` boxes here). AC8 is half-satisfied: the work is committed on
`design/agent-node-output-contract` at `36285f0` and `main` is untouched
(`main` = `c33a783`, unrelated), but the branch has no upstream and is not
yet pushed (`git rev-parse --abbrev-ref @{u}` → *no upstream configured*).
Pushing is a serial-checkpoint action and is outside this step's authority;
it remains the single open acceptance item. This step's own document edits
are uncommitted in the working tree and need the same checkpoint commit.

### 2026-09-21 — Step 6 attempt 2: review revision (still no code written)

Independent review (`opus-review`, `changes-requested`) raised F1 (high), F2,
F3, F4 (medium) and F5 (low). Every finding was re-verified against the source
before editing — evidence
`tmp/agent-node-output-contract/plans/agent-node-output-contract/attempt-2/`
(`10-finding-reverification.log`, `11-intended-edits.md`,
`12-post-edit-state.log`; attempt-1's four logs are untouched). All four
document findings are addressed here; F3 is the checkpoint's action.

**F1 (high) — D3 over-reached from payload fields to all config paths.**
Confirmed against the tree: `examples/telegram-sdk-trio-chat/workflow.json:37-45`
is a `riela/memory-save` `config.payloadTemplate` over `{{event.input.text}}`,
`{{event.conversation.threadId}}`, `{{event.input.historySource}}`,
`{{event.input.attachments}}`, `{{event.input.imagePaths}}` and
`{{event.input.attachmentText}}` — all optional per event, all rendering `""`
today via `exactTemplateValue` → `renderPromptTemplate`. A surface-wide strict
rule would have turned the ordinary plain-text message into a hard
`memory-save` failure. Design section 5 now draws the boundary by **path
class**, not by surface: strict for payload references
(`inbox.latest.output.payload.*`, `input.*`, classifier-bare), lenient for
context namespaces (`event.*`, `workflowInput.*`, `runtime.*`, `_rielaInput.*`,
declared node `variables`), with the telegram example written in as the worked
case and "strict over all config paths" added to the rejected alternatives in
sections 5 and 11. The section now says plainly that the earlier framing —
machine-consumed config is uniformly obligatory — is contradicted by this
repository.

**F2 (medium) — D2a missed the dominant idiom.** Confirmed:
`addonVariables` merges the whole resolved input payload flat
(`WorkflowAddonSupport.swift:20-22`), so `{{queryPlan}}` reaches what
`{{inbox.latest.output.payload.queryPlan}}` reaches, and
`examples/note-rag-retrieval-fusion/workflow.json:117-120` and `:136-145` use
exactly that bare form in `kaiba/note-search` config. Design section 4 now
defines a payload reference as three forms including the bare one, gives the
classifier (reserved runtime roots, declared node `variables`, same-addon
`inputs` are excluded), and states the undecidability honestly: `request.variables`
(`DeterministicWorkflowRunner+Addons.swift:58`) is run-supplied and
`WorkflowDefinition` (`WorkflowModel.swift:582-593`) declares no names for it,
so a bare identifier fed by a run variable is indistinguishable at validate
time. The rule errs toward the error, with the cost and the migration-free
escapes (`{{workflowInput.x}}`, or a declared node `variables` key) stated.

**F4 (medium) — T5 could not have caught F1.** T5's deliverable and completion
box now require mock-scenario **execution** over the addon-config-bearing
examples (`note-rag-retrieval-fusion`, `telegram-sdk-trio-chat`, both carry
`mock-scenario.json`) via `riela workflow run … --mock-scenario …`, not
validate-only, with the run outcomes and session ids as evidence. Design
section 9 carries the same two-layer requirement, and the verification plan
gains step 3b.

**F5 (low) — citations.** `PromptTemplate.swift:21` → `:20`;
`WorkflowAddonSupport.swift:35-38` → `:36-38`. The attempt-1 entry's blanket
"all 15 citations print the cited symbol" claim is retracted in place above
with the true count (13 exact, 2 off by one).

**Knock-on plan changes.** The classifier is one implementation serving both
D2a and D3, so T2 owns it as a new standalone
`Sources/RielaCore/TemplateReferenceClassification.swift`, T4 depends on it by
API, and the dependency waves were rewritten accordingly. T2 and T4 completion
boxes gained the bare-reference and lenient-context cases; the unchecked-box
count stays 6, matching `impl-plans/README.md:46`.

**F3 (medium) — AC8, not actionable here.** Re-checked at attempt 2:
`git rev-parse --abbrev-ref --symbolic-full-name @{u}` → *no upstream
configured*, and `git ls-remote --heads origin design/agent-node-output-contract`
returns nothing (exit 0, empty). The serial checkpoint must commit both
modified documents and push this branch to `origin` with upstream tracking,
never `main`, then re-run `git diff --stat=200 ca1ce34..HEAD` and replace the
checkpoint block above so it names the final commit instead of `36285f0`.
Committing and pushing are outside this step's authority.

### 2026-09-21 — Step 6 attempt 3: second review revision (still no code written)

Second independent review (`opus-review`, `changes-requested`) raised F6 (high)
and F7 (low) plus non-blocking citation housekeeping. Both were re-verified
against the source before editing — evidence
`tmp/agent-node-output-contract/plans/agent-node-output-contract/attempt-3/`
(`20-finding-reverification.log`, `21-intended-edits.md`,
`22-post-edit-state.log`); attempt-1 and attempt-2 evidence untouched. The
review also confirmed F1, F2, F4 and F5 genuinely resolved, and AC1–AC7 met.

**F6 (high) — the prescribed escape did not exist.** Confirmed exactly as
reported: the addon dispatch branch carries no node payload
(`DeterministicWorkflowRunner.swift:511-532`), `WorkflowAddonExecutionInput`
(`WorkflowAddonExecution.swift:341-349`) has no node-variables field,
`addonVariables` (`WorkflowAddonSupport.swift:18-43`) composes without them,
and `payload.variables` is consumed only on the agent-prompt path
(`DeterministicWorkflowRunner+Prompting.swift:52`). The design's own remedy —
"declare it in the node's `variables`" — would therefore have passed validate
and then failed at render time with a `templateResolutionFailed` blaming an
upstream producer for a field it was never asked to publish: the exact defect
class this design exists to remove.

Resolved with **option B, refined by surface** rather than option A. Option A
(threading node `variables` into `WorkflowAddonExecutionInput`) is recorded as
a rejected alternative in §5 and §11 with its reason: that type is public,
`Codable` with explicit `CodingKeys` (`:341-349`, `:371`) and is serialized for
placed/distributed addon execution (guarded at
`DeterministicWorkflowRunner+Addons.swift:24`), so option A widens a wire
format to grant addon nodes a capability they have never had — a feature
request, not a contract fix. The refinement keeps the rule honest instead of
merely deleting a class: §4 now computes the classifier's exclusions **per
surface**, because the two namespaces genuinely differ — declared node
`variables` are excluded on the agent-prompt surface (where `promptVariables`
merges them) and not on the addon surface (where nothing does). §5 states the
consequence plainly, and §7 and §10 no longer offer node `variables` as an
escape; `{{workflowInput.<name>}}` is the sole escape on the addon surface and
it does resolve (`WorkflowInputFilterEvaluation.swift:191-194`).

**F6 second half — §6's classifier contract was unsatisfiable.** It asked for
"a template string and the consuming node payload", which the render-time seam
does not have. §6 now gives an explicit signature —
`classifyTemplateReference(_ path: String, surface: TemplateSurface)` with
`TemplateSurface = .addonConfig(addonInputKeys:) | .agentPrompt(nodeVariableKeys:)`
(*superseded at attempt 4: the second case is now `.addonInputs`, and
`.agentPrompt` is gone — see F9 below*)
— states what each call site can construct (validate time: either case, from
the node payload; render time: only `.addonConfig`, from
`WorkflowAddonExecutionInput.addon.inputs`), and names that asymmetry as the
mechanism behind "the two must never diverge" instead of asserting the
invariant without one. T2's deliverable carries the signature; T4 depends on it
by API.

**F7 (low) — two spellings of one path disagreed.** Confirmed:
`variables["input"]` is the whole `resolvedInputPayload`
(`WorkflowAddonSupport.swift:34`), which carries `_rielaInput`, `upstream` and
`runtime` — which is why `addonForwardedApplicationPayload` strips exactly
those three at `:12-16`. §5 and §7 now exclude `input._rielaInput.*`,
`input.upstream.*` and `input.runtime.*` from the strict class, and T2's
completion box gains the case.

**Housekeeping — reserved-root citation split.** §4 previously attributed all
reserved roots to `WorkflowAddonSupport.swift:23-38`. Corrected to name each
entry point: `inbox` at `:23-33`, `input` at `:34`, the four ids at `:35-38`,
`event`/`workflowInput` inside `request.variables`
(`WorkflowInputFilterEvaluation.swift:191-194`), and
`_rielaInput`/`upstream`/`runtime` inside `resolvedInputPayload` merged flat at
`:20-22`.

**Unchanged and still open.** AC8 remains the single unmet criterion and is
still checkpoint-owned: re-checked at attempt 3, the branch has no upstream and
`git ls-remote --heads origin design/agent-node-output-contract` is empty. The
checkpoint must commit all three rounds of document corrections and push this
branch — never `main` — then re-run `git diff --stat=200 ca1ce34..HEAD` and
replace the checkpoint block above so it names the final commit rather than
`36285f0`. Unchecked-box count stays 6, matching `impl-plans/README.md:46`.

### 2026-09-21 — Step 6 attempt 4: third review revision (still no code written)

Third independent review raised F8 (medium) and F9 (low); F3/AC8 was restated
as not actionable here. Both actionable findings were re-verified from source
before editing — evidence
`tmp/agent-node-output-contract/plans/agent-node-output-contract/attempt-4/`
(`30-finding-reverification.log`, `31-intended-edits.md`,
`32-post-edit-state.log`); attempts 1–3 untouched. The review also confirmed
F6 and F7 resolved, every citation in the attempt-3 text correct, and AC1–AC7
met.

**F8 (medium) — one exclusion set was wrong across two different surfaces.**
Confirmed: `addonVariables` calls `renderAddonInputs` with the *pre-*`inputs`
namespace (`WorkflowAddonSupport.swift:39`, `:45-48`) and only then merges the
rendered results (`:39-41`). So an addon `inputs` key is in scope while
`config` renders and out of scope while `inputs` render. The single
`.addonConfig(addonInputKeys:)` case therefore told an implementer to exclude
`inputs` keys while classifying `inputs` themselves — under which
`inputs: {"summary": "{{results}}"}` with `results` an upstream payload field
would be called context, D2a would not require the producer's schema, and D3
would render `""` into a machine-consumed field. That is the §1 item 3 defect
class, reintroduced by the fix for it, and structurally identical to F6: an
exclusion granted on a surface whose mechanism is absent.

Resolved by splitting the surface: `TemplateSurface` is now
`.addonConfig(addonInputKeys:)` | `.addonInputs` (reserved roots only). §4
explains the ordering that makes them differ and states the shadowing
consequence; §5 names which entry point each rendering surface uses; §6 gives
the two-case signature and — importantly — restates the invariant **per
surface**, since `{{results}}` may legitimately be context in `config` and a
payload reference in `inputs` on the same node; §7 gains two edge cases (an
`inputs` entry referencing another `inputs` key can never resolve and is a
validation error; a payload field colliding with an `inputs` key is protected
in `inputs` and shadowed in `config`); §11 records the single-exclusion-set
alternative as rejected. T2's deliverable and box carry the two-case surface
and the config-vs-inputs test; T4's box requires a payload reference inside
`inputs` to raise `templateResolutionFailed` rather than render `""`.

**F9 (low) — rule 1 scanned a surface that is never rendered.** Confirmed by
enumerating every read site of node payload `variables`:
`DeterministicWorkflowRunner+Prompting.swift:52` seeds them as substitution
*values*; `AgentGatewayNodeAdapter.swift:93`, `:575`, `:593` and
`AdapterUtilities.swift:34` read them as adapter knobs; `renderPromptTemplate`
(`PromptTemplate.swift:3-24`) makes one non-recursive pass over the prompt
*text*. A `{{commitMessage}}` inside a variable value is emitted literally, so
demanding a producer schema for it would be an error that adding the schema
cannot fix. Resolved with the review's option (a): rule 1 now scans successor
addon `config`/`inputs` only, and `.agentPrompt` is gone from `TemplateSurface`
— which also leaves the classifier with exactly the two surfaces F8 requires.
Option (c), extending rule 1 to prompt templates, is recorded as rejected in
§11: prompts are precisely where optional context lives, so a payload-reference
rule over prompt text would repeat the over-reach that `strict over all config
paths` was rejected for, only before the run instead of during it. T2's
deliverable and box mirror the change.

**Still open and unchanged.** AC8: re-checked at attempt 4 — no upstream,
`git ls-remote --heads origin design/agent-node-output-contract` empty (exit
0). Four rounds of document corrections are uncommitted. The checkpoint must
commit both documents and push this branch — never `main` — then re-run
`git diff --stat=200 ca1ce34..HEAD` and replace the checkpoint block above so
it names the final commit rather than `36285f0`. Unchecked-box count stays 6,
matching `impl-plans/README.md:46`.

### 2026-09-21 — Resumed run: re-verification after OOM kill (still no code written)

The prior attempt was killed by the operator's machine running out of memory
after the attempt-4 revision was written to disk but before the checkpoint
commit. This resumed run started, per the resume mandate, by reading
`git status`, `git diff` and both documents: HEAD unchanged at `36285f0`, the
working tree holding exactly the two modified documents (+663/−56, the
attempt-2/3/4 review revisions), nothing staged, nothing untracked, `main`
untouched at `c33a783`. Everything on disk was judged correct and kept;
nothing was rewritten.

**Independent citation re-verification (fresh reads, not trusted from this
log).** The resumed analysis re-read every load-bearing seam from source and
all matched the design exactly: `claudePermissionMode(for:)` mapping with
`nil → nil` (`AgentGatewayNodeAdapter.swift:660`) and the conditional
`--permission-mode` append (`:608`); `normalizeGatewayOutput` (`:719`) with
the opportunistic `try?` sniff (`:728-731`); nil-contract acceptance
(`RuntimeOutputValidation.swift:41`); `maxValidationAttempts` default 1
(`DeterministicWorkflowRunner+Prompting.swift:17`); missing path → `""`
(`PromptTemplate.swift:20`); the full `addonVariables` ordering — strip list
`:12-16`, flat merge `:20-22`, `inbox` `:23-33`, `input` `:34`, ids `:35-38`,
`inputs` merged last `:39-41`, `renderAddonInputs` `:45-48`
(`WorkflowAddonSupport.swift`); the empty-commit-message guard
(`ProductionNodeAdapter+GitAddons.swift:73`); zero `agentSandbox` mentions in
`WorkflowValidation.swift`; optional `agentSandbox` at
`WorkflowModel.swift:777`. Bundle counts re-checked read-only: 16 node files,
16 `claude-code-agent`, 5 with `agentSandbox`, 4 with `jsonSchema`,
`node-plan-checkpoint.json` with neither, `workflow.json:127`/`:159`
consuming `{{inbox.latest.output.payload.commitMessage}}`. Knowledge-base
recall for `agent-node-output-contract` was re-issued and again returned zero
results.

**Design and plan re-accepted without change.** No fifth revision was needed;
this entry is the only edit of the resumed run. AC1–AC7 remain PASS; AC8
remains the single open item and stays checkpoint-owned: commit both modified
documents on `design/agent-node-output-contract`, push that branch to
`origin` with upstream tracking (plain push, never force, never `main`), then
re-run `git diff --stat=200 ca1ce34..HEAD` and replace the attempt-1
checkpoint block so it names the final commit rather than `36285f0`.
Unchecked-box count stays 6, matching `impl-plans/README.md:46`.

### 2026-09-21 — Checkpoint: dispatch manifest for the resumed run (still no code written)

The resumed run's checkpoint verified that branch and HEAD still match the
analysis context (`design/agent-node-output-contract` @
`36285f0187862a3a7d251417f96264a309a87e90`), that the index is empty, and that
the working tree carries only the two accepted documents. It then wrote a new
dispatch manifest with its own unique task id rather than overwriting the
killed run's:

- manifest: `impl-plans/active/agent-node-output-contract-r2-dispatch.json`
  (`taskId` `agent-node-output-contract-r2`, `originalHead` `36285f0`)
- evidence root: `tmp/agent-node-output-contract-r2` (untracked via
  `.gitignore:41`), with
  `checkpoint/00-checkpoint-verification.log` holding the verbatim git proof
  and `plans/agent-node-output-contract/attempt-1/` reserved for the future
  implementation wave
- superseded, preserved untouched: `agent-node-output-contract-dispatch.json`
  (`originalHead` `ca1ce34`) and `tmp/agent-node-output-contract/`, which
  holds the killed run's `attempt-1`…`attempt-4` review evidence (F1–F9)

Machine-checked at checkpoint time: `git diff --name-only` and
`git diff --name-only ca1ce34..HEAD` each match zero `Sources/` or `Tests/`
paths; the plan's unchecked-box count is 6, matching
`impl-plans/README.md:46`. The manifest validates as a single-plan acyclic
dependency graph with safe repository-relative paths, all of which exist.

AC8 stays the single open acceptance item: the commit created from this
checkpoint must carry exactly the design doc, this plan and the new manifest,
after which the branch is pushed to `origin` with upstream tracking (plain
push, never force, never `main`), `git diff --stat=200 ca1ce34..HEAD` is
re-run, and the attempt-1 checkpoint block above is replaced so it names the
final commit rather than `36285f0`.

### 2026-09-21 — Step 6 on a planning-only package (no code written)

The assigned contract (`impl-plans/active/agent-node-output-contract-r2-dispatch.json`,
`fanoutItem.acceptanceCriteria`) is planning-only, so this implementation step
wrote **no production code and no test code**. Its work was an independent
re-verification of the committed design against the tree at `cf5dde4`, plus
the AC7 proof the checkpoint left stale. Evidence:
`tmp/agent-node-output-contract-r2/plans/agent-node-output-contract/attempt-1/`
(`50-step6-verification.log`, `51-intended-edits.md`; the killed run's
`tmp/agent-node-output-contract/attempt-1…4` logs are untouched).

**Seams re-read from source this run, all matching the design exactly.**
`--permission-mode` appended only when the mapping is non-nil
(`AgentGatewayNodeAdapter.swift:608`) and `claudePermissionMode(for:)` with
`case nil: nil` (`:660`); `normalizeGatewayOutput` (`:719`) and the
opportunistic `try?` sniff (`:728-731`); `normalizeTextBusinessPayload`
(`AdapterContracts.swift:295`); nil-contract acceptance
(`RuntimeOutputValidation.swift:41`); `maxValidationAttempts` default 1
(`…+Prompting.swift:17`) and the attempt loop head
(`DeterministicWorkflowRunner.swift:875`); `?? ""`
(`PromptTemplate.swift:20`); `parseJSONObjectCandidate`
(`RuntimeOutputExtraction.swift:3`); the whole `addonVariables` ordering —
strip list `:12-16`, `addonVariables` `:18`, flat merge `:20-22`, `inbox`
`:23-33`, `input` `:34`, ids `:35-38`, `inputs` merged last `:39-41`,
`renderAddonInputs` `:45-48`, `exactTemplateValue` `:64-75`
(`WorkflowAddonSupport.swift`); the empty-commit-message guard at
`ProductionNodeAdapter+GitAddons.swift:73` inside `renderedCommitMessage`
(`:63`); optional `agentSandbox` at `WorkflowModel.swift:777` and
`grep -c agentSandbox Sources/RielaCore/WorkflowValidation.swift` = 0;
`validate(_:nodePayloads:)` at `WorkflowValidation.swift:102`; the addon
dispatch branch passing no node payload
(`DeterministicWorkflowRunner.swift:511-532`) and
`WorkflowAddonExecutionInput` having no such field
(`WorkflowAddonExecution.swift:341-349`, `CodingKeys` `:371`);
`request.variables` threaded at `…+Addons.swift:58` and the distributed guard
at `:24`; node `variables` read as knobs at `AgentGatewayNodeAdapter.swift:93`,
`:575`, `:593` and `RielaAdapters/AdapterUtilities.swift:34`
(`forwardImageAttachments`); `promptVariables` seeding at `…+Prompting.swift:52`
and the schema-example injection at `:153`; the lenient-prompt assertions at
`Tests/RielaCoreTests/PromptTemplateTests.swift:8` and
`DeterministicWorkflowRunnerTests.swift:365`. Worked cases re-read verbatim:
`examples/note-rag-retrieval-fusion/workflow.json:117-120` and `:136-145`
(bare payload references) and `examples/telegram-sdk-trio-chat/workflow.json:31-48`
with the five optional `event.*` paths at `:41-45`. Read-only bundle counts
re-checked: 16 node files, all 16 `claude-code-agent`, 5 with `agentSandbox`,
4 with `jsonSchema`, `node-plan-checkpoint.json` with neither,
`workflow.json:127`/`:159` consuming
`{{inbox.latest.output.payload.commitMessage}}`. One citation is a bare
filename whose directory differs from its neighbours and is recorded here in
full for the implementation session: `AdapterUtilities.swift` lives in
`Sources/RielaAdapters/`, not `Sources/RielaCore/`.

**AC7 proof, current (this is the run's own diff, superseding the `36285f0`
block above).**

```
$ git rev-parse HEAD
cf5dde46b46e07aef963ced1950aa803b3b31a63
$ git status --porcelain=v1        # before this entry was written
(empty)
$ git diff --stat=200 ca1ce34..HEAD
 design-docs/specs/design-agent-node-output-contract.md        | 652 +++
 impl-plans/README.md                                          |   1 +
 impl-plans/active/agent-node-output-contract-dispatch.json    |  39 +++
 impl-plans/active/agent-node-output-contract-r2-dispatch.json |  42 +++
 impl-plans/active/agent-node-output-contract.md               | 542 +++
 5 files changed, 1276 insertions(+)
$ git diff --name-only ca1ce34..HEAD | grep -cE '^(Sources|Tests)/'
0
$ git status --porcelain=v1 | grep -cE '(Sources|Tests)/'
0
```

(`+` runs elided for width; the five paths and the 1276-insertion total are
verbatim — full log in `50-step6-verification.log`.) `ca1ce34..HEAD` is the
correct range, not `main..HEAD`: local `main` is `c33a783` and has advanced
past this branch's base, `git merge-base main HEAD` = `ca1ce34`. **AC7
satisfied**, before and after this entry. `main` is untouched, never merged
into, never reset. There was nothing to build or test: no `swift build` /
`swift test` was run, and none is required for a planning-only package.

**Read-only constraint re-checked.** `git -C /Users/taco/gits/tacogips/riela-packages
status --porcelain=v1 -- packages/fable-and-improve-opus` returns zero paths,
and no file under
`packages/fable-and-improve-opus/workflows/fable-and-improve-opus` has a
modification time from today. That repository's other dirty paths
(`packages/codex-design-and-implement-review-loop/…`, `README.md`) pre-date
this run and belong to the operator.

**AC8 remains the single open acceptance item, and stays checkpoint-owned.**
`git rev-parse --abbrev-ref @{u}` → *no upstream configured*;
`git ls-remote --heads origin design/agent-node-output-contract` → empty
(exit 0). The branch is committed but not pushed. This step does not commit or
push: the shared-branch protocol governing it forbids `git add`/`commit`/
`push`. The checkpoint must commit this entry and push
`design/agent-node-output-contract` to `origin` with upstream tracking —
plain push, never force, never `main`. Unchecked-box count stays 6, matching
`impl-plans/README.md:46`.

### 2026-09-21 — Step 6 attempt 2 of the resumed run: review F10–F12 revision (still no code written)

Independent review (`opus-review`, `changes-requested`) raised F10, F11, F12
(all medium, all against the documents) and F13 (AC8, checkpoint-owned). Every
finding was re-verified against source **before** editing — evidence
`tmp/agent-node-output-contract-r2/plans/agent-node-output-contract/attempt-1/`
(`53-f10-f12-reverification.log`, `54-intended-edits.md`; the 50-/51-/52- logs
of the first Step-6 pass and the killed run's `attempt-1..4` are untouched).
All three findings are confirmed and addressed. No code was written; the edit
is confined to the two documents.

**F10 — the output contract has three states, not two. Confirmed.**
`grep -rn requiresOutputContract Sources/` →
`AgentGatewayNodeAdapter.swift:125`, `requiresOutputContract: input.node.output
!= nil`; `workflowOutputContract(from:)`
(`DeterministicWorkflowRunner+Prompting.swift:10-15`) returns a contract with a
`nil` schema inside it whenever `output` is non-nil. So state 2 —
`output != nil, jsonSchema == nil` — is on the **strict** path and already
throws on prose. Two claims of this design were contradicted by source and are
**retracted**: §1's "so nothing enforces it" and §7's "the description alone
enforces nothing". Both are replaced and the retraction is recorded in §1's
correction block, per the brief-vs-source mandate.

The decision the review asked for: **state 2 is preserved verbatim**, and
D2b's predicates are written separately (§4 D2b now carries a four-row
predicate table). The alternative — erroring on an `output` block without a
`jsonSchema`, which would collapse the predicates into one — was measured and
rejected: **88 of the 125 agent-node `output` blocks under `examples/` are
description-only**, as are **6 of the 10** in `fable-and-improve-opus`
(`node-fable-design`, `node-fable-goal-review`, `node-final-output`,
`node-opus-implementation`, `node-opus-review`, `node-step9-commit-message`).
Beyond the 88-file sweep, the direction is wrong: the natural way to clear
such an error is to delete the `output` block, which leaves the node *looser*
than before. Re-keying `requiresOutputContract` to `jsonSchema != nil` is now
explicitly forbidden in the design and in T3's row and evidence box.

The review's second half of F10 — that state 2 sits on a strict path the
retry loop never retries — is also confirmed
(`DeterministicWorkflowRunner.swift:976`, `guard case .validationRejected`)
and closed by a decision rather than a note: the retry budget keys on
`output != nil` (both strict states), and on the contract path the
extraction/envelope failure is raised as `validationRejected` so the existing
loop retries it. `.invalidOutput` is kept everywhere else. The migration-free
consequence is stated in §4 and §10.

**F11 — the one-transition scan misses forwarded payloads. Confirmed.**
`addonForwardedApplicationPayload` (`WorkflowAddonSupport.swift:12-16`) strips
only `_rielaInput`/`upstream`/`runtime` and its result is published at
`ProductionNodeAdapter.swift:790`, `+WorkflowTaskAddon.swift:177` and
`+PersonaMemory.swift:126`, so a field survives arbitrarily many addon hops.
An addon node also structurally cannot satisfy a schema demand: `output` is on
`AgentNodePayload` (`WorkflowModel.swift:765`) while `addon` is on
`WorkflowNodeRegistryRef:336`/`WorkflowNodeRef:536`, and
`validate(_:nodePayloads:)` (`:102-113`) iterates `nodePayloads` only.
D2a rule 1 now defines a **producer walk**: backwards over transitions,
terminating each path at an agent node (the required producer), passing
through addon-node steps, bounded by a visited set for loop workflows, and
raising nothing on a path that reaches no agent node. New §7 edge cases and a
T2 test fixture (`agent -> riela/kv-set -> riela/git-commit`) pin it.

A limit the review's remedy implied but the source forbids fixing the same
way: **D3 cannot mirror the walk.** `WorkflowAddonExecutionInput`
(`WorkflowAddonExecution.swift:341-349`) carries no workflow definition, so at
render time the only producer available is `_rielaInput.latest.fromStepId`,
which across a relay is the addon that delivered the payload, not the agent
that authored it. Rather than widen that public `Codable` wire type — the same
objection §11 already records for node `variables` — §5 now states the limit
and changes the message to assert only what it knows: `step '<deliverer>'
delivered this input without payload field '<field>'`. D2a's walk is named as
the guarantee that the authoring node was made to declare the field.

**F12 — "all addon families route through this one seam" is false. Confirmed.**
`grep -rn 'renderJSONTemplates' Sources/ | grep -v WorkflowAddonSupport` → **16
sites in 12 files across two further targets**: `RielaCLI`
(`ContainerWorkflowAddonResolver.swift:128`,
`+AppleGatewayAdminAddons.swift:320`, `+LocalGatewaySupport.swift:178`/`:260`/
`:313`, `+GitAddons.swift:67`/`:82`, `+GitPush.swift:118`,
`+AppleReminderAddons.swift:100`, `+GoogleDocumentsGatewayAddons.swift:295`,
`+MemoryAddonCore.swift:26`, `+KeyValueStoreAddon.swift:15`) and
`RielaKaibaAddons` (`KaibaRemoteGraphQLAddon.swift:58`,
`KaibaNoteAddons.swift:366`, `KaibaInputValidation.swift:9`/`:14`). The claim
is retracted in §6. The migration shape is now decided rather than left to
care: the strict surface-aware throwing function becomes the **only public
render entry point** and the lenient `renderJSONTemplates` is privatized to
`RielaAddonSupport`, so every unconverted site is a compile error. T4's write
scope enumerates all 16; its evidence box requires
`grep -rn 'renderJSONTemplates' Sources/ | grep -v RielaAddonSupport` to
return zero, and the verification plan carries the same grep as step 3c.

F12's side-effect half is confirmed and refined: the render at
`+AppleGatewayNotifications.swift:279` is inside `dismissOutput(input:envelope:)`,
reached from `:87`, which runs only after `:72` has built the envelope from the
gateway process output — i.e. after the mutation. §5's "before any side effect"
is therefore no longer asserted as a property of the seam; it is stated as work
T4 owns, with that call site named as the known hoist.

**AC status after this revision.** AC1–AC7 PASS (AC2 was the review's PARTIAL
and is closed by F10's three-state statement in §4; AC7 re-proved below).
**AC8 remains FAIL and remains checkpoint-owned** — `git rev-parse
--abbrev-ref @{u}` still reports no upstream and `git ls-remote --heads origin
design/agent-node-output-contract` is still empty. This step is forbidden by
the shared-branch protocol from `git add`/`commit`/`push`. The checkpoint must
commit both documents and push the branch to `origin` with upstream tracking —
plain push, never force, never `main`.

**AC7 proof for this revision (working tree, uncommitted).**

```
$ git status --porcelain=v1
 M design-docs/specs/design-agent-node-output-contract.md
 M impl-plans/active/agent-node-output-contract.md
$ git status --porcelain=v1 | grep -cE '(Sources|Tests)/'
0
$ git diff --name-only ca1ce34..HEAD | grep -cE '^(Sources|Tests)/'
0
```

Two documentation paths, zero `Sources/` and zero `Tests/`. Unchecked-box
count stays 6, matching `impl-plans/README.md:46`. Nothing was built or tested:
a planning-only package has no code to compile.

### 2026-09-21 — Implementation and verification complete

T1–T6 are complete. The runtime now validates CLI-agent sandbox declarations,
requires producer schemas for payload-consuming templates and conditional
routing, keeps contract-less agent answers on a pure text path, defaults every
output-bearing node to two validation attempts, and rejects unresolved addon
payload templates before addon side effects. The shared template-reference
classifier is used by both validate-time and render-time enforcement. All old
public `renderJSONTemplates` call sites were converted; the lenient renderer is
private to `RielaAddonSupport`.

Verification on the final implementation tree:

- `arch -arm64 /bin/zsh -lc 'swift test'`: 2,392 XCTest cases, 2 skipped,
  0 failures; 17 Swift Testing cases, 0 failures (860.100 seconds).
- `RielaExampleParityTests.testMockScenarioExamplesRunThroughSwiftCLI`: all
  39 registered mock-scenario workflows passed.
- Top-level `.riela/workflows` and `examples` validation: 102 definitions,
  `FAILURES=0`.
- Direct required scenarios completed as
  `note-rag-retrieval-fusion-session-1` (8 executions) and
  `telegram-sdk-trio-chat-session-2` (10 executions); the latter persisted the
  `memory-save` record with absent optional event fields.
- Focused output-contract/addon suites passed; `renderJSONTemplates` has zero
  call sites outside its support target; JSON parsing, sandbox-declaration and
  conditional-schema sweeps are clean; `git diff --check` is clean.
- SwiftLint over 106 changed Swift paths reported zero serious findings (one
  pre-existing long embedded-shell fixture warning remains). No changed Swift
  file exceeds 1,000 lines.

T7/D4 remains intentionally excluded: the sibling `riela-packages` bundle
migration is not part of this repository work package.
