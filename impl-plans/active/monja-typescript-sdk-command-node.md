# Monja TypeScript SDK Command Node Interoperability — Implementation Plan

**Status**: COMPLETED
**Workflow Mode**: `design-plan-only`
**Workflow Execution**: `codex-design-and-implement-review-loop-session-4`
**Issue Reference**:
`local-request:/Users/taco/gits/tacogips/riela:Use the Monja TypeScript SDK from Riela command nodes`
**Design Reference**:
`design-docs/specs/design-monja-typescript-sdk-command-node.md#acceptance-mapping`
**Operator-QA Reference**:
`design-docs/user-qa/qa-monja-typescript-sdk-command-node.md`
**Step 3 Decision**: `accepted_for_implementation_planning` in `comm-000023`
**Latest Step 5 Decision**: `accepted_for_planning_only_completion` in
`comm-000028`; no findings remained after the T1/T7/T9 verification revisions
**Created**: 2026-09-06
**Commit Authorized**: No
**Push Authorized**: No

## Objective And Accepted Boundary

Implement the smallest portable Riela example that proves a Node ESM command
can import the locally packed `@monja/client` package by name, consume Riela's
single-record JSONL invocation, call typed REST `client.core.me()`, and execute
a caller-supplied GraphQL document through `client.graphql.executeStrict`.

The accepted design is the source of truth. The deterministic gate uses an
isolated generated consumer under Riela's gitignored `tmp/` root and a
loopback-only mock. Live Monja deployment, server lifecycle, migrations, seed
data, API-key issuance, and mutation approval remain operator-owned and cannot
be claimed by the deterministic result.

This work package must not publish packages, vendor generated output, introduce
a Cursor/Codex adapter, clean either worktree, or commit/push. Riela or Monja
production code may change only after a reproducible packed-consumer or runtime
failure proves that the example alone cannot satisfy the accepted contract.

## Traceability

The implementation must retain these accepted inputs:

- `comm-000014`: explicit workflow-to-node-file-to-script linkage and exact
  loopback-only plaintext policy.
- `comm-000017`: pure pre-network URL-policy verification, with network success
  required only for `127.0.0.1`.
- `comm-000020`: generated private ESM consumer, pinned TypeScript 5.7.2 and
  `@types/node` 20.12.14, exact strict NodeNext configuration, and isolated
  installed-package resolution proof.
- `comm-000022`: revised design submitted for final review.
- `comm-000023`: design accepted with no findings; packed-package, Node ESM,
  Riela JSONL, typed REST, arbitrary GraphQL, environment-only authentication,
  deterministic verification, dirty-worktree preservation, scope boundaries,
  URL policy, network sequence, and evidence-gated change policy were all
  accepted for implementation planning.
- `comm-000026`: required unconditional exact-path formatting and Biome warning
  gates for the Riela TypeScript example, an explicit
  `check-and-test-after-modify` invocation, a recorded `ts-review` decision,
  and the anchored acceptance-mapping design reference.

Codex-agent references resolve from `/Users/taco/gits/tacogips/monja`:

- `.agents/agents/ts-coding.md`: any TypeScript implementation assignment must
  include Purpose, Reference Document, Implementation Target, and Completion
  Criteria, and must perform the implementation directly.
- `.agents/agents/check-and-test-after-modify.md`: after any TypeScript change,
  provide the modification summary, modified package/layer, modified files,
  and custom gates; run Biome, typecheck, and relevant tests and preserve full
  failure output.
- `.agents/skills/ts-coding-standards/SKILL.md`: use strict types, `unknown`
  narrowing, readonly data, explicit optional/index checks, bounded files,
  formatting, and credential/path hygiene; do not weaken lint or type rules.
- `.agents/skills/ts-review/SKILL.md`: perform a final TypeScript review after
  automated checks, including public API, ESM imports, security, tests, file
  size, and warning review.

There is no Cursor behavior dependency and no accepted divergence from Cursor
behavior. The only intentional boundary is that the example records the tested
Node version and required runtime capabilities without changing or claiming a
formal Monja package `engines` range.

## Planned File Allowlist

Unconditional Riela deliverables:

- `examples/monja-typescript-sdk/workflow.json`
- `examples/monja-typescript-sdk/nodes/node-monja-command.json`
- `examples/monja-typescript-sdk/nodes/monja-command.ts`
- `examples/monja-typescript-sdk/nodes/monja-url-policy.ts`
- `examples/monja-typescript-sdk/scripts/prepare.sh`
- `examples/monja-typescript-sdk/scripts/run-installed-command.sh`
- `examples/monja-typescript-sdk/scripts/mock-server.mjs`
- `examples/monja-typescript-sdk/scripts/verify-url-policy.mjs`
- `examples/monja-typescript-sdk/scripts/verify.sh`
- `examples/monja-typescript-sdk/README.md`
- `examples/monja-typescript-sdk/EXPECTED_RESULTS.md`
- `impl-plans/active/monja-typescript-sdk-command-node.md` for progress updates
- `examples/README.md` only if the existing example index requires registration
- directly affected repository-facing `README.md` content only if the existing
  documentation structure requires a top-level reference

Conditional Riela defect scope, allowed only by Task T7 evidence:

- `Sources/RielaAdapters/WorkflowStdioNodeExecutor.swift`
- `Sources/RielaCore/WorkflowStdioNodeExecution.swift` only if the proven defect
  is in the shared execution contract rather than the adapter implementation
- `Tests/RielaAdaptersTests/WorkflowStdioNodeExecutorTests.swift`

Conditional Monja defect scope, allowed only by Task T8 evidence:

- `packages/client-typescript/package.json`
- the minimum failing file below `packages/client-typescript/src/`
- the directly corresponding file below `packages/client-typescript/test/`
- package-local configuration only when the failure proves that configuration
  is the owning defect

Do not broaden either conditional allowlist merely because adjacent dirty files
exist. Any needed file outside these lists requires a progress-log entry that
records the failing gate, ownership reasoning, and revised bounded scope before
the file is edited.

## Dependency Graph

```text
T0 baseline and evidence root
  +--> T1 command source and URL policy -----+
  +--> T2 workflow/node/runtime launcher ----+--> T5 integrated verifier
  +--> T3 packed ESM consumer preparation ---+          |
  +--> T4 loopback mock/policy verifier -----+          v
                                                  T6 documentation
                                                        |
                                                        v
                                                  T7 full gates/triage
                                                        |
                                    +-------------------+-------------------+
                                    |                                       |
                              T8R conditional Riela fix               T8M conditional Monja fix
                                    +-------------------+-------------------+
                                                        |
                                                        v
                                                  T7 gate rerun
                                                        |
                                                        v
                                                  T9 review/handoff
```

T1, T2, T3, and T4 are the only planned parallel implementation group. They
may start after T0 because their write scopes are file-disjoint and the accepted
design freezes their interfaces. T5 through T9 are serial integration tasks.
T8R and T8M may run in parallel only if T7 proves independent defects in both
repositories and their bounded write scopes remain disjoint.

## Task Breakdown

### T0 — Baseline, Instructions, And Evidence Root

**Deliverables**:

- Record `git status --short`, scoped diffs for overlapping files, tool
  versions, and the current Monja package manifest under a unique
  `tmp/monja-typescript-sdk/<run-id>/evidence/` directory.
- Record the exact Riela and Monja commit identifiers without staging,
  cleaning, resetting, or modifying unrelated files.
- Read the accepted design, operator QA, all four Codex-agent references, and
  the linked TypeScript standard topics required for error handling, types,
  layout, async behavior, and security before TypeScript implementation.
- Establish one explicit implementation allowlist and tag each existing dirty
  path as pre-existing evidence; never copy secret values into the record.
- Confirm `tmp/` is ignored and every generated manifest, lockfile, tarball,
  installed dependency, compiled output, server handoff, and command log stays
  below it.

**Dependencies**: accepted Step 3 decision `comm-000023`.

**Verification**:

```bash
git -C /Users/taco/gits/tacogips/riela status --short
git -C /Users/taco/gits/tacogips/monja status --short
git -C /Users/taco/gits/tacogips/riela check-ignore tmp
test -f /Users/taco/gits/tacogips/monja/packages/client-typescript/package.json
test -f /Users/taco/gits/tacogips/monja/.agents/agents/ts-coding.md
test -f /Users/taco/gits/tacogips/monja/.agents/agents/check-and-test-after-modify.md
test -f /Users/taco/gits/tacogips/monja/.agents/skills/ts-coding-standards/SKILL.md
test -f /Users/taco/gits/tacogips/monja/.agents/skills/ts-review/SKILL.md
```

### T1 — Implement The Strict JSONL Command And Pure URL Policy

**Write scope**:

- `examples/monja-typescript-sdk/nodes/monja-command.ts`
- `examples/monja-typescript-sdk/nodes/monja-url-policy.ts`

**Deliverables**:

- Use the bare ESM import from `@monja/client`; never import Monja source,
  workspace paths, machine paths, import-map aliases, or a `file:` dependency.
- Parse stdin once to EOF with the accepted 1,048,576-byte limit; require one
  nonblank JSON object record and reject extra nonblank records.
- Read only `variables.workflowInput.graphql`; validate the required query,
  optional operation name, optional object variables, 65,536-byte query limit,
  and 262,144-byte serialized-variable limit before any network call. Ignore
  `_rielaInput` metadata when selecting the operation, and never reinterpret
  invocation values as argv or environment-variable names.
- Use `.js` specifiers for internal relative TypeScript imports so NodeNext
  emit is directly executable as ESM.
- Parse `MONJA_BASE_URL`, require `MONJA_API_KEY`, and bound
  `MONJA_REQUEST_TIMEOUT_MS` to `1...60000` with a 15,000 ms default. Keep all
  credentials out of argv, stdout, and diagnostics.
- Implement the pure URL-policy seam before client construction: HTTPS is
  secure-only; HTTP is permitted only for exact normalized `localhost`,
  `127.0.0.1`, and `[::1]`; reject userinfo, query, fragment, other schemes,
  loopback lookalikes, and non-loopback HTTP with stable safe categories.
- Construct the API-key client with the derived `allowInsecureLocalhost`, an
  explicit 1,048,576-byte SDK response limit, and one abort deadline spanning
  the sequential `core.me()`, capability check, and strict GraphQL execution.
- Emit exactly one newline-terminated success object with `status`, safe `rest`
  identity data, and caller-requested `graphql` data, after enforcing the final
  1,048,576-byte serialized-output bound.
- On failure, emit no stdout record and one bounded stderr classification that
  contains stage plus safe kind/status only; omit raw error messages, URLs,
  headers, bodies, query, variables, invocation, environment, and credential
  metadata.

**Dependencies**: T0.

**Unconditional TypeScript workflow**:

- Supply `.agents/agents/ts-coding.md` with Purpose (prove Riela/Monja SDK
  interoperability), Reference Document (the anchored accepted design),
  Implementation Target (the two exact T1 files), and this plan's Completion
  Criteria before implementation.
- After modifying either T1 file and before T3 consumer typecheck or T5
  verification, run the exact-path format command and then the exact-path Biome
  warning gate below. Record all warning diagnostics; do not weaken or bypass
  Monja's Biome configuration.
- After T5 exists, invoke
  `.agents/agents/check-and-test-after-modify.md` with this explicit context:
  Modification Summary: strict Riela JSONL command and pure Monja URL policy;
  Modified Packages/Layers: Riela example layer; Modified Files:
  `examples/monja-typescript-sdk/nodes/monja-command.ts` and
  `examples/monja-typescript-sdk/nodes/monja-url-policy.ts`; Custom Test
  Instructions: run the exact-path format and Biome commands below, then
  `bash examples/monja-typescript-sdk/scripts/verify.sh`, retaining complete
  failure output and a concise pass report.

**Task-specific verification**:

```bash
cd /Users/taco/gits/tacogips/monja && bunx --no-install biome format --write --config-path biome.json /Users/taco/gits/tacogips/riela/examples/monja-typescript-sdk/nodes/monja-command.ts /Users/taco/gits/tacogips/riela/examples/monja-typescript-sdk/nodes/monja-url-policy.ts
cd /Users/taco/gits/tacogips/monja && bunx --no-install biome check --diagnostic-level=warn --config-path biome.json /Users/taco/gits/tacogips/riela/examples/monja-typescript-sdk/nodes/monja-command.ts /Users/taco/gits/tacogips/riela/examples/monja-typescript-sdk/nodes/monja-url-policy.ts
```

The isolated compiler in T3 must then typecheck and emit both files without
`any`, CommonJS syntax, source-relative Monja imports, or machine-specific
paths.

### T2 — Add Workflow, Node Payload, And Fixed Runtime Launcher

**Write scope**:

- `examples/monja-typescript-sdk/workflow.json`
- `examples/monja-typescript-sdk/nodes/node-monja-command.json`
- `examples/monja-typescript-sdk/scripts/run-installed-command.sh`

**Deliverables**:

- Add a manager-less workflow with `entryStepId: "monja-command"`, one node
  file reference `nodes/node-monja-command.json`, one terminal worker step with
  `nodeId: "monja-command"`, and `defaults.nodeTimeoutMs: 90000`.
- Define the `AgentNodePayload` command with id `monja-command`, node type
  `command`, script `scripts/run-installed-command.sh`, empty arguments and
  environment maps, and working directory `scripts`; document the accepted
  input and output contracts in the payload without placing data in argv.
- Make the launcher derive the Riela repository root from its own location,
  accept no credential arguments, and execute compiled JavaScript only from
  `MONJA_EXAMPLE_RUNTIME_DIR` after canonical containment validation beneath
  Riela `tmp/`.
- Use the documented single-run runtime directory below
  `tmp/monja-typescript-sdk/` only for a direct operator prepare/run when
  `MONJA_EXAMPLE_RUNTIME_DIR` is absent. Deterministic verification must always
  set a unique per-run directory explicitly; `prepare.sh` and the launcher must
  resolve the same canonical value.
- Fail before Node starts when the runtime directory is missing, not a
  directory, symlink-escaping, or outside `tmp/`; use the same canonical
  runtime value as `prepare.sh`.

**Dependencies**: T0.

**Task-specific completion check**: workflow validation resolves the node file,
fixed command, empty argv/environment, working directory, and terminal step.

### T3 — Build, Pack, Inspect, And Prepare An Isolated ESM Consumer

**Write scope**:

- `examples/monja-typescript-sdk/scripts/prepare.sh`

**Deliverables**:

- Resolve both repository roots without embedding machine paths; build,
  typecheck, and test `packages/client-typescript` before every pack.
- Use `npm pack --json --pack-destination` and consume the reported tarball
  path rather than guessing the filename.
- Reject wrong package name/version, missing `dist/index.js`, missing
  `dist/index.d.ts`, missing package manifest, any `package/src/` member,
  repository escape, or workspace-only dependency; record checksum and safe
  file inventory under the run evidence directory.
- Generate only under the runtime directory a consumer manifest with
  `name: "riela-monja-typescript-sdk-consumer"`, `private: true`,
  `type: "module"`, exact dependency
  `"@monja/client": "file:<canonical-reported-tarball-path>"`, and exact
  development dependencies `"typescript": "5.7.2"` and
  `"@types/node": "20.12.14"`.
- Generate a standalone `tsconfig.json` with `target: "ES2022"`,
  `module: "NodeNext"`, `moduleResolution: "NodeNext"`,
  `lib: ["ES2022", "DOM", "DOM.Iterable"]`, `types: ["node"]`,
  `rootDir: "src"`, `outDir: "dist"`, `strict: true`,
  `exactOptionalPropertyTypes: true`, `noUncheckedIndexedAccess: true`,
  `useUnknownInCatchVariables: true`, `verbatimModuleSyntax: true`,
  `forceConsistentCasingInFileNames: true`, `noEmitOnError: true`,
  `skipLibCheck: false`, emit enabled, and only `src/**/*.ts` included. Do not
  use `extends` or inherit Riela or Monja compiler settings.
- Run
  `npm install --ignore-scripts --no-audit --no-fund --package-lock=true` from
  the consumer; verify the generated lockfile, exact top-level installed
  versions, and that compiler and Node typings resolve from the consumer's own
  `node_modules`.
- Copy committed command source into consumer `src/`, use only its local
  compiler to typecheck and emit, verify bare package imports remain, reject
  CommonJS output, and require `import.meta.resolve("@monja/client")` to equal
  the real installed `dist/index.js` path.
- Check Node ESM and `globalThis.fetch` capabilities and record the exact Node
  version as evidence without changing Monja's `engines` declaration.

**Dependencies**: T0; T1 source is required for the final task check but the
script can be authored in parallel against the frozen paths and config.

**Task-specific completion check**: a fresh generated consumer can install,
typecheck, emit, resolve, and load only the packed artifact.

### T4 — Implement The Loopback Mock And Pure Policy Verifier

**Write scope**:

- `examples/monja-typescript-sdk/scripts/mock-server.mjs`
- `examples/monja-typescript-sdk/scripts/verify-url-policy.mjs`

**Deliverables**:

- Bind the mock only to `127.0.0.1` on an OS-selected port; communicate its URL
  privately below the runtime directory and never print the generated token.
- Accept exactly the authenticated ordered sequence `GET /api/v1/auth/me`,
  `GET /api/v1/server-capabilities`, and `POST /api/v1/graphql`; reject extra,
  reordered, unauthenticated, malformed, or unexpected requests.
- Return SDK-valid principal, capability grammar, supported event protocol,
  and deterministic GraphQL `me` data; provide controlled REST, capability,
  GraphQL, timeout, and oversized-response failure modes without logging
  secrets or request bodies.
- Import the compiled URL-policy seam and assert HTTPS behavior, the three
  exact loopback HTTP hosts, loopback lookalikes, non-loopback HTTP, other
  schemes, userinfo, query, and fragment without starting a listener or
  invoking fetch.

**Dependencies**: T0; T1 compiled output is required for the policy verifier's
execution but the scripts can be authored in parallel against its frozen API.

**Task-specific completion check**: safe request metadata proves the exact
three-request happy path and the policy matrix remains network-free.

### T5 — Integrate Deterministic Verification Through Riela

**Write scope**:

- `examples/monja-typescript-sdk/scripts/verify.sh`

**Deliverables**:

- Allocate one unique canonical runtime directory under
  `tmp/monja-typescript-sdk/`, invoke T3 preparation, start and reliably stop
  the T4 mock, and run the compiled T1 command through the actual T2 Riela
  workflow boundary.
- Generate an ephemeral unpredictable API token at runtime, pass it only via
  process environments, disable shell tracing, and scan stdout, stderr, Riela
  JSON output, error evidence, and argv evidence for the token.
- Prove the success path produces exactly one accepted object record and the
  REST/capability/GraphQL sequence uses installed `@monja/client` code.
- Prove empty input, multiple records, non-object JSON, missing environment,
  invalid URL policy, REST failure, disabled GraphQL capability, GraphQL
  failure, timeout, oversized input, and oversized output produce no stdout
  object and only bounded safe stderr.
- Assert workflow/node/script linkage, empty authored argv/environment, package
  inventory, pinned tooling, exact generated compiler config, bare ESM emit,
  installed resolution, URL-policy matrix, the `127.0.0.1` transport case, and
  containment of every scratch artifact.
- Preserve evidence for diagnosis during the run, write stable pass/fail
  summaries without secrets, terminate child processes on every exit path, and
  remove throwaway state when the task finishes. Keep only evidence explicitly
  needed for the implementation review, below `tmp/` and never staged.

**Dependencies**: T1, T2, T3, and T4.

**Task-specific completion check**:

```bash
bash examples/monja-typescript-sdk/scripts/verify.sh
```

### T6 — Document Setup, Contracts, Expected Results, And Live Boundary

**Write scope**:

- `examples/monja-typescript-sdk/README.md`
- `examples/monja-typescript-sdk/EXPECTED_RESULTS.md`
- `examples/README.md` only if required by the existing index
- directly affected root `README.md` content only if required by repository
  navigation

**Deliverables**:

- Document build/pack/prepare/run steps, generated private ESM metadata,
  pinned tools, strict NodeNext proof, workflow-to-node-to-script chain,
  `variables.workflowInput.graphql` input, output shape, request order, limits,
  failure classifications, and the fact that all generated state is under
  `tmp/`.
- Document environment-only `MONJA_BASE_URL`, `MONJA_API_KEY`, optional timeout,
  HTTPS default, exact loopback-only HTTP exception, and the difference between
  policy classification and the sole `127.0.0.1` end-to-end transport case.
- Use the read-only schema-backed `RielaSdkProbe` query for portable/live
  instructions while explaining that arbitrary documents, including mutations,
  use the same input contract and require operator approval for live use.
- Document live prerequisites and explicitly state that server start,
  migrations, seed, API-key issuance, secret storage, mutation cleanup, remote
  TLS policy, and formal Node support remain unresolved in the operator-QA file.
- Describe expected stable shapes and evidence categories without committing
  tokens, live server data, tarballs, lockfiles, paths, or captured logs.

**Dependencies**: T5 behavior and evidence shape are stable.

**Task-specific completion check**: every command in the README is either
exercised by T7 or clearly labeled optional/operator-owned.

### T7 — Run Accepted Gates And Classify Failures

**Deliverables**:

- Execute the accepted gates in order and record exact command, exit status,
  relevant non-secret output, date, tool versions, and evidence path in the
  plan's progress log.
- Compare final status and scoped diffs with the T0 baseline in both
  repositories; distinguish pre-existing dirty state from work-package changes.
- Classify each failure as example/harness-owned, environment-owned, pre-existing,
  Riela-owned, or Monja-owned. Fix example/harness failures inside T1-T6 first.
- Enter T8R or T8M only when a minimal reproducible failure proves an owning
  production defect. Otherwise mark each conditional task `NOT_REQUIRED` with
  the evidence that kept scope narrow.
- Unconditionally invoke
  `.agents/agents/check-and-test-after-modify.md` with the T1 modification
  summary, `Riela example layer`,
  `examples/monja-typescript-sdk/nodes/monja-command.ts`,
  `examples/monja-typescript-sdk/nodes/monja-url-policy.ts`, and the custom
  format/Biome/verify gates stated in T1. Record its pass/fail decision and
  full failure-output evidence before accepting T7.

**Dependencies**: T5 and T6.

**Verification**:

```bash
cd /Users/taco/gits/tacogips/monja && bunx --no-install biome format --write --config-path biome.json /Users/taco/gits/tacogips/riela/examples/monja-typescript-sdk/nodes/monja-command.ts /Users/taco/gits/tacogips/riela/examples/monja-typescript-sdk/nodes/monja-url-policy.ts
cd /Users/taco/gits/tacogips/monja && bunx --no-install biome check --diagnostic-level=warn --config-path biome.json /Users/taco/gits/tacogips/riela/examples/monja-typescript-sdk/nodes/monja-command.ts /Users/taco/gits/tacogips/riela/examples/monja-typescript-sdk/nodes/monja-url-policy.ts
cd /Users/taco/gits/tacogips/monja && bun run --cwd packages/client-typescript build && bun run --cwd packages/client-typescript typecheck && bun run --cwd packages/client-typescript test
bash examples/monja-typescript-sdk/scripts/verify.sh
swift run riela workflow validate monja-typescript-sdk --workflow-definition-dir ./examples --output json
swift test --filter WorkflowStdioNodeExecutorTests
git -C /Users/taco/gits/tacogips/riela diff --check
git -C /Users/taco/gits/tacogips/monja diff --check
```

### T8R — Conditionally Fix A Proven Riela JSONL Executor Defect

**Entry condition**: T7 reproduces incompatibility between a correctly behaving
installed command and the accepted Riela JSONL contract.

**Deliverables**:

- Preserve the existing one-envelope-plus-newline stdin and empty-or-one-object
  stdout contract; do not weaken rejection of invalid JSON, multiple records,
  or non-object output.
- Apply the smallest owning fix in the conditional Riela allowlist and add a
  focused regression to `WorkflowStdioNodeExecutorTests`.
- Run Swift format/lint expectations applicable to the touched code, the
  focused executor tests, the deterministic example verifier, workflow
  validation, and Riela `diff --check`.
- If no Riela defect is proven, record `NOT_REQUIRED`; do not make speculative
  executor changes.

**Dependencies**: T7 failure evidence.

### T8M — Conditionally Fix A Proven Monja Package Or SDK Defect

**Entry condition**: T7 proves that a freshly built packed tarball cannot be
installed, imported, typed, or executed under the accepted consumer contract.

**Deliverables**:

- Supply the TypeScript coding assignment with explicit Purpose, accepted
  design reference, exact package/file target, and the completion criteria from
  this plan.
- Apply only the minimum owning package/export/build/SDK fix and a focused
  package test; preserve every unrelated pre-existing Monja change.
- Follow all linked TypeScript standards, including error/security topics,
  strict typing, bounded async work, formatting, and file-size review.
- Invoke the post-modification verification reference with modification
  summary, package, files, and custom gates; preserve complete failure output.
- Run the TypeScript review checklist after automation. Do not weaken Biome,
  TypeScript, test, or package rules and do not add a package `engines` range
  without a separate support decision and minimum-version evidence.
- If no Monja defect is proven, record `NOT_REQUIRED`; do not touch Monja.

**Dependencies**: T7 failure evidence.

**Additional verification when entered**:

```bash
cd /Users/taco/gits/tacogips/monja && biome check . --diagnostic-level=warn
cd /Users/taco/gits/tacogips/monja && biome format --write <each-exact-T8M-modified-path>
cd /Users/taco/gits/tacogips/monja && bun run typecheck
cd /Users/taco/gits/tacogips/monja && bun run test
cd /Users/taco/gits/tacogips/monja && bun run --cwd packages/client-typescript build && bun run --cwd packages/client-typescript typecheck && bun run --cwd packages/client-typescript test
git -C /Users/taco/gits/tacogips/monja diff --check
```

Replace the format placeholder with the ordered explicit T8M file list and
record the expanded command in the progress log. Do not run Monja's repo-wide
`bun run format` in the dirty worktree.

### T9 — Final Review, Documentation Refresh, And Handoff

**Deliverables**:

- Rerun T7 after every T8 change and require the final run to use a fresh
  consumer and fresh mock runtime.
- Review all new TypeScript and JavaScript against the Codex references, verify
  no file exceeds applicable size expectations, and confirm no shell command
  can expose credentials through tracing, argv, diagnostics, or captured
  output.
- Apply `.agents/skills/ts-review/SKILL.md` to the two exact T1 files after the
  final automated gates. Record an explicit `Pass` or `Issues` decision with
  path-specific findings covering strict typing, Result/error handling, ESM
  imports, module boundaries, file size, security, warnings, and test coverage.
  Resolve every issue and rerun affected gates before T9 may record `Pass`.
- Review `README.md`, the example index, and
  `.codex/skills/riela-impl-workflow/SKILL.md`; update only directly affected
  user-facing documentation. Do not rewrite accepted unrelated workflow
  contracts.
- If any packaged workflow, prompt, reusable script, or skill carrying digest
  metadata is changed, refresh the owning `riela-package.json` digests and
  verify them. The standalone example itself does not imply a digest update.
- Record final scoped diffs, commands, results, findings, residual risks,
  conditional-task decisions, and unresolved operator-owned live questions.
- Confirm no generated consumer, `node_modules`, lockfile, tarball, `dist`,
  credential, or verification log is tracked; remove completed scratch state
  under the task-specific `tmp/` directory.
- Hand off exact changed-file arrays for Riela and Monja separately. Do not
  stage, commit, or push.

**Dependencies**: final successful T7 run; T8R/T8M completed or explicitly
marked `NOT_REQUIRED`.

## Progress Log Contract

Update this plan after every task with:

- status: `PENDING`, `IN_PROGRESS`, `DONE`, `NOT_REQUIRED`, or `BLOCKED`;
- timestamp and responsible implementation step;
- exact files changed, including repository root for cross-repository changes;
- exact commands and exit status, with safe concise results and full failure
  output referenced below `tmp/`;
- discovered findings and the evidence-based decision to narrow or widen scope;
- preservation check against each repository's T0 dirty baseline;
- remaining dependencies, verification gaps, and next task.

Never paste secrets, raw authorization headers, complete environments, live
response data, private paths generated in the consumer manifest, or unbounded
stderr into this tracked log. Use bounded classifications and gitignored
evidence references.

Final task state:

| Task | Status | Progress evidence |
| --- | --- | --- |
| T0 | DONE | Baselines preserved at Riela `c3282b1` and Monja `d7a37ce`; task output remained allowlisted |
| T1 | DONE | Strict JSONL command and pure URL policy implemented by the required TypeScript coding agent |
| T2 | DONE | Workflow, command-node payload, and fixed runtime launcher implemented |
| T3 | DONE | Fresh package build/pack inspection and isolated private ESM consumer passed |
| T4 | DONE | Ordered authenticated loopback mock and zero-network URL-policy verifier passed |
| T5 | DONE | Deterministic Riela-to-Node-to-Monja REST and GraphQL verifier passed |
| T6 | DONE | Example setup, contracts, expected results, and live boundary documented |
| T7 | DONE | Accepted automated gates passed; the source-build exception is recorded below |
| T8R | NOT_REQUIRED | No Riela JSONL executor defect was reproduced |
| T8M | NOT_REQUIRED | No Monja package or SDK defect was reproduced |
| T9 | DONE | Required independent check agent and TypeScript review passed; handoff recorded |

## Progress Log

### Session: 2026-09-06

**Repositories and scope**:

- Riela baseline: `c3282b1`. Changed only the standalone example, its index,
  and the design, QA, and implementation-plan records listed in this plan.
- Monja baseline: `d7a37ce`. No Monja production or test file was changed.
- Existing unrelated worktree changes in both repositories were neither
  formatted broadly, staged, reset, nor otherwise modified by this task.

**Implementation and verification evidence**:

- The required `ts-coding` agent implemented the two T1 TypeScript files.
- `bash examples/monja-typescript-sdk/scripts/verify.sh` exited 0. It built,
  typechecked, and packed `@monja/client`, installed the archive with lifecycle
  scripts disabled into a fresh private Node ESM consumer, and exercised the
  Riela workflow against the ordered authenticated mock. Positive REST and
  arbitrary GraphQL paths, malformed/bounded input, safe failure mappings,
  response/output limits, timeout, URL policy, request ordering, package
  resolution, and token non-disclosure all passed.
- Monja package gates passed: build, strict typecheck, and 274 tests across 14
  files. An additional temporary cross-process probe ran the actual Monja Hono
  harness and used the installed SDK from Node for `core.me()` and
  `graphql.executeStrict()`; both returned the expected authenticated admin
  identity.
- The exact-path Monja-configured Biome warning gate passed for both Riela
  TypeScript files. The isolated consumer passed TypeScript 5.7.2 strict
  NodeNext typecheck and emission under Node v26.7.0.
- `shellcheck`, `sh -n`, JavaScript syntax checks, JSON parsing, the pure URL
  matrix, prebuilt-Riela workflow validation/inspection, and scoped
  `git diff --check` gates passed.
- The mandatory `check-and-test-after-modify` agent reported `PASS` after the
  exact configured rerun. The mandatory final `ts-review` reported `Pass` with
  no remaining path-specific findings.

**Classified external build exception**:

- Source-based `swift run riela workflow validate` and the focused Swift test
  could not enter compilation because the existing Riela package graph pins a
  Kaiba revision that does not export the `KaibaClient` product required by
  `RielaKaibaSupport`. This predates and is outside the Monja integration
  allowlist. The existing Riela binary successfully validated and inspected
  this workflow, so no speculative Riela or Monja production fix was made.

**Decisions and residual boundary**:

- T8R and T8M are `NOT_REQUIRED`: the packed consumer, real Monja harness
  probe, and full deterministic verifier found no owning SDK or executor defect.
- No registry publication, live external deployment, API-key issuance, live
  mutation, commit, or push was performed. Live verification remains
  operator-owned as documented in the QA record.
- Generated consumer state, package archives, dependencies, compiled output,
  mock handoffs, and credentials remained below ignored Riela `tmp/` and were
  removed after verification.

## Completion Criteria

Implementation is complete only when all of the following are true:

- The implementation output contains the exact workflow/node/script chain, one
  strict TypeScript command, the pure URL policy, isolated preparation,
  deterministic mock/verifier, README, and expected-results documentation.
- A fresh npm tarball is built before packing, inspected, installed with
  scripts disabled into a new private ESM consumer, typechecked and emitted by
  the pinned local compiler, and resolved only from that consumer's installed
  `@monja/client/dist/index.js`.
- The actual Riela workflow passes one invocation record to Node, accepts one
  success object, and proves typed REST plus capability-gated arbitrary
  GraphQL against the ordered `127.0.0.1` mock.
- All accepted positive, negative, size, timeout, ESM, URL-policy, containment,
  request-order, and secret-leak checks pass deterministically.
- `MONJA_API_KEY` is environment-only; workflow JSON has empty argv/environment
  maps and no generated or committed artifact contains the runtime token.
- The accepted rollout commands pass, or a non-work-package/pre-existing
  failure is fully evidenced and explicitly separated from completion claims.
- Both Riela TypeScript files pass the exact-path formatting and Biome warning
  gates before isolated consumer typecheck/verification; the unconditional
  `check-and-test-after-modify` report passes and T9 records `ts-review: Pass`.
- Any Riela or Monja production change is backed by a reproduced owning defect,
  a focused regression test, relevant lint/typecheck/test gates, and a final
  clean scoped diff review.
- Unrelated dirty work in both repositories is unchanged; no cleanup, reset,
  broad formatting, staging, commit, push, registry publication, or live
  mutation occurs.
- Live verification is not claimed unless an operator separately resolves the
  questions in `design-docs/user-qa/qa-monja-typescript-sdk-command-node.md`
  and records external non-secret evidence.
- The final progress log contains exact file arrays, verification commands and
  decisions, conditional-task outcomes, remaining risks, and scratch cleanup.

## Risks And Controls

- **Stale or workspace-only package success**: build before pack, inspect the
  reported archive, install into a fresh consumer, and assert real ESM
  resolution inside consumer `node_modules`.
- **Consumer drift**: generate the exact accepted `package.json` and
  `tsconfig.json`, pin TypeScript and Node typings, retain a generated lockfile
  only as evidence, and reject version or path mismatches.
- **Credential leakage**: environment-only token, fixed empty argv, no shell
  tracing, safe bounded diagnostics, token scanning, and no raw SDK errors.
- **Plaintext remote transport**: derive insecure-localhost only for exact
  loopback HTTP before client construction; HTTPS remains the live default.
- **Resolver or IPv6 nondeterminism**: use only `127.0.0.1` for transport and
  test `localhost`/`[::1]` only through the pure policy seam.
- **GraphQL sequence mismatch**: require capabilities between REST and GraphQL
  and reject missing, extra, or reordered requests.
- **JSONL contamination or unbounded output**: enforce one input record, one
  object output, byte bounds, no stdout logging, and negative executor checks.
- **Runtime-directory escape**: canonicalize and reject missing, non-directory,
  symlink-escaping, or out-of-`tmp/` values before Node execution.
- **Unnecessary cross-repository edits**: enter conditional tasks only after a
  minimal reproduced owning failure and review every final path against the
  baseline allowlist.
- **Dirty-worktree collision**: preserve per-repository baseline evidence,
  avoid broad format/stage operations, and separate all pre-existing changes
  in the final handoff.
- **Misleading compatibility or live claims**: record the exact tested Node
  version, do not alter `engines`, and keep server lifecycle, credentials, TLS,
  and mutations operator-owned.

## Addressed Review Feedback

Step 3 reported no high, mid, or low findings. This plan carries every accepted
feedback item into explicit tasks, dependencies, file scopes, verification
commands, completion criteria, and risks. It preserves the accepted package
consumer, Node ESM, Riela JSONL, typed REST, arbitrary GraphQL,
environment-only authentication, deterministic verification, URL policy,
network order, dirty-worktree, Monja-reference, no-Cursor-dependency, and live
operator-boundary requirements without reopening the accepted design.

Step 5 `comm-000026` findings are addressed as follows:

- Mid finding at the former T1 completion check: T1 and T7 now contain the
  required unconditional exact-path Biome formatting and warning-diagnostic
  commands before consumer typecheck and verification; T1/T7 also require the
  explicit `check-and-test-after-modify` invocation with modification summary,
  Riela example layer, exact files, custom gates, and complete evidence.
- Low finding at the former line 9: the plan now references
  `design-docs/specs/design-monja-typescript-sdk-command-node.md#acceptance-mapping`.
- T9 now requires a recorded path-specific `ts-review` `Pass`/`Issues`
  decision and closes all issues before completion.
