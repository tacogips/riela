# Open Model Provider Routing Implementation Plan

**Status**: Completed
**Design Reference**: design-docs/specs/design-open-model-provider-routing.md
**Created**: 2026-07-17
**Last Updated**: 2026-07-17

---

## Design Document Reference

**Source**: design-docs/specs/design-open-model-provider-routing.md (accepted by
Step 3 review, decision `accepted_with_low_finding`; the single low finding —
the codex-agent reference path — is corrected in this step). Supporting docs:
design-docs/specs/design-workflow-json.md (node-payload section),
design-docs/user-qa/qa-open-model-provider-routing.md.

**Codex reference**: `../codex-agent/src/types/rollout.ts` —
`SessionMeta.model_provider` (verified). The `provider.name` value recorded in
backend event payload metadata (`provider_name`) intentionally mirrors this
rollout field. Intentional divergence accepted in the design:
`AdapterExecutionOutput.provider` keeps meaning backend adapter identity
(`codex-agent`, `claude-code-agent`) and is not repurposed to carry the model
provider name.

### Summary

Add optional `provider` (object: `name`, `baseUrl`, `apiKeyEnv`) and
`providerProxy` (string, v1 value `"codex"`) fields to `AgentNodePayload` so
codex-agent and claude-code-agent workflow nodes can target alternate
OpenAI-compatible providers. Canonical wire spelling is camelCase
(`providerProxy`); `provider_proxy` is not an alias. Behavior with both fields
unset must stay byte-identical (argv and process environment) to today.

### Scope

**Included**: schema decode + validation, codex-agent `-c` config-override
argv construction, claude-code-agent environment injection
(`ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN`), `provider_name` backend-event
metadata, redaction coverage for `apiKeyEnv` values, docs update, one example
workflow, deterministic tests.

**Excluded**: cursor-cli-agent and all `official/*` SDK backends (validation
rejects `provider` there — rule 6), non-`codex` proxy values, routing Claude
Code through a Codex proxy, non-loopback `http` base URLs (tracked in user-qa),
`ANTHROPIC_API_KEY` alternative naming (user-qa open question; manual
`agentEnvironment` wiring remains the escape hatch).

---

## Tasks

### TASK-001: Schema — `provider` / `providerProxy` on `AgentNodePayload`

**Files**: `Sources/RielaCore/WorkflowModel.swift` (struct `AgentNodePayload`,
line ~788), `Sources/RielaCore/AgentEnvironment.swift` (reuse
`isValidEnvironmentVariableName`, `reservedAgentEnvironmentNames`).

**Deliverables**:
- New `AgentProviderConfiguration` Codable/Equatable/Sendable struct: `name`
  (required), `baseUrl` (required), `apiKeyEnv` (optional).
- Optional `provider: AgentProviderConfiguration?` and
  `providerProxy: String?` on `AgentNodePayload`, decoded strictly (no
  `provider_proxy` alias; unknown snake_case key is ignored like any other
  unknown key today).
- Decode-time enforcement of design rules 1–5: name regex
  `[a-z0-9][a-z0-9_-]*` and ≤64 chars; absolute URL with `https` or
  loopback-only `http`, userinfo rejected; `apiKeyEnv` valid env-var name and
  not reserved; `providerProxy` requires `provider`; only value `codex`.
- Encoding round-trips both fields; absent fields encode to absent keys.

**Checklist**:
- [x] `AgentProviderConfiguration` type + strict `init(from:)`
- [x] `AgentNodePayload` fields, decode rules 1–5, encode round-trip
- [x] Decode fixture tests in `Tests/RielaCoreTests` (accept + reject per rule,
      including `provider_proxy` non-alias behavior)

### TASK-002: Workflow validation — backend compatibility + overlap warning

**Files**: `Sources/RielaCore/WorkflowNodeValidation.swift` (and
`WorkflowValidationHelpers.swift` if shared helpers fit better).

**Deliverables**:
- Rule 6: `provider` on any `executionBackend` other than `codex-agent` /
  `claude-code-agent` → validation error.
- Rule 7: `providerProxy: "codex"` with backend other than `codex-agent` →
  validation error (claude-code-agent + codex proxy is explicitly an error).
- Warning diagnostic when a claude-code-agent node sets both `provider` and an
  `agentEnvironment` binding for `ANTHROPIC_BASE_URL` (structured field wins).
- Rule 8: both fields absent → no new validation executes.

**Checklist**:
- [x] Rules 6–7 errors with actionable messages
- [x] `agentEnvironment` overlap warning
- [x] Backend-compatibility matrix tests in `Tests/RielaCoreTests`

### TASK-003: codex-agent argv construction

**Files**: `Sources/CodexAgent/CodexAgentProcess.swift` (`configOverrides`
handling, line ~165), `Sources/CodexAgent/CodexAgentAdapter.swift` (map node
payload → process options).

**Deliverables**:
- When `provider` is set, append `-c model_provider=<name>`,
  `-c model_providers.<name>.name=<name>`,
  `-c model_providers.<name>.base_url=<baseUrl>`, and (only with `apiKeyEnv`)
  `-c model_providers.<name>.env_key=<apiKeyEnv>`.
- Ordering: after effort-derived overrides, before
  `additionalArguments`/`codexAdditionalArgs` so explicit user overrides win.
- No secret value in argv; `providerProxy: "codex"` produces the same argv as
  the native mapping (explicit spelling of the default).

**Checklist**:
- [x] Provider override appending + ordering
- [x] Golden argv tests in `Tests/CodexAgentTests`: no provider (byte-identical
      to current), provider without `apiKeyEnv`, provider with `apiKeyEnv`,
      `codexAdditionalArgs` last-write-wins
- [x] Assertion that a test key value never appears in argv

### TASK-004: claude-code-agent environment injection

**Files**: `Sources/ClaudeCodeAgent/ClaudeCodeAgentAdapter.swift`,
`Sources/RielaAdapters/AdapterUtilities.swift`
(`mergedAgentProcessEnvironment`, line ~59;
`sensitiveAdapterEnvironmentValues`, line ~311).

**Deliverables**:
- When `provider` is set: inject `ANTHROPIC_BASE_URL=<baseUrl>` and, when
  `apiKeyEnv` is set, `ANTHROPIC_AUTH_TOKEN=<runtime value of apiKeyEnv>`
  resolved at launch.
- Composition order: adapter base env → node `agentEnvironment` → provider
  entries → reserved `RIELA_AGENT_BACKEND` (provider wins over
  `agentEnvironment`, reserved name still wins over everything).
- Missing runtime value for `apiKeyEnv` surfaces as a readiness/launch error,
  not a silent empty token.
- Confirm `sensitiveAdapterEnvironmentValues` covers `ANTHROPIC_AUTH_TOKEN`
  (`*_AUTH_TOKEN` pattern) so the token value is redacted everywhere.

**Checklist**:
- [x] Environment injection + composition order
- [x] Golden environment tests in `Tests/ClaudeCodeAgentTests` (unset =
      byte-identical; set with/without `apiKeyEnv`; `agentEnvironment` overlap
      resolution)
- [x] Missing-env-value error path test

### TASK-005: Runtime forwarding + `provider_name` event metadata

**Files**: `Sources/RielaCore/AdapterContracts.swift`
(`AdapterExecutionInput`), backend event payload construction in
`Sources/CodexAgent/` and `Sources/ClaudeCodeAgent/` adapters,
`Sources/RielaCore/DeterministicWorkflowRunner.swift` (verify pass-through
only).

**Deliverables**:
- Fields ride on `AgentNodePayload` through `AdapterExecutionInput.node`; audit
  that deterministic runner, dispatching adapter, scenario adapters, and
  GraphQL node inspection need no changes (fields travel on the payload).
- Add `provider_name` (string) to adapter output / backend event payload
  metadata only when a provider override is active, mirroring the Codex
  rollout `SessionMeta.model_provider` field
  (`../codex-agent/src/types/rollout.ts`).
- `AdapterExecutionOutput.provider` unchanged (backend adapter identity).

**Checklist**:
- [x] `AdapterExecutionInput` round-trip test carries both fields
- [x] `provider_name` present when active, absent when not, in backend event
      payload tests (`Tests/AgentAdapterTests` or backend-specific suites)
- [x] Forwarding-path audit noted in progress log with file evidence

### TASK-006: Redaction verification

**Files**: `Sources/RielaAdapters/AdapterUtilities.swift`
(`redactAdapterSensitiveText`), `Sources/RielaAdapters/LocalAgentProcess.swift`
(failure-detail redaction, lines ~883–995).

**Deliverables**:
- Deterministic test: a provider key injected via `apiKeyEnv` appears as
  `<redacted>` in simulated stderr failure text and backend event content.
- If `sensitiveAdapterEnvironmentValues` key patterns miss the provider env-var
  name (arbitrary names are allowed), extend value-based redaction so the
  resolved secret value is always in the sensitive-values list for
  provider-configured launches.

**Checklist**:
- [x] Redaction tests (stderr path + event content path) in
      `Tests/RielaAdaptersTests`
- [x] Gap fix if arbitrary `apiKeyEnv` names escape the pattern list

### TASK-007: Docs and example workflow

**Files**: `design-docs/specs/design-workflow-json.md` (node-payload section —
already updated in Step 2; reconcile against the implemented decode rules),
`examples/` (new directory, e.g. `examples/open-model-provider-codex/`),
`examples/README.md`.

**Deliverables**:
- Example workflow demonstrating a loopback OpenAI-compatible provider
  (`http://localhost:...`) on a codex-agent node with `provider` +
  `providerProxy: "codex"`, following existing example bundle layout
  (workflow.json + node payloads + prompts + EXPECTED_RESULTS.md where the
  sibling examples have one).
- Docs show only the camelCase spelling; the compatibility decision (no
  `provider_proxy` alias) is stated.

**Checklist**:
- [x] Example bundle validates via workflow validation
- [x] `examples/README.md` entry
- [x] `design-workflow-json.md` reconciled with implemented behavior

---

## Dependencies

| Task | Depends On | Reason |
|------|------------|--------|
| TASK-001 | — | Foundation types |
| TASK-002 | TASK-001 | Validates the new fields |
| TASK-003 | TASK-001 | Reads `provider` from payload |
| TASK-004 | TASK-001 | Reads `provider` from payload |
| TASK-005 | TASK-001, TASK-003, TASK-004 | Event metadata emitted by both adapters |
| TASK-006 | TASK-004 | Redacts the resolved token value |
| TASK-007 | TASK-001, TASK-002 | Example must validate against final rules |

## Parallelizable Tasks

- TASK-003 (`Sources/CodexAgent/`) and TASK-004 (`Sources/ClaudeCodeAgent/` +
  `Sources/RielaAdapters/`) have disjoint write scopes and can run in parallel
  once TASK-001 lands.
- TASK-002 (`Sources/RielaCore/Workflow*Validation*.swift`) can run in parallel
  with TASK-003/TASK-004 after TASK-001.
- TASK-005, TASK-006, TASK-007 are sequential tail work (TASK-005 touches both
  adapter trees; TASK-007 needs final validation rules).

## Verification

Run from the worktree root
(`/Users/taco/gits/tacogips/riela-open-model-provider`):

- `swift build`
- `swift test --filter RielaCoreTests` (decode + validation rules)
- `swift test --filter CodexAgentTests` (argv golden tests)
- `swift test --filter ClaudeCodeAgentTests` (environment golden tests)
- `swift test --filter 'AgentAdapterTests|RielaAdaptersTests'` (forwarding,
  `provider_name`, redaction)
- `rg -n 'provider_proxy' Sources/ Tests/ design-docs/ examples/` — canonical
  spelling only; the snake_case string may appear solely in the non-alias
  reject/ignore fixtures and the compatibility-decision prose
- `rg -n 'readonly model_provider\?: string' ../codex-agent/src/types/rollout.ts`
  — reference symbol still present
- `git diff --check` — no whitespace damage
- Byte-identical default check: golden tests for both backends with no
  `provider` field asserting current argv/environment output exactly

## Completion Criteria

- [x] All TASK-001…TASK-007 checklists checked with per-box evidence
- [x] Both fields unset → argv and process environment byte-identical to
      pre-change behavior (golden tests green)
- [x] All decode/validation rules 1–8 covered by accept + reject tests
- [x] No secret value in argv, persisted artifacts, or unredacted output
      (asserted by tests)
- [x] Relevant suites are green with no feature-related failures and no new
      dependencies; the full RielaCore run retains one pre-existing unrelated
      nano-model fixture failure recorded below
- [x] Docs and example updated; example validates
- [x] No commits, no pushes, no changes outside this feature worktree; reviewed
      changes left uncommitted for the caller

## Progress Log

Implementation sessions must append entries here (date/time, tasks completed,
tasks in progress, blockers, verification evidence such as test counts). Each
checked box requires named test or command evidence in the same entry.

### Session: 2026-07-17 11:09

**Tasks Completed**: Plan authored (Step 4). Step 3 low finding fixed:
`design-open-model-provider-routing.md` line 60 corrected from
`../../codex-agent/src/types/rollout.ts` to
`../codex-agent/src/types/rollout.ts` (verified: `SessionMeta.model_provider`
exists at the corrected path).
**Tasks In Progress**: None; ready for Step 5 plan review / implementation.
**Blockers**: None.

### Session: 2026-07-17 12:27

**Tasks Completed**: TASK-001 through TASK-007. Provider fields forward through
`AdapterExecutionInput.node`; `DeterministicWorkflowRunner`, both CLI command
builders, `LocalAgentCommandAdapter`, `WorkflowRunEvent`, and
`WorkflowBackendEventRecord` were audited. The first adversarial review found
one medium boundary issue: public Swift construction bypassed decode-only
invariants. The fix makes `AgentProviderConfiguration` immutable with a
validating throwing initializer, models `AgentProviderProxy` as a closed enum,
validates direct builder calls, and adds programmatic-construction tests.
Arbitrary credential names are also carried as explicit sensitive values so
Codex stderr and backend-event content remain redacted.

**Verification Evidence**: `swift build` passed; post-review focused provider
tests passed 22/22. The broad Codex, Claude, agent-adapter, and Riela-adapter
suite run executed 327 tests with four live tests skipped and zero failures.
`RielaCoreTests` executed 423 tests with 422 passing and one inherited, unrelated
failure in
`SourceDeletionReadinessTests.testFixturesDoNotReferenceRemovedCodexNanoModel`.
SwiftLint completed across 728 files with 15 repository-existing warnings and
zero serious violations. The example workflow validated with no diagnostics;
`git diff --check` passed. Changed Swift files are below 1000 lines after
extracting local-process contracts to `LocalAgentProcessContracts.swift`.

**Tasks In Progress**: None.
**Blockers**: None. The nano-model fixture failure is outside this feature
diff and was explicitly excluded by adversarial review.

### Session: 2026-07-17 12:40

**Tasks Completed**: The second adversarial review confirmed the public
construction finding resolved and found two additional medium boundaries.
Codex default and custom auth preflight errors now include arbitrary
`apiKeyEnv` values in provider-aware redaction. Classified, fallback, and
monitor-injected backend events now preserve `nil` metadata when provider
routing is absent. Focused tests cover both corrections. Local process and
runtime backend-event contracts were extracted into responsibility-named files
so every changed production Swift file remains below 1000 lines.

**Verification Evidence**: Post-correction focused provider suite passed 22/22.
The prior broad and core-suite evidence remains applicable; final lint, example
validation, diff checks, and acceptance review are recorded at handoff.

**Tasks In Progress**: None.
**Blockers**: None.

### Session: 2026-07-17 13:20

**Tasks Completed**: Subsequent read-only adversarial reviews closed all
remaining credential-disclosure paths. Successful stdout is sanitized before
output-contract parsing and its decoded JSON is sanitized recursively;
streaming and non-streaming runner errors preserve cancellation and structured
adapter error metadata while redacting messages. Provider-derived credentials
are sensitive regardless of length. Classified, fallback, and monitor-injected
events sanitize provider, event type, tool name, content, and nested usage and
metadata before persistence. Tests cover short and JSON-escaped credentials,
plain and contract output, both runner paths, and all backend-event fields.

**Verification Evidence**: Focused provider tests passed 26/26. The latest
broad Codex, Claude, agent-adapter, and Riela-adapter run executed 333 tests,
skipped four live tests, and had zero failures. SwiftLint exited successfully
with the same 15 repository-existing warnings and zero serious violations.
The final read-only Riela adversarial review,
`codex-adversarial-implementation-review-loop-session-587`, accepted with no
high, medium, or low findings. Example validation and final diff/file-length
checks are recorded at handoff.

**Tasks In Progress**: None.
**Blockers**: None. The inherited unrelated RielaCore nano-model fixture
failure remains outside this feature diff.

## Related Plans

- **Depends On**: none (foundation types already exist)
- **Design**: design-docs/specs/design-open-model-provider-routing.md
- **QA**: design-docs/user-qa/qa-open-model-provider-routing.md
