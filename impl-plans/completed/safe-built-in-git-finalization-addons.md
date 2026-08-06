# Safe Built-in Git Finalization Add-ons Implementation Plan

**Status**: Completed and accepted; archived before commit-message generation
**Workflow Mode**: issue-resolution
**Issue Reference**: `tacogips/riela#80`
**Issue URL**: `https://github.com/tacogips/riela/issues/80`
**Created**: 2026-08-04
**Step 3 Review Decision**: `accepted-for-implementation-planning`

## Source of Truth

Implement the Step 3-accepted design in:

- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/core-built-in-workers.md`
- `design-docs/specs/design-node-addon-catalog-and-chat-reply-worker.md`

The accepted scope is one high-risk issue-resolution work package: complete the
existing staged `riela/git-commit@1` and `riela/git-push@1` candidate without
touching unrelated work. Preserve explicit per-operation authorization,
argument-array Git execution, repository/path confinement, crash-safe and
idempotent commit retries, same-name upstream validation, non-force push, live
remote reconciliation, bounded diagnostics, and deterministic tests.

No Codex-agent references were supplied. There is no Codex-reference behavior,
intentional divergence, or Cursor adapter boundary to trace in this plan.

## Existing Candidate and Ownership Boundary

The implementation step starts by reviewing, not discarding, the staged
candidate in:

- `.riela/workflows/codex-design-and-implement-review-loop/workflow.json`
- `Sources/RielaCLI/ProductionNodeAdapter+GitAddons.swift`
- `Sources/RielaCLI/ProductionNodeAdapter.swift`
- `Tests/RielaCLITests/GitWorkflowAddonTests.swift`
- `Tests/RielaCoreTests/WorkflowModelTests.swift`

The two accepted design documents and this plan also belong to issue #80.
Useful dispatch, parsing, and test scaffolding may be retained, but candidate
behavior that searches `PATH`, invokes `/usr/bin/env`, mutates the canonical
index before validation, infers retry success from commit message/path shape,
trusts display-form upstreams, or omits live post-push verification must be
reworked to match the accepted design. Unrelated staged or unstaged changes
must remain byte-for-byte untouched.

## Task Breakdown

### TASK-001 - Inventory the Candidate and Freeze Issue Ownership

**Status**: Completed
**Write Scope**: the plan progress log, now archived at
`impl-plans/completed/safe-built-in-git-finalization-addons.md`
**Parallelizable**: No
**Depends On**: Accepted Step 3 design

Tasks:

- Capture `git status --short`, staged and unstaged name-only diffs, and the
  current branch/upstream without changing Git state.
- Map each staged candidate behavior and test to the accepted commit, push,
  execution-identity, journal, output, and verification contracts.
- Record which existing code can be retained and which accepted safety
  requirements are absent or contradicted.
- Record an explicit issue-owned file allowlist before implementation. Add a
  file only when a later task proves it directly necessary.
- Keep all scratch/evidence artifacts under `tmp/issue-80-git-addons/`; never
  stage that directory.

Deliverables:

- Candidate gap matrix and issue-owned file allowlist in the progress log.
- No production or test mutation before the ownership boundary is recorded.

### TASK-002 - Carry Runtime-Owned Attempt Identity and Acceptance Lifecycle

**Status**: Completed
**Write Scope**:

- `Sources/RielaCore/WorkflowAddonExecution.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner+Addons.swift`
- `Sources/RielaCore/RuntimePublication.swift` and runtime-store/publication
  model files only if required for the accepted-token hook
- `Tests/RielaCoreTests/WorkflowAddonExecutionIdentityTests.swift` (new)
- `Tests/RielaCoreTests/RuntimePublicationTests.swift`

**Parallelizable**: Yes, with TASK-003 after TASK-001; scopes are disjoint
**Depends On**: TASK-001

Tasks:

- Add a runtime-owned add-on execution identity carrying
  `workflowExecutionId`, recorded `stepExecutionId`, monotonic attempt, and an
  optional exact predecessor execution id.
- Refactor add-on execution so the step execution is durably recorded before a
  mutating resolver is invoked, then pass that exact recorded identity through
  `WorkflowAddonExecutionInput`.
- Derive predecessor linkage only from persisted runtime execution state;
  authored config, workflow variables, resolved input, and add-on input must
  not set or override identity fields.
- Define a runtime-internal finalization token channel that is not projected
  into the business payload. Mark the exact token accepted only after accepted
  output is durably persisted; make cleanup/reconciliation safe across a crash
  after publication.
- Preserve decoding compatibility for existing add-on input fixtures and prove
  non-mutating add-ons remain behaviorally unchanged.

Deliverables:

- Recorded execution identity reaches the resolver before mutation.
- Publication can acknowledge one exact finalization token without exposing it
  to workflow-authored data or normal output.
- Core tests cover identity provenance, predecessor isolation, compatible
  decoding, accepted-token ordering, and crash/replay behavior.

### TASK-003 - Build Trusted Git, Repository, and Finalization-Store Primitives

**Status**: Completed
**Write Scope**:

- `Sources/RielaCLI/ProductionNodeAdapter+GitAddons.swift`
- `Sources/RielaCLI/ProductionNodeAdapter+GitProcess.swift` (new)
- `Sources/RielaCLI/ProductionNodeAdapter+GitRepository.swift` (new)
- `Sources/RielaCLI/ProductionNodeAdapter+GitFinalizationStore.swift` (new)
- `Tests/RielaCLITests/GitWorkflowAddonTests.swift`
- `Tests/RielaCLITests/GitWorkflowAddonPolicyTests.swift` (new, if splitting
  the staged test file materially improves ownership and size)

**Parallelizable**: Yes, with TASK-002 after TASK-001; do not edit Core files
**Depends On**: TASK-001

Tasks:

- Replace production `/usr/bin/env`/`PATH` lookup with one-time canonical
  resolution of `/usr/bin/git`, enforcing the accepted ownership, permission,
  symlink, parent-directory, and repository-exclusion policy.
- Keep a dependency-injected command runner for deterministic tests while
  production always executes the approved canonical executable with an
  argument array and bounded UTF-8 output.
- Construct the minimal child environment and explicit safety configuration:
  remove inherited `GIT_*`, askpass, pager, SSH/proxy-command, config,
  object-store, repository, and index overrides; disable hooks, signing,
  filesystem monitoring, and terminal prompting.
- Implement canonical repository identity from worktree top-level, per-worktree
  Git paths, common Git directory, and stable filesystem identities. Resolve
  index and lock paths through Git rather than assuming `.git` is a directory.
- Validate exact repository-relative paths, literal pathspecs, tracked
  deletions, regular worktree paths, directory rejection, `.git` exclusion,
  and exact allowlist equality without descendant expansion.
- Implement the runtime-owned external finalization store: digest-derived
  create-only journal keys, bounded canonical records, prepared-index files,
  synchronized atomic rename, collision checks, accepted-token marker/recovery,
  and non-mutating garbage collection.
- Add reusable deterministic failure-injection seams for journal, prepared
  index, ref, reflog, canonical index, lock, and output-publication phases.

Deliverables:

- Trusted process/repository/store primitives with no workflow-controlled
  executable or storage path.
- Deterministic unit coverage for executable trust, PATH poisoning, symlinks,
  inherited environment, linked worktrees, path confinement, collision, and
  store durability rules.

### TASK-004 - Implement the Crash-Safe Commit Transaction

**Status**: Completed
**Write Scope**:

- `Sources/RielaCLI/ProductionNodeAdapter+GitCommit.swift` (new)
- `Tests/RielaCLITests/GitWorkflowAddonCommitTests.swift` (new)

**Parallelizable**: Yes, with TASK-005 after TASK-002 and TASK-003; commit and
push files/tests must remain disjoint
**Depends On**: TASK-002, TASK-003

Tasks:

- Require explicit version `"1"`, `config.allowCommit: true`, a trimmed
  bounded non-empty message, and a typed 1...2,048 unique exact-file array.
- Snapshot and fingerprint the canonical index, reject any pre-existing staged
  path outside the allowlist, and leave the canonical index byte-for-byte
  unchanged during staging and validation.
- Stage only exact paths into an attempt-scoped prepared index with literal
  pathspec semantics; reject directories, implicit descendants, custom clean
  filters, empty commits, and staged-set/allowlist mismatches.
- Snapshot validated author/committer identity and required configuration, then
  prepare the tree and commit object without moving `HEAD`.
- Durably journal parent/ref/tree/commit/index fingerprints, validated inputs,
  repository and attempt identities, prepared-index location, and a random
  operation token before ref mutation.
- Publish under an exclusively created index lock: revalidate the canonical
  fingerprint, synchronize prepared bytes, compare-and-swap the branch ref with
  a tokened reflog entry, then atomically publish the index. Never remove a
  foreign or orphaned lock.
- Reconcile every journaled parent/candidate/index/reflog state exactly as the
  design specifies; ambiguous, corrupt, reset, cross-session, or mismatched
  states fail closed and never create a second commit.
- Emit the exact `git` business object for `committed` and
  `already-committed`, including full commit hash, validated message, and
  authored-order file list.

Deliverables:

- Atomic, allowlist-confined commit behavior with deterministic retry evidence.
- Failure-injection tests for every journal/ref/reflog/index/output crash phase,
  foreign locks, concurrent index/ref movement, reset-after-token, corrupt
  records, and cross-session replay.

### TASK-005 - Implement Safe Same-Name Upstream Push

**Status**: Completed
**Write Scope**:

- `Sources/RielaCLI/ProductionNodeAdapter+GitPush.swift` (new)
- `Tests/RielaCLITests/GitWorkflowAddonPushTests.swift` (new)

**Parallelizable**: Yes, with TASK-004 after TASK-002 and TASK-003; push files
and tests must remain disjoint
**Depends On**: TASK-002, TASK-003

Tasks:

- Require explicit version `"1"` and `config.allowPush: true` independently
  from commit authorization.
- Resolve and validate a named current branch plus independent
  `branch.<name>.remote` and `branch.<name>.merge` values; require the exact
  same-name `refs/heads/<current-branch>` upstream and reject detached, missing,
  malformed, option-like, or behind-local-tracking states.
- Snapshot the effective push URL and reject credential-bearing, rewritten
  unsupported, external-helper, configured receive-pack, query/fragment,
  control/whitespace, and unsafe SSH forms.
- Enforce the accepted transport policy. Resolve Git transport helpers,
  credential helpers, and `/usr/bin/ssh` only from accepted canonical trusted
  locations; reject shell snippets, arguments, relative/PATH/repository helpers,
  mutable SSH command strings, and unresolved helpers.
- Query the live remote branch tip through the validated transport snapshot.
  Return `already-pushed` only for an exact remote-tip/HEAD match; fail closed
  for missing or stale/divergent live state.
- Push only `HEAD:refs/heads/<current-branch>` with a non-force refspec, then
  query the live tip again and publish success only for an exact match.
- Keep credentials, URLs, helper protocol data, and captured provider output
  out of workflow diagnostics and output.
- Emit the exact `git` business object for `pushed` and `already-pushed`,
  including full commit hash, validated remote name, and branch name.

Deliverables:

- Fail-closed same-name upstream push with live retry and post-push evidence.
- Deterministic tests for branch/remote grammar, transport parsing, trusted and
  untrusted helpers, URL rewrites, PATH poisoning, stale tracking refs, live
  divergence, non-fast-forward concurrency, provider failures, and post-push
  verification failures.

### TASK-006 - Integrate Dispatch, Workflow Authorization, and Output Contracts

**Status**: Completed
**Write Scope**:

- `Sources/RielaCLI/ProductionNodeAdapter.swift`
- Git add-on dispatch/output integration files
- `.riela/workflows/codex-design-and-implement-review-loop/workflow.json`
- `Tests/RielaCoreTests/WorkflowModelTests.swift`
- `Tests/RielaCLITests/GitWorkflowAddonIntegrationTests.swift` (new, if the
  staged `GitWorkflowAddonTests.swift` is split)

**Parallelizable**: No
**Depends On**: TASK-004, TASK-005

Tasks:

- Route only `riela/git-commit@1` and `riela/git-push@1`; omitted or unsupported
  versions must be policy-blocked even if other built-ins accept shorthand.
- Preserve the independently authored `allowCommit: true` and `allowPush: true`
  gates in the issue-owned workflow and prove neither can be inferred from
  workflow progression or prior approval.
- Validate that Step 9 supplies the exact message/file list, Step 10 publishes
  commit evidence, Step 11 independently revalidates push state, and
  `workflow-output` consumes rather than fabricates the required evidence.
- Reject success payloads with missing, stale, mismatched, or leaked fields.
- Refresh a package digest only if an applicable `riela-package.json` is
  present at implementation time; record the current absence rather than
  creating an unrelated manifest.

Deliverables:

- Resolver, workflow, and final output are wired to the accepted contracts.
- Workflow-model and integration tests cover dispatch, exact versions,
  authorization, output fields, and stale/missing evidence rejection.

### TASK-007 - Run the Full Adversarial Matrix and Close Review Gaps

**Status**: Completed
**Write Scope**:

- Git/Core test files owned by TASK-002 through TASK-006
- implementation files only for failures proven by the matrix
- `impl-plans/completed/safe-built-in-git-finalization-addons.md` progress log

**Parallelizable**: No
**Depends On**: TASK-002 through TASK-006

Tasks:

- Run the accepted deterministic matrix for authorization, strict rendering,
  literal paths, rollback, executable/helper trust, hook/filter isolation,
  identity snapshots, journal identity/collision/cleanup, every crash phase,
  foreign locks, reflog proof, reset, stale live remote, transport policy,
  retries, and output evidence.
- Confirm failures expose only stable error category and bounded safe
  diagnostics.
- Run the focused Core and CLI suites after the narrow Git suite so shared
  runner/publication regressions are caught.
- Address every high or mid implementation-review finding without weakening a
  safety assertion; add a regression test for each accepted fix.

Deliverables:

- Recorded command results and test counts.
- No unresolved high or mid finding; low residual risks remain explicit.

### TASK-008 - Refresh Documentation and Produce the Final Owned Diff

**Status**: Completed; documentation refreshed and final owned diff handed off to later commit/push gates
**Write Scope**:

- accepted design documents only for implementation-proven clarification
- directly affected `README.md` or workflow-use skill only when behavior is
  user-facing and currently undocumented
- `impl-plans/completed/safe-built-in-git-finalization-addons.md`

**Parallelizable**: No
**Depends On**: TASK-007

Tasks:

- Re-read the accepted design, `README.md`, and `.codex/skills/riela-impl-workflow/SKILL.md`.
- Keep documentation aligned with implemented authorization, safety, retry,
  output, verification, and operator-owned orphan-lock behavior; do not reopen
  accepted scope.
- Record changed files, retained candidate elements, intentional
  implementation clarifications, commands, results, blockers, and residual
  risks in the progress log.
- Verify staged and unstaged issue-owned diffs separately. Stage/commit only
  the explicit issue #80 allowlist; preserve all unrelated work.
- Before any push, verify the current branch has a configured same-name
  upstream, all gates pass, and the push is non-force. Push only that branch.

Deliverables:

- Review-ready issue-owned diff and complete progress evidence.
- Documentation refresh complete before commit generation.

## Dependencies

| Task | Depends On | Reason |
| --- | --- | --- |
| TASK-001 | Accepted Step 3 design | Freezes candidate gaps and ownership before writes |
| TASK-002 | TASK-001 | Runtime identity and accepted-token lifecycle are mutation prerequisites |
| TASK-003 | TASK-001 | Shared Git/repository/store policy precedes commit and push |
| TASK-004 | TASK-002, TASK-003 | Commit recovery needs runtime identity and durable primitives |
| TASK-005 | TASK-002, TASK-003 | Push needs runtime identity and trusted process/transport primitives |
| TASK-006 | TASK-004, TASK-005 | Integration must target completed operation contracts |
| TASK-007 | TASK-002 through TASK-006 | Adversarial verification spans all layers |
| TASK-008 | TASK-007 | Docs and final ownership evidence follow verified behavior |

## Parallelizable Tasks

- TASK-002 and TASK-003 may run in parallel after TASK-001 because their Core
  and CLI write scopes are disjoint. Agree on the execution-identity and
  internal-token interfaces before either task lands integration changes.
- TASK-004 and TASK-005 may run in parallel after TASK-002 and TASK-003 only if
  they use separate commit/push source and test files. Shared dispatch, workflow,
  and output wiring remains exclusively owned by TASK-006.
- No other tasks are parallelizable; they either establish ownership, integrate
  shared files, verify the combined state, or prepare final handoff.

## Verification

For this SwiftPM work package, `swift build` is the compile and typecheck gate.
Run focused checks first, then shared regression gates:

```bash
swift build
swift test --filter GitWorkflowAddon
swift test --filter WorkflowModelTests
swift test --filter RielaCLITests
swift test --filter RielaCoreTests
swift run riela workflow validate codex-design-and-implement-review-loop --workflow-definition-dir .riela/workflows --output json
git diff --check
git diff --cached --check
git status --short
git diff --name-only
git diff --cached --name-only
```

The Git test filter may be split into narrower policy, commit, push, journal,
and integration suites during implementation, but the aggregate
`GitWorkflowAddonTests` gate must remain available or be replaced by an
explicit equivalent command list in the progress log.

## Completion Criteria

- [x] The staged candidate has been audited and only issue-owned files are
      modified, staged, committed, or pushed.
- [x] Both built-ins require exact version `1` and independent explicit
      authorization.
- [x] Production Git and helper execution never searches workflow-controlled
      `PATH`, never uses shell interpolation, and uses only validated argument
      arrays, environment, configuration, and trusted canonical executables.
- [x] Every Git invocation disables repository replacement-object semantics so
      `refs/replace/*` cannot alter exact staged-path, tree, retry, or ancestry
      validation and hide allowlist-external canonical-index content.
- [x] Commit staging is exact, repository-confined, canonical-index preserving,
      journaled before ref mutation, compare-and-swap published, reflog proven,
      and idempotent across every accepted retry/crash state, including a
      transient retry-validation or repository-preflight failure before the
      next runtime attempt.
- [x] Untrusted no-follow repository discovery, linked-worktree backpointer,
      canonical-index, and worktree-content opens are nonblocking and reject
      FIFO, dangling-symlink, or other non-regular replacements before waiting
      outside the workflow deadline; final-entry or intermediate-ancestor
      `ENOENT` is accepted only as a missing-path candidate, exact tracked-file
      validation is required before treating it as a deletion, and
      classification is repeated at staging.
- [x] Immutable journal, predecessor-link, prepared-index, and create-only
      collision reads are descriptor-bound, no-follow, nonblocking, size
      bounded, deadline-aware, non-destructively validate runtime-owned
      post-link crash artifacts under a bounded directory scan, and fail closed
      on foreign hard links, ownership replacement, or path replacement.
- [x] The finalization root and every managed child directory retain no-follow
      descriptors and stable device/inode identities; every later operation
      revalidates its pathname binding and uses descriptor-relative creation,
      chmod, linking, reads, scans, synchronization, and removal so
      post-preflight root or child symlink swaps fail closed without target
      mutation.
- [x] Failed-artifact garbage collection uses deadline-aware, entry-bounded
      descriptor scans, carries the cutoff-qualified snapshot into cleanup,
      and removes only that exact regular-file snapshot after private
      quarantine while exclusively restoring concurrent replacements.
- [x] Isolated transport repositories retain an exact directory identity,
      preserve concurrent path replacements during cleanup, and are eligible
      for bounded age-based collection after cancellation or process death.
- [x] Commit and push preparation never collect journals solely by age;
      repository-bound exact-journal markers derived from runtime-persisted
      completed or non-resumable failed workflow and step executions establish
      eligibility, while old active and max-step-resumable retry ancestry
      remains available.
- [x] Terminal maintenance keeps its journal candidate set bounded while
      streaming every runtime-persisted step execution identity, so workflows
      exceeding the 4,096 finalization-directory scan limit still mark their
      exact Git journal without retaining an unbounded identity set.
- [x] Foreign/orphaned index locks are never removed automatically.
- [x] Push validates the current same-name upstream and approved network
      transport snapshot, requires `HEAD` to equal the full accepted Step 10
      commit hash before live access, rejects local and `file://` receiver
      execution, requires the accepted commit to be the sole commit above the
      live upstream, reconciles live remote state, never forces, and verifies
      the live tip after success.
- [x] Commit publication retains its owned index-lock descriptor through ref
      update, index publication, or owned cleanup and rejects any lock-path
      replacement without removing the foreign lock.
- [x] Commit/push success and retry outputs contain every accepted evidence
      field and no credential, URL, helper data, or provider output.
- [x] The protected terminal output fails closed when its exact versioned Git
      finalization policy is missing, ambiguous, or invalidated by topology
      drift, accepts only equal lowercase 40- or 64-character object IDs, and
      copies the accepted Step 10 committed-file array exactly.
- [x] Deterministic tests cover all accepted success, policy, failure,
      concurrency, crash, retry, and evidence cases without live network access.
- [x] Build, focused tests, Core/CLI regressions, workflow validation, and both
      diff checks pass, or a genuinely external gap is recorded with evidence.
- [x] No known high or mid implementation or test-integrity finding remains;
      independent Step 7 review remains the next gate.
- [x] Documentation is refreshed before commit generation, the implementation
      plan progress log is complete, and the exact issue-owned commit/push
      handoff is recorded for the later same-name-upstream workflow gates.

## Progress Log Expectations

After each task, append a dated entry containing:

- task status and completed checklist items;
- exact changed-file paths and confirmation that write scope was respected;
- retained/reworked staged-candidate behavior;
- decisions and accepted-design traceability;
- exact verification commands, exit status, test counts, and relevant failure
  evidence;
- blockers, unresolved findings, residual risks, and next dependency.

Do not mark a task complete from code inspection alone when its deliverable has
a deterministic test or command gate. Move this plan to `impl-plans/completed/`
after the accepted implementation, review, documentation, and exact-file
finalization handoff are complete; commit and push remain later workflow gates.

## Risks

- **High during implementation**: ref/index publication and output acceptance
  span Git and runtime persistence; incomplete ordering can report success for
  a partially published commit. Mitigation: tokened journal state machine plus
  phase-by-phase failure injection.
- **High during implementation**: Git config, hooks, filters, helpers, URL
  rewrites, SSH commands, or inherited environment can introduce command
  execution. Mitigation: minimal environment, explicit safety overrides,
  trusted canonical helper policy, and adversarial fixtures.
- **Medium**: runtime add-on identity and accepted-token plumbing affects shared
  Core execution/publication paths. Mitigation: backward-compatible models and
  focused plus full Core regression suites.
- **Medium**: the current staged candidate mutates the canonical index and
  infers retry success too loosely. Mitigation: retain only safe scaffolding and
  require temporary-index/journal/reflog proof before accepting behavior.
- **Low residual**: an orphaned `.git/index.lock` still requires owning-process
  or operator resolution; the add-on must fail retryably and leave it intact.
- **Low residual**: concurrent remote updates remain possible; non-force push
  and post-push live-tip verification fail closed.
- **Low residual**: additional platform Git or credential-helper locations are
  unsupported until a versioned policy change and deterministic tests approve
  them.

## Progress Log

### 2026-08-04 - Plan Created

- **Completed**: Step 3 acceptance confirmed from `comm-000429`; accepted design
  and staged candidate paths inspected; implementation tasks, ownership,
  dependencies, parallel boundaries, verification, and risks documented.
- **In progress**: None.
- **Blockers**: None.
- **Codex-agent references**: None supplied.
- **Next**: TASK-001 candidate inventory and issue-owned file allowlist.

### 2026-08-04 - Step 4 Self-Review

- **Completed**: Rechecked the plan against the accepted design and current
  staged candidate. Tightened prospective Core/CLI/test file ownership for the
  two parallel work groups and made the Swift compile/typecheck gate explicit.
- **Design defects**: None identified.
- **Plan defects remaining**: None identified.
- **Verification**: `git diff --check` and `git diff --cached --check` passed.
- **Next**: Independent Step 5 implementation-plan review.

### 2026-08-04 - TASK-001 through TASK-007 Implementation and Verification

- **Completed**: Audited the staged candidate, retained its resolver/workflow/test
  scaffolding, and replaced unsafe PATH lookup, canonical-index staging,
  message/path retry inference, and display-only upstream handling.
- **Runtime lifecycle**: Added runtime-owned execution identity, persisted
  internal finalization tokens, post-acceptance acknowledgment, and startup
  reconciliation without exposing tokens in business output.
- **Commit transaction**: Added exact literal-path validation, no-filter object
  staging into an attempt index, create-only journal/prepared records, reflog
  proof, compare-and-swap ref publication, owned index-lock publication, and
  deterministic recovery across all six injected failure phases.
- **Push transaction**: Added strict same-name upstream and effective-URL
  validation, trusted helper/SSH policy, isolated runtime transport
  configuration, live remote reconciliation, explicit non-force push, and
  post-push tip/HEAD verification.
- **Integration and output**: Kept exact version `1` and independent
  `allowCommit`/`allowPush` gates; wired complete commit/push evidence into the
  final workflow output prompt. No `riela-package.json` exists, so no digest
  refresh applies.
- **Issue-owned implementation files**:
  `.riela/workflows/codex-design-and-implement-review-loop/workflow.json`,
  `.riela/workflows/codex-design-and-implement-review-loop/prompts/workflow-output.md`,
  `Sources/RielaCLI/ProductionNodeAdapter.swift`,
  `Sources/RielaCLI/ContainerWorkflowAddonResolver.swift`, all six
  `Sources/RielaCLI/ProductionNodeAdapter+Git*.swift` files,
  `Sources/RielaCore/AdapterContracts.swift`,
  `Sources/RielaCore/DeterministicWorkflowRunner+Addons.swift`,
  `Sources/RielaCore/RuntimePublication.swift`,
  `Sources/RielaCore/RuntimeSession.swift`,
  `Sources/RielaCore/WorkflowAddonExecution.swift`,
  `Tests/RielaCLITests/GitWorkflowAddonTests.swift`,
  `Tests/RielaCLITests/GitWorkflowAddonAdversarialTests.swift`,
  `Tests/RielaCoreTests/WorkflowAddonExecutionIdentityTests.swift`, and
  `Tests/RielaCoreTests/WorkflowModelTests.swift`.
- **Design and planning files**:
  `design-docs/specs/node-addon-catalog-and-chat-reply-worker/core-built-in-workers.md`,
  `design-docs/specs/design-node-addon-catalog-and-chat-reply-worker.md`, and
  this active plan. No Codex-agent reference was supplied.
- **Verification passed**: Xcode-toolchain `swift build`; aggregate direct
  XCTest execution for `GitWorkflowAddonTests` and
  `GitWorkflowAddonAdversarialTests` (39 tests); `swift test --filter
  'WorkflowAddonExecutionIdentityTests|WorkflowModelTests'` (26 tests);
  `swift test --filter RielaCoreTests` (481 tests); `swift test --filter
  RielaCLITests` (726 tests after the revision); targeted strict SwiftLint for every issue-owned
  Swift file; workflow validation with `valid: true` and no diagnostics; `git
  diff --check`; and `git diff --cached --check`.
- **Findings**: No unresolved high or mid self-review finding. The push
  transport was hardened after self-review to perform network operations from
  a runtime-owned isolated bare repository with system/global/local config
  excluded after preflight. A staging symlink-swap window was closed by hashing
  from a descriptor opened through no-follow, repository-identity-checked path
  traversal; a deterministic ancestry-symlink regression test was added.
- **Residual risks**: Foreign/orphaned index locks remain operator-owned;
  concurrent remote updates fail closed through non-force push and post-push
  verification; platform helper locations outside the version `1` allowlist
  remain unsupported.
- **Next**: Independent implementation/adversarial review. TASK-008 remains in
  progress because staging, commit, push, plan archival, and final documentation
  handoff belong to later workflow gates.

### 2026-08-04 - Step 6 Self-Review Revision

- **Addressed findings**: Added accepted-finalization acknowledgment forwarding
  through `CompositeWorkflowAddonResolver` and `ScenarioWorkflowAddonResolver`;
  integration tests prove accepted markers persist while journals, prepared
  indexes, and execution links are cleaned.
- **HTTPS policy**: HTTPS now requires a non-empty trusted credential-helper
  snapshot. Ordered helper reset semantics are applied before validation, and
  deterministic tests cover trusted installation-root, absent, repository-local,
  and reset-discarded helper configurations without live network access.
- **Completed matrix**: Added explicit repository-hook, global-identity snapshot,
  external-helper/URL-rewrite, journal-collision, accepted-output cleanup,
  trusted-executable/symlink, concurrent non-fast-forward, and post-push
  verification-failure tests in
  `Tests/RielaCLITests/GitWorkflowAddonAdversarialTests.swift`.
- **Verification**: Xcode-toolchain `swift build` passed. Direct XCTest execution
  of both Git classes passed 39 tests with zero failures and a clean command
  exit. The final `RielaCLITests` module selection passed 726 tests with zero
  failures; the command wrapper remained open past the recorded successful
  suite completion and was terminated at 300 seconds. The focused Core identity
  and workflow-model selection passed 26 tests. Targeted strict SwiftLint passed
  for every issue-owned Swift file. Workflow validation returned `valid: true`
  with no diagnostics. Final `git diff --check` and `git diff --cached --check`
  passed, and no `riela-package.json` digest refresh applies.
- **Plan state**: TASK-007 and its deterministic-matrix completion criterion
  remain complete based on the expanded passing matrix. TASK-008 remains in
  progress for later documentation, commit, push, and archival gates.
- **Next**: Repeat Step 6 self-review, then independent Step 7 review if no
  high or mid finding remains.

### 2026-08-04 - Step 6 Test-Integrity Revision

- **Addressed retry evidence finding**: Strengthened
  `Tests/RielaCLITests/GitWorkflowAddonTests.swift` so `already-committed`,
  `pushed`, and `already-pushed` outcomes assert the exact operation, status,
  hash, message/files or remote/branch fields, and reject unexpected evidence
  keys. Added a workflow-output prompt contract test covering the exclusive
  Step 10/Step 11 evidence sources, required hash equality, required fields,
  and non-fabrication on missing or mismatched evidence.
- **Completed omitted contract coverage**: Added
  `Tests/RielaCLITests/GitWorkflowAddonContractTests.swift` for tracked
  deletions, message/file bounds, duplicate paths, linked worktrees, unsafe
  transport forms, configured SSH commands, and bounded non-leaking
  diagnostics. Added `Tests/RielaCLITests/GitWorkflowAddonRecoveryTests.swift`
  for missing/corrupt journal state, corrupt predecessor links, missing
  prepared indexes, missing reflog proof, concurrent canonical-index movement,
  and compare-and-swap ref races.
- **Completed runtime identity coverage**: Extended
  `Tests/RielaCoreTests/WorkflowAddonExecutionIdentityTests.swift` to prove
  authored config/variables cannot override identity, resumed attempts derive
  monotonic attempt and exact predecessor values from persisted executions,
  and an interrupted accepted-token acknowledgment is reconciled on resume.
- **Implementation corrections exposed by the new tests**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitFinalizationStore.swift` now maps a
  missing prepared index to the stable fail-closed policy error, and
  `Sources/RielaCore/DeterministicWorkflowRunner.swift` initializes per-step
  attempt counts from persisted executions so resumed attempts remain
  monotonic. The latter file is added to the issue #80 ownership allowlist as a
  directly proven runtime-identity correction.
- **Verification**: `swift test --filter RielaCoreTests` passed 484 tests;
  `swift test --filter RielaCLITests` passed 738 tests; the four Git add-on
  classes account for 51 passing tests. `WorkflowModelTests` passed 24 tests,
  and the focused recovery/identity selection passed 11 tests. Xcode-toolchain
  `swift build` passed with a clean command exit when output was suppressed.
  Targeted strict SwiftLint passed for all 20 issue-owned Swift files. Workflow
  validation returned `valid: true` with no diagnostics; its command wrapper
  remained open after producing the valid result. `swift test --filter
  GitWorkflowAddon` passed all 51 Git add-on tests. Final `git diff --check`
  and `git diff --cached --check` both passed.
- **Findings closed**: Both mid-severity findings from `comm-000437` are
  addressed. No tests were deleted, skipped, narrowed, or weakened, and no
  test-only production branch was added.
- **Next**: Step 6 self-review and test-integrity gates, then independent Step 7
  adversarial review. TASK-008 remains in progress for documentation, staging,
  commit, push, archival, and final handoff.

### 2026-08-05 - Step 7 Concurrency and Retry Revision

- **Source review**: Addressed all high- and mid-severity findings from
  `comm-000441` without changing the accepted design or weakening existing
  policy checks.
- **Commit branch confinement**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitCommit.swift` now revalidates the
  exact symbolic branch and expected HEAD revision while holding the owned
  index lock, both before compare-and-swap ref mutation and before prepared
  index publication. Concurrent same-tree branch switches fail retryably
  without advancing a ref or publishing the index.
- **Push evidence confinement**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitPush.swift` now revalidates the
  exact snapshotted branch and HEAD before and after live-remote queries and
  after post-push verification. Both `already-pushed` and `pushed` reject
  concurrent branch switches, including switches to a branch at the same
  commit.
- **Multi-attempt recovery**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitFinalizationStore.swift` records
  create-only retry-execution aliases to the immutable original journal.
  `Sources/RielaCLI/ProductionNodeAdapter+GitCommit.swift` creates the alias
  before reconciliation, so a second recovery failure can be resumed by the
  next runtime-owned predecessor. Accepted-token cleanup removes every alias
  for the exact journal.
- **Deterministic coverage**:
  `Tests/RielaCLITests/GitWorkflowAddonRecoveryTests.swift` covers a concurrent
  commit branch switch and three attempts with two consecutive
  output-publication failures, including alias cleanup.
  `Tests/RielaCLITests/GitWorkflowAddonAdversarialTests.swift` covers
  `already-pushed` branch switches with identical and different commit ids and
  a same-commit switch during post-push verification.
- **Verification**: Xcode-toolchain `swift build` reported `Build complete`.
  Direct aggregate Git XCTest execution reported 55 tests with zero failures.
  `swift test --filter RielaCLITests` reported 742 tests with zero failures, and
  `swift test --filter RielaCoreTests` reported 484 tests with zero failures.
  Targeted strict SwiftLint passed for the five changed Swift files. The Swift
  command and XCTest wrappers remained open after their successful suite/build
  summaries and were bounded by timeouts. Final `git diff --check` and `git
  diff --cached --check` both passed after this progress entry was written.
- **Plan state**: TASK-007 remains complete with the new regressions. TASK-008
  remains in progress for the later documentation, staging, commit, push,
  archival, and final handoff gates.
- **Residual risks**: Foreign or orphaned index locks remain operator-owned;
  concurrent remote updates remain fail-closed through non-force push and live
  verification; additional platform helper locations remain unsupported.
- **Next**: Repeat Step 6 self-review, test-integrity, and independent Step 7
  review.

### 2026-08-05 - Step 7 Reflog, Retention, and Process-Boundary Revision

- **TASK-007 reopened and completed**: Addressed every mid-severity finding from
  `comm-000445` without reopening the accepted design or weakening existing
  authorization, confinement, retry, or transport checks.
- **Exact reflog reconciliation**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitCommit.swift` now accepts only the
  newest exact tokened reflog subject and proves both the immediately preceding
  branch revision and the candidate commit parent equal the journaled parent.
  `Tests/RielaCLITests/GitWorkflowAddonRecoveryTests.swift` proves a branch
  moved away from and back to the candidate remains policy-blocked.
- **Bounded failed-artifact retention**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitFinalizationStore.swift` now
  garbage-collects coherent old journal, prepared-index, and execution-link
  sets; cleans old orphan prepared indexes, temporary files, and links; honors
  the configured collection limit; and preserves a journal carrying a recent
  retry alias. Tests cover age, limit, coherent removal, orphan cleanup, and
  retry preservation.
- **Bounded process output and deadlines**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitProcess.swift` now launches the
  canonical Git executable in its own process group, drains combined output
  into a hard 1 MiB in-memory bound, terminates the group on overflow or
  deadline, and maps deadline expiry to the runtime timeout category.
  `Sources/RielaCLI/ProductionNodeAdapter.swift` and
  `Sources/RielaCLI/ProductionNodeAdapter+GitAddons.swift` propagate the exact
  `AdapterExecutionContext.deadline` through the Git operation. Contract tests
  cover output overflow, a Git alias with a hanging child process, and deadline
  propagation through resolver dispatch.
- **Verification**: Xcode-toolchain `swift test --filter
  GitWorkflowAddonContractTests` passed 9 tests; `swift test --filter
  GitWorkflowAddonRecoveryTests` passed 12 tests; aggregate `swift test
  --filter GitWorkflowAddon` passed 62 tests; `swift test --filter
  RielaCLITests` passed 749 tests; and `swift test --filter RielaCoreTests`
  passed 484 tests, all with zero failures. Builds completed successfully.
  Targeted strict SwiftLint passed with no diagnostics and a clean command
  exit. Swift test wrappers remained open after successful summaries and were
  bounded at 300 seconds where required. Final `git diff --check` and `git
  diff --cached --check` both passed, and the focused test diff contains no
  deleted test or assertion lines.
- **Plan state**: TASK-007 and the deterministic-matrix completion criterion
  are complete again. TASK-008 remains in progress for later documentation
  finalization, staging, commit, push, archival, and final handoff gates.
- **Residual risks**: Foreign or orphaned index locks remain operator-owned;
  concurrent remote updates remain fail-closed through non-force push and live
  verification; additional platform helper locations remain unsupported.
- **Next**: Repeat Step 6 self-review and test-integrity gates, then independent
  Step 7 review.

### 2026-08-05 - Step 6 Long-Deadline Conversion Revision

- **TASK-007 reopened and completed**: Addressed the mid-severity self-review
  finding from `comm-000447` without changing the accepted deadline policy.
- **Bounded conversion**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitProcess.swift` now clamps a finite
  remaining deadline interval in the floating-point domain before converting
  it to the `poll` API's `Int32` timeout. Non-finite deadline intervals fail
  closed as `deadlineExceeded` instead of trapping or polling indefinitely.
- **Deterministic coverage**:
  `Tests/RielaCLITests/GitWorkflowAddonContractTests.swift` exercises a real
  delayed Git child with a deadline beyond `Int32.max` milliseconds and rejects
  a non-finite deadline through the production runner.
- **Verification**: Xcode-toolchain `swift test --filter
  GitWorkflowAddonContractTests` passed 11 tests, aggregate `swift test --filter
  GitWorkflowAddon` passed 64 tests, and `swift test --filter RielaCLITests`
  passed 751 tests, all with zero failures and completed builds. Targeted strict
  SwiftLint passed with no diagnostics. Final whitespace and focused test
  integrity checks passed.
- **Plan state**: TASK-007 is complete again. TASK-008 remains in progress for
  documentation finalization, staging, commit, push, archival, and final
  handoff.
- **Next**: Repeat Step 6 self-review and test-integrity gates, then independent
  Step 7 review.

### 2026-08-05 - Step 7 Empty-Commit, Publication, and Store-Confinement Revision

- **TASK-007 reopened and completed**: Addressed all three mid-severity
  findings from `comm-000451` without changing the accepted authorization,
  exact-path, retry, or transport contracts.
- **Tree-based empty-commit rejection**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitCommit.swift` now rejects a
  prepared tree equal to the parent tree before creating the commit object;
  index-byte differences remain concurrency evidence only. A fresh unchanged
  tracked-file regression proves policy rejection without changing `HEAD`, the
  canonical index, or finalization journals.
- **Post-ref and pre-output branch confinement**: Commit publication now
  revalidates the exact symbolic branch and candidate revision after the ref
  failure seam, immediately before index publication, and after the index
  publication seam before success can be emitted. Deterministic tests switch
  branches at both seams and prove no false success or unintended canonical
  index publication.
- **Runtime store and hook confinement**: Git operations now prepare the
  finalization store only after repository discovery. The store canonicalizes
  its root and every managed directory, rejects repository overlap and symlink
  escape, and requires the runtime hooks directory to be empty. Contract tests
  cover an in-repository store, an outside symlink resolving into the
  repository, and preexisting hook content.
- **Verification**: The focused Xcode-toolchain selection
  `swift test --filter 'GitWorkflowAddonContractTests|GitWorkflowAddonRecoveryTests'`
  passed 29 tests with zero failures and a clean exit. Aggregate
  `swift test --filter GitWorkflowAddon` passed 70 tests with zero failures and
  a clean exit. `swift test --filter RielaCLITests` reported 757 tests with zero
  failures; its wrapper timed out only after the successful suite summary. An
  explicit Xcode-toolchain `swift build` passed with a clean exit. Xcode-routed
  targeted strict SwiftLint passed with no diagnostics and a clean exit. `git
  diff --check`, `git diff --cached --check`, and the focused
  no-deleted-test-lines scan passed. The initial verification compile exposed a
  missing array delimiter, and the first focused run exposed an over-specific
  error-message assertion; both were corrected before the passing reruns.
- **Plan state**: TASK-007 and its completion criteria are complete again.
  TASK-008 remains in progress for documentation finalization, staging, commit,
  push, archival, and handoff.
- **Residual risks**: Foreign or orphaned index locks remain operator-owned;
  concurrent remote updates remain fail-closed through non-force push and live
  verification; additional platform helper locations remain unsupported.
- **Next**: Repeat Step 6 self-review and test-integrity gates, then independent
  Step 7 and required adversarial review.

### 2026-08-05 - Step 7 Retry-Boundary and Finalization-Lifecycle Revision

- **TASK-007 reopened and completed**: Addressed both mid-severity findings from
  `comm-000455` without changing the accepted Git authorization, mutation, or
  recovery contracts.
- **Exact retry predecessor**:
  `Sources/RielaCore/DeterministicWorkflowRunner+Addons.swift` now links only
  the immediately preceding execution for the same logical step and node, and
  only when that execution is failed or running without accepted output. An
  accepted execution is therefore a hard boundary that prevents a later loop
  invocation from replaying an older Git journal.
- **Accepted-finalization lifecycle**:
  `Sources/RielaCore/DeterministicWorkflowRunner.swift` now reconciles completed
  accepted tokens at every resumed session entry, including terminal sessions.
  It acknowledges the exact completed execution after ordinary or recovered
  pending publication. Running staged publications remain unacknowledged until
  their route transaction completes, preserving retry evidence if publication
  aborts.
- **Deterministic coverage**:
  `Tests/RielaCoreTests/WorkflowAddonExecutionIdentityTests.swift` now covers a
  failed attempt followed by an accepted retry and a new loop invocation, an
  interrupted acknowledgment followed by completed-session resume, and an
  interrupted acknowledgment after staged-publication recovery. The focused
  suite passes 8 tests with zero failures.
- **Verification**: Xcode-toolchain `swift test --filter
  WorkflowAddonExecutionIdentityTests` passed 8 tests with zero failures and a
  clean command exit. `swift test --filter RielaCoreTests` reported 487 tests
  with zero failures before its wrapper timed out. `swift test --filter
  GitWorkflowAddon` passed 70 tests with zero failures and a clean command exit.
  The authoritative extended `swift test --filter RielaCLITests` rerun passed
  757 tests with zero failures and a clean command exit; an earlier 300-second
  attempt was terminated before its final summary, and a diagnostic direct
  XCTest selector matched zero tests and was not treated as evidence. Direct
  installed SwiftLint passed strict targeted lint for the three changed Swift
  files. The explicit Xcode-toolchain `swift build` reported `Build complete`
  before its wrapper timed out. Final `git diff --check` and `git diff --cached
  --check` both passed, and the focused test diff contains no deleted test or
  assertion lines.
- **Plan state**: TASK-007 and the deterministic-matrix completion criterion
  are complete again. TASK-008 remains in progress for documentation
  finalization, staging, commit, push, archival, and final handoff.
- **Residual risks**: Foreign or orphaned index locks remain operator-owned;
  concurrent remote updates remain fail-closed through non-force push and live
  verification; additional platform helper locations remain unsupported.
- **Next**: Repeat Step 6 self-review and test-integrity gates before
  independent Step 7 and required adversarial review.

### 2026-08-05 - Step 7 Reflog, Repository-Identity, and Evidence-Guard Revision

- **TASK-007 reopened and completed**: Addressed all three mid-severity
  findings from `comm-000459` while preserving the accepted authorization,
  confinement, recovery, and output contracts.
- **Durable reflog proof**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitCommit.swift` now invokes
  `git update-ref --create-reflog`, then verifies the newest exact tokened
  parent-to-candidate transition before publishing the prepared index.
  `Tests/RielaCLITests/GitWorkflowAddonRecoveryTests.swift` proves recovery
  evidence is created with `core.logAllRefUpdates=false` and no prior branch
  reflog.
- **Pinned per-worktree repository identity**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitFinalizationStore.swift` and
  `Sources/RielaCLI/ProductionNodeAdapter+GitRepository.swift` now persist and
  revalidate the Git discovery path, per-worktree Git directory, and index
  parent identities. Repository Git commands are pinned to the validated Git
  directory and worktree. Commit publication revalidates identity immediately
  before ref and index mutation. A linked-worktree metadata-retargeting test in
  `Tests/RielaCLITests/GitWorkflowAddonContractTests.swift` proves fail-closed
  behavior without ref or index publication.
- **Deterministic final evidence guard**:
  `Sources/RielaCore/DeterministicWorkflowRunner+GitFinalizationEvidence.swift`
  and `DeterministicWorkflowRunner+LoopPolicy.swift` validate exact accepted
  Step 10 and Step 11 evidence, require matching full commit hashes, and reject
  missing, stale, mismatched, or unexpected fields before terminal output
  persistence for the accepted `codex-design-and-implement-review-loop`
  contract. Planning-only output bypasses Git evidence validation, and unrelated
  workflows retain their own contracts. The workflow-output node now declares
  a mode-conditional output JSON schema.
  `Tests/RielaCoreTests/WorkflowGitFinalizationEvidenceTests.swift` and
  `WorkflowModelTests.swift` cover the runtime, mode, and model contracts.
- **Verification**: Xcode-toolchain `swift build` passed. Focused evidence and
  model verification passed 29 tests with zero failures; focused contract and
  recovery verification reported 31 tests with zero failures before its
  wrapper timeout. Aggregate `GitWorkflowAddon` passed 72 tests, full
  `RielaCoreTests` passed 492 tests, and full `RielaCLITests` passed 759 tests,
  all with zero failures. The final CLI wrapper timed out only after its saved
  completion summary. The direct workflow validator returned `valid: true`
  with no diagnostics before its wrapper timeout. Targeted strict SwiftLint
  passed with no diagnostics and a clean exit. Final staged and unstaged diff
  checks, no-deleted-test-lines scan, skipped-test scan, and test discovery
  counts passed.
- **Plan state**: TASK-007 and its deterministic-matrix completion criterion
  are complete again. TASK-008 remains in progress for staging, commit, push,
  archival, and final handoff.
- **Residual risks**: Foreign or orphaned index locks remain operator-owned;
  concurrent remote updates remain fail-closed through non-force push and live
  verification; additional platform Git and credential-helper locations remain
  unsupported.
- **Next**: Complete Step 6 self-review and test-integrity gates, then repeat
  independent Step 7 and the required adversarial review.

### 2026-08-05 - Step 6 Output-Boundary and Index-Entry Revision

- **TASK-007 reopened and completed**: Addressed all three mid-severity
  self-review findings from `comm-000461` without broadening issue ownership.
- **Final output revalidation**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitCommit.swift` now revalidates the
  repository, exact symbolic branch, and candidate revision after the
  output-publication seam for both initial and recovered commits. Deterministic
  tests switch branches at that seam and prove that neither path emits false
  success.
- **Per-worktree index-entry confinement**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitRepository.swift` retains the final
  index path entry instead of resolving through it, requires a single-link
  regular `index` directly inside the validated per-worktree Git directory,
  captures its `lstat` identity, and revalidates it immediately before ref and
  index publication. Contract tests reject both an initial sibling-worktree
  index symlink and post-preflight retargeting without changing either ref or
  the sibling index.
- **Verification**: Focused `GitWorkflowAddonContractTests` and
  `GitWorkflowAddonRecoveryTests` reported 35 tests with zero failures before
  the wrapper timeout. The aggregate Git gate passed 76 tests with zero
  failures and a clean exit. `RielaCLITests` reported 763 tests with zero
  failures before its wrapper timeout. Strict SwiftLint reported no
  diagnostics, both staged and unstaged diff checks passed, no test or
  assertion lines were deleted, and all 76 Git add-on tests remained
  discoverable. The aggregate Git build completed successfully; the standalone
  build wrapper supplied no additional output and was terminated while open.
- **Plan state**: TASK-007 and its deterministic-matrix completion criterion
  are complete again. TASK-008 remains in progress for staging, commit, push,
  archival, and final handoff.
- **Residual risks**: Foreign or orphaned index locks remain operator-owned;
  concurrent remote updates remain fail-closed through non-force push and live
  verification; additional platform Git and credential-helper locations remain
  unsupported.
- **Next**: Repeat Step 6 self-review and test-integrity gates before
  independent Step 7 and the required adversarial review.

### 2026-08-05 - Step 6 Preflight Repository-Binding Revision

- **TASK-007 reopened and completed**: Addressed both mid-severity findings
  from `comm-000463` without expanding the accepted issue scope.
- **Coherent repository discovery**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitRepository.swift` now captures and
  compares two complete Git-directory, common-directory, and exact-index path
  snapshots while also requiring the `.git` entry identity and bounded digest
  to remain unchanged. A temporarily retargeted linked-worktree discovery file
  therefore cannot bind the source worktree to a sibling worktree's ref or
  index.
- **Deterministic regression**:
  `Tests/RielaCLITests/GitWorkflowAddonContractTests.swift` temporarily
  retargets `.git` only during the first discovery pass, restores it in place
  before ordinary publication checks, and proves both worktrees' refs and
  indexes remain unchanged. The focused contract suite passed 19 tests with
  zero failures and a clean exit after correcting the new test's initializer
  argument order. The aggregate Git gate passed 77 tests, full
  `RielaCLITests` passed 764 tests, and strict SwiftLint reported no
  diagnostics, all with clean exits.
- **Plan state**: TASK-007 and its deterministic-matrix completion criterion
  are complete again. TASK-008 remains in progress for staging, commit, push,
  archival, and final handoff.
- **Next**: Repeat Step 6 self-review and test-integrity gates before
  independent Step 7 and the required adversarial review.

### 2026-08-05 - Step 6 Sustained Discovery-ABA Revision

- **TASK-007 reopened and completed**: Addressed the mid-severity finding from
  `comm-000465` without changing the accepted authorization, confinement, or
  mutation scope.
- **Discovery-entry binding**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitRepository.swift` now opens the
  initial `.git` entry without following a final symlink, reads a regular
  discovery file through the bounded descriptor, derives its exact canonical
  `gitdir:` target, and requires that target to equal the per-worktree Git
  directory returned by both path snapshots. The final no-follow discovery
  snapshot must still match the initial identity, digest, and derived target.
- **Deterministic regression**:
  `Tests/RielaCLITests/GitWorkflowAddonContractTests.swift` now retains a
  sibling worktree's `.git` discovery value through both path-discovery passes,
  restores the source value only before final discovery verification, and
  proves both worktrees' refs, indexes, and lock paths remain unchanged.
- **Verification**: Xcode-toolchain `swift test --filter
  GitWorkflowAddonContractTests` passed 20 tests, aggregate `swift test
  --filter GitWorkflowAddon` passed 78 tests, and full `swift test --filter
  RielaCLITests` passed 765 tests, all with zero failures and clean exits.
  Xcode-routed strict SwiftLint passed with no diagnostics for the revised
  source and test files.
- **Plan state**: TASK-007 and the deterministic-matrix completion criterion
  are complete again. TASK-008 remains in progress for staging, commit, push,
  archival, and final handoff.
- **Next**: Repeat Step 6 self-review, test-integrity, independent Step 7, and
  required adversarial review gates before TASK-008 finalization.

### 2026-08-05 - Step 6 Persistent Linked-Worktree Backpointer Revision

- **TASK-007 reopened and completed**: Addressed both mid-severity findings
  from `comm-000467` without expanding the accepted authorization or mutation
  scope.
- **Reciprocal linked-worktree binding**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitRepository.swift` now opens the
  selected per-worktree Git directory's `gitdir` backpointer without following
  its final path entry, reads it through the bounded descriptor, and requires
  it to identify the exact source worktree `.git` path. The backpointer path,
  filesystem identity, and digest are persisted in the journal repository
  identity and revalidated before mutation.
- **Deterministic regression**:
  `Tests/RielaCLITests/GitWorkflowAddonContractTests.swift` retargets the source
  `.git` file to a sibling before repository loading, retains that value
  throughout execution, and proves both worktrees' refs, indexes, and lock
  paths remain unchanged.
- **Verification**: Xcode-toolchain `swift test --filter
  GitWorkflowAddonContractTests` passed 21 tests with zero failures and a clean
  exit. Aggregate `swift test --filter GitWorkflowAddon` reported 79 tests with
  zero failures before its wrapper timeout. Full `swift test --filter
  RielaCLITests` reported 766 tests with zero failures before bounded wrapper
  termination. Direct strict SwiftLint passed with no diagnostics for the
  revised source and test files; staged and unstaged diff checks, test-integrity
  checks, JSON validation, and the no-TypeScript-change check passed.
- **Plan state**: TASK-007 and the deterministic-matrix completion criterion
  are complete again. TASK-008 remains in progress for staging, commit, push,
  archival, and final handoff.
- **Next**: Repeat Step 6 self-review, test-integrity, independent Step 7, and
  required adversarial review gates before TASK-008 finalization.

### 2026-08-05 - Step 6 Terminal Evidence Mode-Binding Revision

- **TASK-007 reopened and completed**: Addressed the mid-severity Step 7
  finding from `comm-000471` without changing the accepted commit, push, or
  retry contracts.
- **Runtime-owned workflow mode**:
  `Sources/RielaCore/DeterministicWorkflowRunner+GitFinalizationEvidence.swift`
  now derives the terminal mode from persisted executed routing: a completed
  accepted `step6-implement` proves `issue-resolution`, while an accepted
  `step5-impl-plan-review` planning decision proves `design-plan-only`.
  Terminal output must match that mode, and every terminal route now validates
  exact accepted Step 10 and Step 11 evidence unconditionally.
- **Output contract**: The `design-plan-only` branch in
  `.riela/workflows/codex-design-and-implement-review-loop/nodes/node-workflow-output.json`
  now requires `commitMessage`, `commitHash`, `pushedRemote`, and
  `pushedBranch`, matching the existing planning-output prompt and the shared
  commit/push route.
- **Deterministic coverage**:
  `Tests/RielaCoreTests/WorkflowGitFinalizationEvidenceTests.swift` rejects an
  issue-resolution-to-planning downgrade and missing or mismatched planning
  evidence while accepting exact evidence for both modes.
  `Tests/RielaCoreTests/WorkflowModelTests.swift` proves both schema branches
  require the finalization fields.
- **Verification**: The Xcode-toolchain focused evidence/model selection passed
  31 tests with zero failures; full `RielaCoreTests` passed 494 tests with zero
  failures. Xcode-routed strict SwiftLint passed for the four revised Swift
  files with no diagnostics. Workflow validation returned `valid: true` with
  no diagnostics. Final staged and unstaged diff checks and JSON parsing passed.
- **Plan state**: TASK-007 and its deterministic-matrix completion criterion
  are complete again. TASK-008 remains in progress for staging, commit, push,
  archival, and final handoff.
- **Residual risks**: Foreign or orphaned index locks remain operator-owned;
  concurrent remote updates remain fail-closed through non-force push and live
  verification; additional platform Git and credential-helper locations remain
  unsupported.
- **Next**: Repeat Step 6 self-review and test-integrity, then independent Step
  7 and the required adversarial review before TASK-008 finalization.

### 2026-08-05 - Step 6 Feature-Fanout Mode-Evidence Revision

- **TASK-007 reopened and completed**: Addressed the mid-severity self-review
  finding from `comm-000473` without changing the accepted Git transaction,
  authorization, push, or retry contracts.
- **Workflow-derived planning evidence**:
  `Sources/RielaCore/DeterministicWorkflowRunner+GitFinalizationEvidence.swift`
  now derives the eligible planning-decision step IDs from workflow transitions
  that route directly into commit preparation under `planning_only`. Both the
  sequential `step5-impl-plan-review` route and the feature-fanout
  `step5-feature-plan-join` route therefore supply persisted authoritative mode
  evidence to the terminal guard.
- **Deterministic coverage**:
  `Tests/RielaCoreTests/WorkflowGitFinalizationEvidenceTests.swift` now proves
  exact finalization evidence succeeds for feature-fanout planning-only output.
  `Tests/RielaCoreTests/WorkflowModelTests.swift` proves policy discovery binds
  both planning decision steps.
- **Verification**: The Xcode-toolchain focused evidence/model selection passed
  32 tests with zero failures; full `RielaCoreTests` passed 495 tests with zero
  failures. Strict SwiftLint passed with no diagnostics for the three revised
  Swift files. Workflow validation returned `valid: true` with no diagnostics;
  JSON parsing, staged and unstaged diff checks, and the no-TypeScript-change
  check passed.
- **Plan state**: TASK-007 and its deterministic-matrix completion criterion
  are complete again. TASK-008 remains in progress for staging, commit, push,
  archival, and final handoff.
- **Residual risks**: Foreign or orphaned index locks remain operator-owned;
  concurrent remote updates remain fail-closed through non-force push and live
  verification; additional platform Git and credential-helper locations remain
  unsupported.
- **Next**: Repeat Step 6 self-review and test-integrity, then independent Step
  7 and the required adversarial review before TASK-008 finalization.

### 2026-08-05 - Step 7 Retry Journal and Index-Identity Revision

- **TASK-007 reopened and completed**: Addressed both mid-severity findings
  from `comm-000477` without changing the accepted authorization, staging,
  publication, or push contracts.
- **Cross-attempt index identity**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitFinalizationStore.swift` and
  `Sources/RielaCLI/ProductionNodeAdapter+GitRepository.swift` now persist the
  canonical index path-entry device and inode in repository identity. Retry
  requires that exact identity while the canonical index still has the
  journaled original bytes, while retaining the expected completed-state path
  where owned atomic index publication changed the inode and the prepared
  digest plus exact reflog prove completion.
- **Semantic journal integrity**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitFinalizationStore.swift` binds
  execution links to the canonical journal-byte digest.
  `Sources/RielaCLI/ProductionNodeAdapter+GitCommit.swift` recomputes rendered
  input and journal identities, validates canonical ref/hash/token/path fields,
  proves the prepared index tree, and verifies the candidate commit's exact
  parent, tree, message, author, and committer before retry reconciliation.
- **Deterministic coverage**:
  `Tests/RielaCLITests/GitWorkflowAddonRecoveryTests.swift` rejects a
  byte-identical index replacement between journaled attempts and rejects
  well-formed message and candidate-commit journal tampering after independently
  updating the link digest. Existing multi-attempt, output-publication,
  branch-race, and successful completed-state recovery coverage remains green.
- **Verification**: Xcode-toolchain `swift test --filter
  GitWorkflowAddonRecoveryTests` passed 19 tests with zero failures;
  `swift test --filter GitWorkflowAddon` passed 81 tests with zero failures;
  and `swift test --filter RielaCLITests` passed 768 tests with zero failures and
  a clean exit. Direct strict SwiftLint passed with no diagnostics for the four
  revised Swift files. The focused and aggregate Git wrappers remained open
  after their successful summaries and were bounded. Final staged and unstaged
  diff checks passed.
- **Plan state**: TASK-007 and its deterministic-matrix completion criterion
  are complete again. TASK-008 remains in progress for staging, commit, push,
  archival, and final handoff.
- **Residual risks**: Foreign or orphaned index locks remain operator-owned;
  concurrent remote updates remain fail-closed through non-force push and live
  verification; additional platform Git and credential-helper locations remain
  unsupported.
- **Next**: Repeat Step 6 self-review and test-integrity, then independent Step
  7 and the required adversarial review before TASK-008 finalization.

### 2026-08-05 - Step 7 Adversarial Transport and Evidence-Policy Revision

- **TASK-007 reopened and completed**: Addressed the high- and mid-severity
  adversarial findings from `comm-000482` without weakening authorization,
  repository confinement, retry, or network push verification.
- **Local receiver execution blocked**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitPush.swift` now applies a
  production version-one transport policy that rejects absolute-path and
  `file://` push transports before remote queries or push. Deterministic test
  fixtures may inject a local-only policy, but repository or workflow input
  cannot override the production policy.
- **Receiver-hook regression**:
  `Tests/RielaCLITests/GitWorkflowAddonAdversarialTests.swift` installs an
  executable `post-receive` hook in a local bare remote and proves the
  production resolver returns `policyBlocked` before the hook runs or the
  remote ref changes.
- **Terminal evidence fails closed**:
  `Sources/RielaCore/DeterministicWorkflowRunner+GitFinalizationEvidence.swift`
  and `Sources/RielaCore/DeterministicWorkflowRunner+LoopPolicy.swift` bind the
  protected workflow and terminal step explicitly, require unique version-one
  commit and push nodes, and reject output when policy construction fails.
  Intermediate post-push steps, renamed planning labels, missing Git nodes, and
  ambiguous Git nodes can no longer silently remove terminal evidence checks.
- **Deterministic coverage**:
  `Tests/RielaCoreTests/WorkflowModelTests.swift` covers each protected topology
  drift, and `Tests/RielaCLITests/GitWorkflowAddonTests.swift` keeps existing
  local bare-remote success cases behind an injected test-only transport policy.
- **Documentation**:
  `design-docs/specs/node-addon-catalog-and-chat-reply-worker/core-built-in-workers.md`
  now defines HTTPS, SSH, and SCP-like forms as the version-one production push
  transports and explains why local and file transports are rejected.
- **Verification**: The Xcode-toolchain focused adversarial/model selection
  passed 41 tests with zero failures. Aggregate `GitWorkflowAddon` passed 82,
  full `RielaCoreTests` passed 496, and full `RielaCLITests` passed 769 tests,
  all with zero failures; the aggregate wrappers were bounded only after their
  successful summaries. Direct strict SwiftLint passed with no diagnostics for
  the seven revised Swift files. `swift build` completed, workflow validation
  returned `valid: true` with no diagnostics, and final staged and unstaged diff
  checks passed.
- **Plan state**: TASK-007 and its deterministic-matrix completion criterion
  are complete again. TASK-008 remains in progress for allowlisted staging,
  commit, same-name upstream push, archival, and final handoff.
- **Residual risks**: Foreign or orphaned index locks remain operator-owned;
  concurrent network-remote updates remain fail-closed through non-force push
  and live verification; additional platform Git and credential-helper
  locations remain unsupported.
- **Next**: Repeat Step 6 self-review and test-integrity, then independent Step
  7 and the required adversarial review before TASK-008 finalization.

### 2026-08-05 - Step 7 Global Topology and Evidence-Freshness Revision

- **TASK-007 reopened and completed**: Addressed both mid-severity findings
  from `comm-000486` without changing the accepted Git authorization,
  transaction, transport, or terminal-output contracts.
- **Global protected topology**:
  `Sources/RielaCore/DeterministicWorkflowRunner+GitFinalizationEvidence.swift`
  now requires exactly one version-one Git commit node and one version-one Git
  push node across the protected workflow, exactly one step for each node, and
  exact commit-to-push-to-terminal transitions. Detached, reused, or
  out-of-chain Git mutation nodes therefore invalidate the protected policy
  instead of escaping terminal evidence enforcement.
- **Fresh terminal evidence**: Required Git evidence now comes only from the
  latest execution for each protected step. A newer failed or running attempt
  blocks terminal acceptance instead of exposing an older completed payload as
  current finalization evidence.
- **Deterministic coverage**:
  `Tests/RielaCoreTests/WorkflowModelTests.swift` rejects detached push and
  out-of-chain commit nodes, while
  `Tests/RielaCoreTests/WorkflowGitFinalizationEvidenceTests.swift` rejects an
  older accepted commit or push payload followed by either a failed or running
  attempt.
- **Verification**: The Xcode-toolchain focused selection
  `swift test --filter 'WorkflowGitFinalizationEvidenceTests|WorkflowModelTests'`
  passed 34 tests with zero failures. Full `RielaCoreTests` passed 497 tests
  with zero failures, and full `RielaCLITests` passed 769 tests with zero
  failures. Targeted strict SwiftLint completed with no diagnostics for the
  three revised Swift files. The successful SwiftPM wrappers required bounded
  termination after their zero-failure summaries.
- **Plan state**: TASK-007 and its deterministic-matrix completion criterion
  are complete again. TASK-008 remains in progress for allowlisted staging,
  commit, same-name upstream push, archival, and final handoff.
- **Residual risks**: Foreign or orphaned index locks remain operator-owned;
  concurrent network-remote updates remain fail-closed through non-force push
  and live verification; additional platform Git and credential-helper
  locations remain unsupported.
- **Next**: Repeat Step 6 self-review and test-integrity, then independent Step
  7 and the required adversarial review before TASK-008 finalization.

### 2026-08-05 - Step 7 Repository-Metadata and SHA-256 Revision

- **TASK-007 reopened and completed**: Addressed all five mid-severity findings
  delivered by Step 7 in `comm-000490` for workflow execution
  `codex-design-and-implement-review-loop-session-48` without weakening the
  accepted authorization, confinement, retry, or non-force push contracts.
- **Common-directory identity binding**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitRepository.swift` now opens a
  linked worktree's `commondir` file with no-follow, nonblocking semantics,
  validates its bounded content and exact `<common>/worktrees/<name>` layout,
  and binds its device, inode, and digest into both preflight passes and every
  repository-operation identity check.
- **Object database and format binding**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitRepository.swift` requires the
  lexical `<common>/objects` entry to be a non-symlink directory, retains its
  filesystem identity, and accepts only a discovered `sha1` or `sha256` object
  format. `Sources/RielaCLI/ProductionNodeAdapter+GitPush.swift` revalidates
  that identity before transport setup and initializes the isolated bare
  repository with the same explicit object format.
- **Descriptor-bound canonical index reads**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitCommit.swift` and
  `Sources/RielaCLI/ProductionNodeAdapter+GitRepository.swift` open initial and
  retry index reads with `O_NOFOLLOW | O_NONBLOCK`, validate the descriptor's
  type, size, link count, device, and inode, enforce the workflow deadline, and
  digest only bytes read through that descriptor.
- **Journal identity extension**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitFinalizationStore.swift` includes
  the commondir binding, object-directory identity, and object format in the
  repository identity used by journal keys and retry validation.
- **Deterministic coverage**:
  `Tests/RielaCLITests/GitWorkflowAddonContractTests.swift` rejects a
  post-preflight commondir retarget, escaped object-directory symlink, canonical
  index symlink swap, and canonical index FIFO without blocking.
  `Tests/RielaCLITests/GitWorkflowAddonTests.swift` creates a SHA-256 source and
  bare remote, commits a 64-character object id, and proves isolated push and
  remote verification succeed. `Tests/RielaCLITests/GitWorkflowAddonRecoveryTests.swift`
  retains constructor coverage for the expanded journal identity.
- **Documentation**:
  `design-docs/specs/node-addon-catalog-and-chat-reply-worker/core-built-in-workers.md`
  records the no-follow commondir/object/index invariants and explicit source
  object-format propagation.
- **Verification**: Xcode-toolchain focused Git selection passed 87 tests with
  zero failures; full `RielaCoreTests` passed 497 and full `RielaCLITests`
  passed 774 tests with zero failures. Direct strict SwiftLint reported 0
  violations in the seven revised Swift files before its already-known wrapper
  was bounded after the completed summary. `swift build` completed, workflow
  validation returned `valid: true` with no diagnostics, and final staged and
  unstaged diff checks passed.
- **Plan state**: TASK-007 and its deterministic-matrix completion criterion
  are complete again. TASK-008 remains in progress for allowlisted staging,
  commit, same-name upstream push, archival, and final handoff.
- **Residual risks**: Foreign or orphaned index locks remain operator-owned;
  concurrent network-remote updates remain fail-closed through non-force push
  and live verification; additional platform Git and credential-helper
  locations remain unsupported.
- **Next**: Independent Step 7 implementation review, followed by the required
  adversarial review before TASK-008 finalization.

### 2026-08-05 - Step 7 Retry-Ancestry and Nonblocking-Open Revision

- **TASK-007 reopened and completed**: Addressed both mid-severity findings from
  `comm-000494` for workflow execution
  `codex-design-and-implement-review-loop-session-48` without weakening the
  accepted authorization, immutable-journal, repository-confinement, or
  deadline contracts.
- **Initial retry ancestry revision**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitCommit.swift` now creates the
  current execution's alias to a discovered immutable predecessor journal
  before fallible journal validation. This covered post-discovery failures but
  not a repository-preflight failure before journal discovery; the later
  self-review revision below supersedes this ancestry mechanism.
- **Nonblocking repository opens**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitRepository.swift` adds
  `O_NONBLOCK` to no-follow `.git` discovery, linked-worktree `gitdir`
  backpointer, and final worktree-file opens. Descriptor type validation rejects
  FIFO replacements without waiting beyond the workflow deadline.
- **Deterministic coverage**:
  `Tests/RielaCLITests/GitWorkflowAddonRecoveryTests.swift` proves a completed
  first attempt, transient second-attempt validation failure, subsequent
  allowlisted worktree edit, and third-attempt recovery do not create a second
  commit. `Tests/RielaCLITests/GitWorkflowAddonNonblockingTests.swift` covers
  worktree, `.git` discovery, and linked-worktree backpointer FIFO races. The
  responsibility-specific file keeps every changed Swift file below 1,000
  lines.
- **Documentation**:
  `design-docs/specs/node-addon-catalog-and-chat-reply-worker/core-built-in-workers.md`
  now records early retry aliasing and nonblocking no-follow repository opens.
- **Verification**: The Xcode-toolchain focused selection
  `swift test --filter 'GitWorkflowAddonNonblockingTests|GitWorkflowAddonRecoveryTests'`
  passed 23 tests with zero failures. The combined `RielaCLITests` and
  `RielaCoreTests` selection passed 1,275 tests with zero failures before the
  already-known SwiftPM wrapper was bounded after its completed summary.
  Targeted strict SwiftLint completed with zero violations in the five changed
  Swift files.
- **Plan state**: TASK-007 and its deterministic-matrix completion criterion
  are complete again. TASK-008 remains in progress for allowlisted staging,
  commit, same-name upstream push, archival, and final handoff.
- **Residual risks**: Foreign or orphaned index locks remain operator-owned;
  concurrent network-remote updates remain fail-closed through non-force push
  and live verification; additional platform Git and credential-helper
  locations remain unsupported.
- **Next**: Repeat Step 6 self-review and test-integrity, then independent Step
  7 and the required adversarial review before TASK-008 finalization.

### 2026-08-05 - Step 6 Self-Review Preflight-Ancestry Revision

- **TASK-007 reopened and completed**: Addressed the remaining mid-severity
  finding from `comm-000496` for workflow execution
  `codex-design-and-implement-review-loop-session-48` without preparing or
  writing finalization storage against an unvalidated repository root.
- **Runtime-owned ancestry**:
  `Sources/RielaCore/WorkflowAddonExecution.swift` and
  `Sources/RielaCore/DeterministicWorkflowRunner+Addons.swift` now carry the
  ordered execution ids of every consecutive unaccepted predecessor, newest
  first, alongside the immediate predecessor id. Authored variables and add-on
  configuration still cannot control these identities, and a completed loop
  invocation remains an ancestry boundary.
- **Confined recovery lookup**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitCommit.swift` searches that bounded,
  unique ancestry for the newest available immutable journal only after Git
  repository and finalization-store confinement validation. It links the
  current execution before journal validation and reconciliation. A retryable
  preflight failure can therefore leave no alias without hiding an earlier
  journal from the next attempt.
- **Deterministic coverage**:
  `Tests/RielaCoreTests/WorkflowAddonExecutionIdentityTests.swift` proves the
  runner carries two consecutive failed execution ids and clears ancestry
  after accepted loop progress.
  `Tests/RielaCLITests/GitWorkflowAddonRecoveryTests.swift` proves a completed
  first commit, retryable second-attempt `--show-toplevel` failure, subsequent
  allowlisted edit, and third-attempt recovery retain the original commit with
  exactly two commits in history. The existing post-discovery validation test
  remains intact.
- **Documentation**:
  `design-docs/specs/node-addon-catalog-and-chat-reply-worker/core-built-in-workers.md`
  now records ordered runtime ancestry and safe post-confinement journal lookup.
- **Verification**: The Xcode-toolchain focused selection
  `swift test --filter 'GitWorkflowAddonRecoveryTests|GitWorkflowAddonNonblockingTests|WorkflowAddonExecutionIdentityTests'`
  passed 33 tests with zero failures. The combined `RielaCLITests` and
  `RielaCoreTests` selection passed 1,277 tests with zero failures. `swift
  build` completed successfully. Targeted strict SwiftLint completed with zero
  violations in six changed Swift files.
- **Plan state**: TASK-007 and its deterministic-matrix completion criterion
  are complete again. TASK-008 remains in progress for allowlisted staging,
  commit, same-name upstream push, archival, and final handoff.
- **Residual risks**: Foreign or orphaned index locks remain operator-owned;
  concurrent network-remote updates remain fail-closed through non-force push
  and live verification; additional platform Git and credential-helper
  locations remain unsupported.
- **Next**: Repeat Step 6 self-review and test-integrity, then independent Step
  7 and the required adversarial review before TASK-008 finalization.

### 2026-08-05 - Step 6 Identity, File-Mode, URL, and Diagnostic Revision

- **TASK-007 reopened and completed**: Addressed all four mid-severity findings
  from `comm-000500` for workflow execution
  `codex-design-and-implement-review-loop-session-48` without weakening
  authorization, repository confinement, exact staging, or transport policy.
- **Git identity precedence**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitCommit.swift` resolves
  `author.name`/`author.email` and `committer.name`/`committer.email`
  independently before falling back to `user.name`/`user.email`, then snapshots
  the bounded values for commit creation and retry evidence.
- **Tracked file modes**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitCommit.swift` snapshots effective
  `core.filemode`; `Sources/RielaCLI/ProductionNodeAdapter+GitRepository.swift`
  reads the exact prepared-index stage-zero mode and preserves it when
  executable-bit tracking is disabled, including the existing symlink mode.
- **HTTPS policy and diagnostics**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitPush.swift` rejects decoded HTTPS
  whitespace/control characters and malformed or out-of-range ports without
  reading Foundation's trapping `URLComponents.port` accessor.
  `Sources/RielaCLI/ProductionNodeAdapter+GitAddons.swift` preserves typed
  adapter failures and converts other filesystem/runtime failures to one
  bounded, path-free, retryable diagnostic.
- **Deterministic coverage**:
  `Tests/RielaCLITests/GitWorkflowAddonReviewRegressionTests.swift` proves
  author/committer-specific precedence, both tracked executable-mode
  directions under `core.filemode=false`, percent-decoded HTTPS and invalid-port
  rejection before network access, and path-free Foundation failure mapping.
- **Documentation**:
  `design-docs/specs/node-addon-catalog-and-chat-reply-worker/core-built-in-workers.md`
  now records the implementation-proven identity, file-mode, decoded-URL, and
  diagnostic contracts.
- **Verification**: Xcode-toolchain `swift test --filter
  GitWorkflowAddonReviewRegressionTests` passed 4 tests with zero failures;
  aggregate `swift test --filter GitWorkflowAddon` passed 96 tests with zero
  failures; and combined `swift test --filter 'RielaCLITests|RielaCoreTests'`
  passed 1,281 tests with zero failures. The aggregate SwiftPM wrappers were
  bounded only after their successful summaries. `swift build` reported
  `Build complete`. Targeted strict SwiftLint reported zero violations in the
  five changed Swift files before its completed wrapper was bounded. Workflow
  validation returned `valid: true` with no diagnostics. `git diff --check`,
  `git diff --cached --check`, and the deleted-test/discovery check passed.
- **Plan state**: TASK-007 and its deterministic-matrix completion criterion
  are complete again. TASK-008 remains in progress for allowlisted staging,
  commit, same-name upstream push, archival, and final handoff.
- **Residual risks**: Foreign or orphaned index locks remain operator-owned;
  concurrent network-remote updates remain fail-closed through non-force push
  and live verification; additional platform Git and credential-helper
  locations remain unsupported. No commit or push has been performed.
- **Next**: Repeat Step 6 self-review and test-integrity, then independent Step
  7 and the required adversarial review before TASK-008 finalization.

### 2026-08-05 - Step 6 Recovery-Record Error Classification Revision

- **TASK-007 reopened and completed**: Addressed the mid-severity self-review
  finding from `comm-000502` for workflow execution
  `codex-design-and-implement-review-loop-session-48` without weakening the
  path-free diagnostic boundary for transient Foundation failures.
- **Permanent recovery-state classification**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitFinalizationStore.swift` now maps
  missing immutable journals, missing predecessor links, and malformed journal
  or link JSON to bounded, path-free, non-retryable `policyBlocked` errors.
  Other Foundation filesystem failures continue to reach the add-on boundary
  as bounded, path-free, retryable `providerError` failures.
- **Deterministic coverage**:
  `Tests/RielaCLITests/GitWorkflowAddonRecoveryTests.swift` now asserts error
  code, retryability, bounded messages, and repository/finalization-path
  redaction for missing or corrupt journals and corrupt predecessor links.
- **Documentation**:
  `design-docs/specs/node-addon-catalog-and-chat-reply-worker/core-built-in-workers.md`
  now distinguishes permanent immutable-record policy failures from transient
  storage-provider failures.
- **Verification**: Xcode-toolchain `swift test --filter
  GitWorkflowAddonRecoveryTests` passed 21 tests with zero failures;
  `swift test --filter GitWorkflowAddon` passed 96 tests with zero failures;
  and `swift test --filter RielaCLITests` passed 783 tests with zero failures.
  The unchanged Core suite retains the 498-test passing result contained in the
  1,281-test aggregate evidence from `comm-000501`. `swift build` reported
  `Build complete` before its wrapper timeout. Targeted strict SwiftLint found
  zero violations in the two changed Swift files.
- **Plan state**: TASK-007 and its deterministic-matrix completion criterion
  are complete again. TASK-008 remains in progress for allowlisted staging,
  commit, same-name upstream push, archival, and final handoff.
- **Residual risks**: Foreign or orphaned index locks remain operator-owned;
  concurrent network-remote updates remain fail-closed through non-force push
  and live verification; additional platform Git and credential-helper
  locations remain unsupported. No commit or push has been performed.
- **Next**: Repeat Step 6 self-review and test-integrity, then independent Step
  7 and the required adversarial review before TASK-008 finalization.

### 2026-08-06 - Step 7 Finalization-Authorization and Publication Revision

- **Accepted-plan alignment**: Reconfirmed full `issue-resolution` mode and the
  Step 4/5 contract before changing the candidate. TASK-007 was reopened and
  completed for every high or mid finding supplied by
  `codex-design-and-implement-review-loop-session-49` Step 6; the explicit
  authorization, exact staging, immutable recovery, non-force push, and
  terminal evidence contracts were not weakened.
- **Recovery and diagnostic findings**: Retained the prior permanent
  `policyBlocked` classification for missing or malformed immutable journal and
  predecessor-link records, while transient Foundation failures remain a
  bounded, path-free retryable provider error. The earlier executable-mode,
  decoded-HTTPS, and diagnostic findings remain covered by focused regression
  tests.
- **Push authorization**: `.riela/workflows/codex-design-and-implement-review-loop/workflow.json`
  now renders the exact accepted Step 10 `commitHash` into Step 11 through
  `expectedCommitHashTemplate`. `Sources/RielaCLI/ProductionNodeAdapter+GitPush.swift`
  validates a full lowercase SHA-1 or SHA-256 id and requires current `HEAD` to
  equal it before live remote access or mutation. The isolated transport
  repository is therefore pinned to the authorized commit rather than a later
  concurrent local commit.
- **File-mode correctness**: `Sources/RielaCLI/ProductionNodeAdapter+GitRepository.swift`
  preserves only executable-bit state when `core.filemode=false`; with normal
  symlink checkout behavior, replacing a tracked symlink with a regular file
  records the regular-file mode exactly as native `git add` does.
- **Owned-lock lifetime**: `Sources/RielaCLI/ProductionNodeAdapter+GitCommit.swift`
  retains the open owned index-lock descriptor through ref update, identity
  revalidation, atomic index publication, directory synchronization, and final
  branch verification. Cleanup removes only the still-identity-matching owned
  lock and never a replacement.
- **Terminal evidence**: `Sources/RielaCore/DeterministicWorkflowRunner+GitFinalizationEvidence.swift`
  now rejects equal but noncanonical hashes unless both accepted evidence
  values are full 40- or 64-character lowercase hexadecimal object ids.
- **Deterministic coverage and maintainability**:
  `Tests/RielaCLITests/GitWorkflowAddonReviewRegressionTests.swift`,
  `Tests/RielaCLITests/GitWorkflowAddonRecoveryTests.swift`,
  `Tests/RielaCoreTests/WorkflowGitFinalizationEvidenceTests.swift`, and
  `Tests/RielaCoreTests/WorkflowModelTests.swift` cover the four new review
  boundaries. Recovery-only injectors moved to
  `Tests/RielaCLITests/GitWorkflowAddonRecoveryTestSupport.swift`, reducing the
  recovery suite from 1,014 to 968 lines without changing behavior.
- **Verification**: Xcode-toolchain
  `swift test --filter 'GitWorkflowAddonReviewRegressionTests|GitWorkflowAddonRecoveryTests|WorkflowGitFinalizationEvidenceTests|WorkflowModelTests'`
  passed 64 tests; `swift test --filter GitWorkflowAddon` passed 100 tests;
  `swift build` completed; and
  `swift test --filter 'RielaCLITests|RielaCoreTests'` passed 1,286 tests, all
  with zero failures. `swift run riela workflow validate
  codex-design-and-implement-review-loop --workflow-definition-dir
  .riela/workflows --output json` returned `valid: true` with no diagnostics.
  Xcode `xcrun swiftlint lint --strict --no-cache` reported zero violations in
  the 11 revised Git/evidence/test files. `git diff --check`, `git diff
  --cached --check`, and the untracked-file whitespace check passed. No
  applicable `riela-package.json` exists, so no digest refresh is required.
- **Plan state**: TASK-007 and its no-known-high-or-mid completion criterion are
  complete again. TASK-008 remains in progress for documentation finalization,
  allowlisted staging, commit, same-name upstream push, archival, and final
  handoff; Step 6 performed no commit or push.
- **Residual risks**: Foreign or orphaned index locks remain operator-owned;
  concurrent remote updates remain fail-closed through non-force push and live
  verification; additional platform Git and credential-helper locations remain
  unsupported.
- **Next**: Independent Step 7 adversarial implementation review.

### 2026-08-06 - Step 7 Authorization, Mode, Lock-Identity, and Evidence Revision

- **TASK-007 reopened and completed**: Addressed every high- and mid-severity
  finding supplied to `step6-implement` for workflow execution
  `codex-design-and-implement-review-loop-session-50`, preserving the accepted
  explicit-authorization, exact-staging, crash-recovery, and non-force-push
  contracts.
- **Accepted-commit push authorization**:
  `.riela/workflows/codex-design-and-implement-review-loop/workflow.json` passes
  the accepted Step 10 `commitHash` through `expectedCommitHashTemplate`, and
  `Sources/RielaCLI/ProductionNodeAdapter+GitPush.swift` requires that full
  lowercase object ID to equal current `HEAD` before any live remote query or
  push. `Tests/RielaCLITests/GitWorkflowAddonReviewRegressionTests.swift`
  proves a concurrent local commit is rejected before live access and remains
  absent from the remote.
- **Tracked symlink transition**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitRepository.swift` preserves mode
  `120000` only for the regular worktree representation used when effective
  `core.symlinks=false`; otherwise a tracked symlink replaced by a regular file
  records the regular-file mode even when `core.filemode=false`. The review
  regression suite proves the resulting tree mode is `100644`.
- **Owned-lock lifetime and identity**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitCommit.swift` keeps the exclusively
  created index-lock descriptor open through ref update, atomic index
  publication, or owned cleanup. Descriptor and path identities are checked
  before publication, so the open inode cannot be reused to disguise a
  replacement. New post-ref-update failure injection proves a foreign
  replacement is detected, preserved, and never published as the canonical
  index.
- **Canonical terminal evidence**:
  `Sources/RielaCore/DeterministicWorkflowRunner+GitFinalizationEvidence.swift`
  independently requires commit and push hashes to be lowercase full SHA-1 or
  SHA-256 object IDs before equality and exact terminal-output consumption.
  `Tests/RielaCoreTests/WorkflowGitFinalizationEvidenceTests.swift` rejects
  abbreviated, uppercase, and wrong-length hashes.
- **Carried-forward review closures**: Executable-mode preservation, decoded
  HTTPS validation, path-free Foundation diagnostics, and permanent malformed
  recovery-record classification remain covered by
  `GitWorkflowAddonReviewRegressionTests` and
  `GitWorkflowAddonRecoveryTests`; the generic retryable boundary is reached
  only for transient non-typed filesystem/runtime failures.
- **Plan state**: TASK-007 and the associated completion criteria are complete
  again. TASK-008 remains in progress for allowlisted staging, commit,
  same-name upstream push, archival, and final handoff after independent Step 7
  and adversarial review gates pass.
- **Residual risks**: Foreign or orphaned index locks remain operator-owned;
  concurrent network-remote updates remain fail-closed through non-force push
  and live verification; additional platform Git and credential-helper
  locations remain unsupported. No commit or push has been performed.
- **Next**: Run focused and aggregate Swift verification, workflow validation,
  strict SwiftLint, test-integrity discovery, and staged/unstaged ownership
  checks; then return to independent Step 7 review.

### 2026-08-06 - Step 6 Immutable Finalization-Record Read Revision

- **Accepted-plan alignment**: Reconfirmed full `issue-resolution` mode and the
  Step 4/5 contract before changing the candidate. TASK-007 was reopened and
  completed for the mid-severity self-review finding delivered by
  `comm-000508` in workflow execution
  `codex-design-and-implement-review-loop-session-49`; authorization, exact
  staging, immutable recovery, non-force push, and terminal evidence contracts
  remain unchanged.
- **Descriptor-bound persistence reads**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitFinalizationStore.swift` routes
  create-only collision, journal, predecessor-link, and prepared-index reads
  through one `O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC` descriptor reader. It
  requires a bounded single-link regular file, enforces the workflow deadline,
  reads only from the opened descriptor, and verifies stable descriptor and
  path identity before accepting bytes. Missing required recovery state stays
  a path-free non-retryable policy failure; transient non-typed I/O failures
  still reach the bounded retryable provider boundary.
- **Deterministic coverage**:
  `Tests/RielaCLITests/GitWorkflowAddonFinalizationStoreReadTests.swift` proves
  create-only FIFO collisions return promptly, matching journal symlinks are
  not followed, oversized sparse prepared indexes are rejected before loading,
  and predecessor-link replacement during an opened read fails closed.
  `Tests/RielaCLITests/GitWorkflowAddonRecoveryTests.swift` exposes its existing
  finalization-store fixture for the responsibility-focused suite without
  changing test behavior.
- **Documentation and criteria**:
  `design-docs/specs/node-addon-catalog-and-chat-reply-worker/core-built-in-workers.md`
  records the no-follow/nonblocking immutable-record read boundary. The
  completion criteria now explicitly require bounded descriptor reads and
  replacement rejection for journals, links, prepared indexes, and collisions.
- **Verification**: Xcode-toolchain
  `swift test --filter 'GitWorkflowAddonStoreReadTests|GitWorkflowAddonRecoveryTests'`
  passed 26 tests; `swift test --filter GitWorkflowAddon` passed 104 tests;
  `swift build` completed; and
  `swift test --filter 'RielaCLITests|RielaCoreTests'` passed 1,290 tests, all
  with zero failures. `swift run riela workflow validate
  codex-design-and-implement-review-loop --workflow-definition-dir
  .riela/workflows --output json` returned `valid: true` with no diagnostics.
  Xcode `xcrun swiftlint lint --strict --no-cache` reported zero violations in
  the three revised Swift files. No TypeScript file changed, so TypeScript
  post-modification checks do not apply. No applicable `riela-package.json`
  exists, so no digest refresh is required.
- **Plan state**: TASK-007 and the no-known-high-or-mid completion criterion are
  complete again. TASK-008 remains in progress for allowlisted staging,
  commit, same-name upstream push, archival, and final handoff after independent
  Step 7 and adversarial review gates pass; Step 6 performed no commit or push.
- **Residual risks**: Foreign or orphaned index locks remain operator-owned;
  concurrent remote updates remain fail-closed through non-force push and live
  verification; additional platform Git and credential-helper locations remain
  unsupported.
- **Next**: Repeat Step 6 self-review, then return the candidate to independent
  Step 7 adversarial implementation review.

### 2026-08-06 - Step 6 Post-Link Crash-Recovery Revision

- **Accepted-plan alignment**: Reconfirmed full `issue-resolution` mode and the
  Step 4/5 crash-safe idempotence contract. TASK-007 was reopened and completed
  for self-review finding
  `codex-design-and-implement-review-loop-session-49-step6-implement-self-review-attempt-2-finding-1`
  delivered by `comm-000510`; authorization, repository confinement, and
  non-force push behavior remain unchanged.
- **Owned hard-link reconciliation**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitFinalizationStore.swift` now treats
  a multi-link immutable record as recoverable only when every extra link can
  be removed from the no-follow opened runtime-owned temporary directory by
  exact device and inode. The directory removal is synchronized and the opened
  destination must then be the sole stable link. A hard link outside that
  directory remains a non-retryable policy failure, while transient cleanup
  I/O continues through the retryable provider boundary.
- **Deterministic coverage**:
  `Tests/RielaCLITests/GitWorkflowAddonFinalizationStoreReadTests.swift`
  simulates process termination after create-only `link(2)` publication by
  recreating the runtime-owned temporary hard link, proves byte-identical retry
  removes it and succeeds, and separately proves a foreign hard link is
  preserved and rejected.
- **Documentation and criteria**:
  `design-docs/specs/node-addon-catalog-and-chat-reply-worker/core-built-in-workers.md`
  and the completion criteria now distinguish runtime-owned post-link crash
  artifacts from foreign hard links.
- **Verification**: Xcode-toolchain `swift test --filter
  GitWorkflowAddonStoreReadTests` passed 6 tests; `swift test --filter
  'GitWorkflowAddonStoreReadTests|GitWorkflowAddonRecoveryTests'` passed 28;
  `swift test --filter GitWorkflowAddon` passed 106; `swift build` completed;
  and `swift test --filter 'RielaCLITests|RielaCoreTests'` passed 1,292 tests,
  all with zero failures. Workflow validation returned `valid: true` with no
  diagnostics. Xcode `xcrun swiftlint lint --strict --no-cache` reported zero
  violations in the three revised Swift files. No TypeScript file changed and
  no applicable repository-root `riela-package.json` exists.
- **Plan state**: TASK-007 and the no-known-high-or-mid completion criterion are
  complete again. TASK-008 remains in progress pending Step 6 self-review,
  independent Step 7 and adversarial review, allowlisted staging, commit,
  same-name upstream push, archival, and final handoff. No commit or push was
  performed.
- **Residual risks**: Foreign or orphaned index locks remain operator-owned;
  concurrent remote updates remain fail-closed through non-force push and live
  verification; additional platform Git and credential-helper locations remain
  unsupported.
- **Next**: Repeat Step 6 self-review, then return the candidate to independent
  Step 7 adversarial implementation review.

### 2026-08-06 - Step 6 Non-Destructive Hard-Link Validation Revision

- **Accepted-plan alignment**: Reconfirmed full `issue-resolution` mode and the
  Step 4/5 unrelated-work preservation, bounded recovery, and crash-safe
  idempotence contract. TASK-007 was reopened and completed for self-review
  findings
  `codex-design-and-implement-review-loop-session-49-step6-implement-self-review-attempt-3-finding-1`
  and
  `codex-design-and-implement-review-loop-session-49-step6-implement-self-review-attempt-3-finding-2`
  delivered by `comm-000512`; authorization, repository confinement, and
  non-force push behavior remain unchanged.
- **Non-destructive ownership validation**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitFinalizationStore.swift` no longer
  deletes temporary hard-link pathnames during immutable-record recovery.
  Instead, it validates every extra link against the opened record device and
  inode in the pinned runtime temporary directory, repeats that validation
  after the descriptor-bound read, and preserves all entries for bounded
  garbage collection. Replacement can therefore fail closed without deleting
  another session's file.
- **Bounded reconciliation**: Runtime temporary-directory enumeration checks the
  workflow deadline on every iteration and rejects more than 4,096 entries.
  Transient directory I/O continues to the retryable provider boundary while
  an ownership mismatch or entry-limit exhaustion remains a stable policy
  failure.
- **Deterministic coverage**:
  `Tests/RielaCLITests/GitWorkflowAddonFinalizationStoreReadTests.swift` now
  proves post-link crash retry succeeds without deletion, a validated pathname
  replacement is preserved and rejected, expired-deadline enumeration times
  out, entry-limit exhaustion fails closed, and foreign hard links remain
  preserved and rejected.
- **Documentation and criteria**:
  `design-docs/specs/node-addon-catalog-and-chat-reply-worker/core-built-in-workers.md`
  and the completion criteria now require non-destructive, deadline-aware,
  entry-bounded ownership validation before and after immutable-record reads.
- **Verification**: Xcode-toolchain `swift test --filter
  GitWorkflowAddonStoreReadTests` passed 9 tests; `swift test --filter
  'GitWorkflowAddonStoreReadTests|GitWorkflowAddonRecoveryTests'` passed 31;
  `swift test --filter GitWorkflowAddon` passed 109; `swift build` completed;
  and `swift test --filter 'RielaCLITests|RielaCoreTests'` passed 1,295 tests,
  all with zero failures. Workflow validation returned `valid: true` with no
  diagnostics. Xcode `xcrun swiftlint lint --strict --no-cache` reported zero
  violations in the three revised Swift files. `git diff --check` and
  `git diff --cached --check` passed. No TypeScript file changed and no
  applicable repository-root `riela-package.json` exists.
- **Plan state**: TASK-007 and the no-known-high-or-mid completion criterion are
  complete again. TASK-008 remains in progress pending Step 6 self-review,
  independent Step 7 and adversarial review, allowlisted staging, commit,
  same-name upstream push, archival, and final handoff. No commit or push was
  performed.
- **Residual risks**: Foreign or orphaned index locks remain operator-owned;
  concurrent remote updates remain fail-closed through non-force push and live
  verification; additional platform Git and credential-helper locations remain
  unsupported; bounded garbage collection, rather than record reads, removes
  retained post-link crash artifacts.
- **Next**: Repeat Step 6 self-review, then return the candidate to independent
  Step 7 adversarial implementation review.

### 2026-08-06 - Step 6 Identity-Safe Bounded Garbage-Collection Revision

- **Accepted-plan alignment**: Reconfirmed full `issue-resolution` mode and the
  Step 4/5 bounded retention, deadline, and unrelated-work preservation
  contract. TASK-007 was reopened and completed for self-review findings
  `codex-design-and-implement-review-loop-session-49-step6-implement-self-review-attempt-4-finding-1`
  and
  `codex-design-and-implement-review-loop-session-49-step6-implement-self-review-attempt-4-finding-2`
  delivered by `comm-000514`; commit authorization, repository confinement,
  and push behavior remain unchanged.
- **Identity-safe cleanup**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitFinalizationGarbageCollection.swift`
  adds descriptor snapshots and private per-entry quarantine. Garbage
  collection now opens and snapshots an eligible regular file, revalidates the
  pathname, atomically moves it into a new private directory, and deletes it
  only when the quarantined descriptor retains the exact device, inode, mode,
  link count, size, and modification time. A replacement before quarantine is
  preserved; a mismatch after quarantine remains isolated instead of deleted.
- **Bounded maintenance**: Journal, prepared-index, execution-link, temporary,
  and hooks-directory scans are no-follow, deadline-aware, capped at 4,096
  entries, and sorted only after the bound is established. Execution links are
  decoded once and grouped by journal key to avoid quadratic rescans. A
  garbage-collection timeout now propagates through
  `Sources/RielaCLI/ProductionNodeAdapter+GitRepository.swift`; other optional
  maintenance failures remain non-authorizing and do not change Git state.
- **Deterministic coverage**:
  `Tests/RielaCLITests/GitWorkflowAddonGarbageCollectionSafetyTests.swift`
  proves replacement preservation, exact old-entry removal, directory-entry
  limit exhaustion, and expired workflow-deadline behavior. Existing recovery
  and immutable-record race coverage remains passing.
- **Documentation and criteria**:
  `design-docs/specs/node-addon-catalog-and-chat-reply-worker/core-built-in-workers.md`
  and the completion criteria now require descriptor-scanned, entry-bounded,
  deadline-aware, private-quarantine garbage collection.
- **Verification**: Xcode-toolchain `swift test --filter
  'GitAddonGarbageCollectionSafetyTests|GitWorkflowAddonStoreReadTests|GitWorkflowAddonRecoveryTests'`
  passed 35 tests; `swift test --filter GitWorkflowAddon` passed 113;
  `swift build` completed; and `swift test --filter
  'RielaCLITests|RielaCoreTests'` passed 1,299 tests, all with zero failures.
  Workflow validation returned `valid: true` with no diagnostics. Xcode
  `xcrun swiftlint lint --strict --no-cache` reported zero violations in the
  six revised Swift files. `git diff --check` and `git diff --cached --check`
  passed. No TypeScript file changed and no applicable repository-root
  `riela-package.json` exists.
- **Plan state**: TASK-007 and the no-known-high-or-mid completion criterion are
  complete again. TASK-008 remains in progress pending Step 6 self-review,
  independent Step 7 and adversarial review, allowlisted staging, commit,
  same-name upstream push, archival, and final handoff. No commit or push was
  performed.
- **Residual risks**: Foreign or orphaned index locks remain operator-owned;
  concurrent remote updates remain fail-closed through non-force push and live
  verification; additional platform Git and credential-helper locations remain
  unsupported; a post-quarantine identity mismatch preserves bytes inside its
  hidden private quarantine for operator-visible later maintenance.
- **Next**: Repeat Step 6 self-review, then return the candidate to independent
  Step 7 adversarial implementation review.

### 2026-08-06 - Step 6 Cutoff-Snapshot and Quarantine-Restoration Revision

- **Accepted-plan alignment**: Reconfirmed full `issue-resolution` mode and the
  Step 4/5 bounded retention and unrelated-work preservation contract. TASK-007
  was reopened and completed for findings
  `codex-design-and-implement-review-loop-session-49-step6-implement-self-review-attempt-5-finding-1`
  and
  `codex-design-and-implement-review-loop-session-49-step6-implement-self-review-attempt-5-finding-2`
  delivered by `comm-000516`; commit authorization, repository confinement,
  and push behavior remain unchanged.
- **Stable eligibility identity**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitFinalizationStore.swift` now carries
  each cutoff-qualified device/inode snapshot directly into cleanup instead of
  reopening the pathname and accepting a replacement as the expected entry.
- **Replacement restoration**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitFinalizationGarbageCollection.swift`
  revalidates the qualified snapshot before quarantine, validates the moved
  entry again, and restores any mismatching replacement with an exclusive
  no-overwrite rename. If another entry already occupies the original name,
  the mismatching bytes remain isolated in private quarantine.
- **Deterministic coverage**:
  `Tests/RielaCLITests/GitWorkflowAddonGarbageCollectionSafetyTests.swift`
  covers replacement between cutoff qualification and cleanup open, and
  replacement after pathname validation but before quarantine rename.
- **Plan state**: TASK-007 and the no-known-high-or-mid completion criterion are
  complete again. TASK-008 remains in progress pending Step 6 self-review,
  independent Step 7 adversarial review, allowlisted staging, commit,
  same-name upstream push, archival, and final handoff. No commit or push was
  performed.
- **Next**: Repeat Step 6 self-review, then return the candidate to independent
  Step 7 adversarial implementation review.

### 2026-08-06 - Step 7 Dangling-Symlink Revision

- **Accepted-plan alignment**: Reconfirmed full `issue-resolution` mode and the
  accepted exact-path, regular-worktree-file, tracked-deletion, and canonical-
  index preservation contracts. TASK-007 was reopened for the mid-severity
  finding from `comm-000519`; no authorization, journal, or push policy was
  changed.
- **No-follow path classification**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitRepository.swift` now traverses
  worktree ancestry through no-follow directory descriptors and opens the
  final entry with `O_NOFOLLOW | O_NONBLOCK`. Only `ENOENT` for that final entry
  is classified as a deletion; dangling symlinks and other non-regular entries
  fail closed. The same classifier runs again at the staging boundary.
- **Deterministic regression**:
  `Tests/RielaCLITests/GitWorkflowAddonReviewRegressionTests.swift` replaces a
  tracked regular file with a dangling symlink and proves policy rejection,
  unchanged `HEAD`, byte-identical canonical index, and preservation of the
  symlink.
- **Carried verification evidence from `comm-000518`**: `swift test --filter
  GitAddonGarbageCollectionSafetyTests` passed 5 tests; `swift test --filter
  GitWorkflowAddon` passed 109 tests; and `swift test --filter
  'RielaCLITests|RielaCoreTests'` passed 1,300 tests, all with zero failures.
- **Upstream acknowledgment**: The configured same-name upstream is behind the
  current branch by pre-existing non-issue-80 commit `9c4af2e`. Finalization
  must preserve that explicit context, stage only issue #80 files, and use a
  non-force push only after all remaining review gates pass.
- **Post-revision verification**: Xcode-toolchain `swift test --filter
  GitWorkflowAddonReviewRegressionTests` passed 8 tests; `swift test --filter
  GitAddonGarbageCollectionSafetyTests` passed 5 tests; `swift test --filter
  GitWorkflowAddon` passed 110 tests; `swift test --filter
  'RielaCLITests|RielaCoreTests'` passed 1,301 tests; and `swift build`
  completed, all with zero failures. Workflow validation returned `valid: true`
  with no diagnostics. Targeted strict SwiftLint reported zero violations in
  both revised Swift files. `git diff --check` and `git diff --cached --check`
  passed. No TypeScript file changed, and no applicable `riela-package.json`
  exists.
- **Plan state**: TASK-007 and the no-known-high-or-mid completion criterion are
  complete again. TASK-008 remains in progress for documentation finalization,
  allowlisted staging, commit, same-name upstream push, archival, and final
  handoff after independent Step 7 and adversarial review. No commit or push
  was performed.
- **Residual risks**: Foreign or orphaned index locks remain operator-owned;
  concurrent remote updates remain fail-closed through non-force push and live
  verification; additional platform Git and credential-helper locations remain
  unsupported; and the current branch retains pre-existing non-issue-80 commit
  `9c4af2e` beyond its configured same-name upstream.
- **Next**: Repeat Step 6 self-review, then return the candidate to independent
  Step 7 review. If accepted, the high-risk intake still requires the separate
  adversarial gate before finalization.

### 2026-08-06 - Step 6 Nested Tracked-Deletion Evidence Revision

- **Accepted-plan alignment**: Reconfirmed full `issue-resolution` mode and the
  Step 4/5 exact tracked-deletion, repository-confinement, deterministic-test,
  and unrelated-work preservation contracts. This rerun addresses both
  findings delivered by `comm-000524` and preserves the prior Step 7 finding
  reference
  `codex-design-and-implement-review-loop-session-52-step7-review-attempt-1-finding-1`.
- **Nested tracked deletion**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitRepository.swift` treats `ENOENT`
  at either the final entry or an intermediate ancestor as a missing-path
  candidate. The existing exact `git ls-files --error-unmatch -- <path>` check
  remains the authorization boundary, and the no-follow classifier runs again
  during prepared-index staging. Symlink, FIFO, directory, and other ancestry
  failures remain policy-blocked.
- **Deterministic coverage**:
  `Tests/RielaCLITests/GitWorkflowAddonReviewRegressionTests.swift` removes the
  parent directory of tracked `nested/tracked.txt`, commits that exact deletion,
  and proves an unrelated worktree edit remains unstaged and uncommitted.
- **Plan correction**: The completion criterion now permits final-entry or
  intermediate-ancestor `ENOENT` only as a missing-path candidate and requires
  exact tracked-file validation before deletion handling. This supersedes the
  final-entry-only wording recorded for the earlier dangling-symlink revision.
- **Verification**:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter GitWorkflowAddon`
  passed 111 tests with zero failures;
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'RielaCLITests|RielaCoreTests'`
  passed 1,302 tests with zero failures;
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`
  completed successfully; and
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate codex-design-and-implement-review-loop --workflow-definition-dir .riela/workflows --output json`
  returned `valid: true` with no diagnostics. The SwiftPM wrappers remained
  open after their successful summaries and were bounded by `timeout`.
- **Lint and integrity**: Xcode-routed
  `/usr/bin/xcrun swiftlint lint --strict --no-cache Sources/RielaCLI/ProductionNodeAdapter+GitRepository.swift Tests/RielaCLITests/GitWorkflowAddonReviewRegressionTests.swift`
  reported zero violations. Final `git diff --check` and
  `git diff --cached --check` passed. No TypeScript file changed, and no
  applicable repository-root `riela-package.json` exists.
- **Plan state**: TASK-007 and the no-known-high-or-mid completion criterion are
  complete again. TASK-008 remains in progress for independent Step 7 and
  adversarial review, documentation finalization, allowlisted staging, commit,
  same-name upstream push, archival, and final handoff. No commit or push was
  performed.
- **Residual risks**: Foreign or orphaned index locks remain operator-owned;
  concurrent remote updates remain fail-closed through non-force push and live
  verification; additional platform Git and credential-helper locations remain
  unsupported; and the current branch retains pre-existing non-issue-80 commit
  `9c4af2e` beyond its configured same-name upstream.
- **Next**: Repeat Step 6 self-review and test-integrity checks, then return the
  candidate to independent Step 7 and the required adversarial review.

### 2026-08-06 - Step 6 Replacement-Ref and Retry-Retention Revision

- **Accepted-plan alignment**: Reconfirmed full `issue-resolution` mode and the
  accepted exact allowlist, canonical-index preservation, retry-idempotency,
  and bounded-maintenance contracts. This rerun addresses both adversarial
  findings delivered by `comm-000529`; explicit commit and push authorization,
  repository confinement, and non-force push behavior remain unchanged.
- **Replacement-object confinement**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitProcess.swift` now applies Git's
  global `--no-replace-objects` option to every runtime Git invocation. A
  repository-local `refs/replace/*` entry therefore cannot substitute the
  parent tree used by staged-path, empty-commit, retry, or ancestry checks.
  Legacy graft behavior was reviewed separately and cannot substitute tree
  content or conceal an allowlist-external canonical-index entry.
- **Retry-evidence retention**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitRepository.swift` no longer invokes
  age-only failed-artifact collection during commit or push preparation. An old
  unaccepted predecessor journal remains available until retry ancestry can
  reconcile it; explicit maintenance remains available to a runtime caller
  that can exclude active unaccepted execution ancestry.
- **Deterministic coverage**:
  `Tests/RielaCLITests/GitWorkflowAddonReviewRegressionTests.swift` proves that
  a replacement ref cannot hide an unrelated staged path or mutate `HEAD` or
  the canonical index. `Tests/RielaCLITests/GitWorkflowAddonGarbageCollectionSafetyTests.swift`
  ages a published-but-unaccepted predecessor beyond the retention cutoff and
  proves retry returns the original `already-committed` evidence without a
  second commit while preserving a later worktree edit.
- **Documentation**:
  `design-docs/specs/node-addon-catalog-and-chat-reply-worker/core-built-in-workers.md`
  records the replacement-object boundary and makes age collection an explicit
  runtime-aware maintenance operation rather than automatic add-on preparation.
- **Verification**:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'GitWorkflowAddonReviewRegressionTests|GitAddonGarbageCollectionSafetyTests'`
  passed 16 tests with zero failures;
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter GitWorkflowAddon`
  passed 112 tests with zero failures;
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'RielaCLITests|RielaCoreTests'`
  passed 1,304 tests with zero failures; and
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`
  completed successfully. Workflow validation returned `valid: true` with no
  diagnostics. Targeted strict SwiftLint reported zero violations in all four
  revised Swift files. `git diff --check` and `git diff --cached --check`
  passed. No TypeScript file changed, and no applicable `riela-package.json`
  exists.
- **Finding disposition**: The high-severity replacement-ref allowlist bypass
  and mid-severity age-only retry-evidence deletion from `comm-000529` are
  resolved with production changes and regressions. The earlier nested tracked-
  deletion finding remains resolved.
- **Plan state**: TASK-007 and the no-known-high-or-mid completion criterion are
  complete again. TASK-008 remains in progress for independent Step 7 and the
  required adversarial review, allowlisted staging, commit, same-name upstream
  push, archival, and final handoff. No commit or push was performed.
- **Residual risks**: Unaccepted finalization artifacts now require an explicit
  runtime-aware maintenance caller to bound long-term accumulation; foreign or
  orphaned index locks remain operator-owned; concurrent remote updates remain
  fail-closed through non-force push and live verification; additional platform
  Git and credential-helper locations remain unsupported; and the current
  branch retains pre-existing non-issue-80 commit `9c4af2e` beyond its
  configured same-name upstream.
- **Next**: Repeat Step 6 self-review, then return the candidate to independent
  Step 7 review and the mandatory adversarial gate before finalization.

### 2026-08-06 - Step 6 Runtime-Aware Terminal Maintenance Revision

- **Accepted-plan alignment**: Reconfirmed full `issue-resolution` mode and the
  accepted bounded-retention and exact-retry contracts. This revision addresses
  `step6-self-review-finding-gc-no-production-caller` from `comm-000531` without
  weakening replacement-object confinement, exact staging, or non-force push.
- **Runtime-confirmed terminality**:
  `Sources/RielaCore/WorkflowAddonExecution.swift` adds a dedicated terminal-
  finalization recording boundary. The deterministic runner invokes it only
  after a completed session or non-resumable failure is durably persisted;
  max-step failures remain resumable and are explicitly excluded. Composite
  and scenario resolvers forward the runtime-owned signal to the built-in Git
  resolver.
- **Durable eligibility markers**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitFinalizationTerminalMaintenance.swift`
  writes bounded create-only markers under the private finalization store only
  when the persisted workflow and step execution identities match a journal in
  the resolver's validated repository. Automatic preparation collection is
  restored, but journal removal now requires both retention age and a matching
  exact-journal marker. Markers are identity-safely removed after their journal
  disappears; active and crash-interrupted retry ancestry is retained.
- **Deterministic coverage**:
  `Tests/RielaCLITests/GitWorkflowAddonGarbageCollectionSafetyTests.swift`
  creates concurrent old active and terminal transaction artifacts through the
  production resolver/runner boundary, then proves preparation collects only
  the terminal set. `Tests/RielaCoreTests/WorkflowAddonExecutionIdentityTests.swift`
  verifies completed and terminal-failure notification and proves a resumable
  max-step failure is not marked terminal. Existing collector tests now provide
  explicit terminal eligibility before asserting age and limit behavior.
- **Plan state**: TASK-007 and the no-known-high-or-mid completion criterion are
  complete again. TASK-008 remains in progress for independent Step 7 and the
  mandatory adversarial review, allowlisted staging, commit, same-name upstream
  push, archival, and final handoff. No commit or push was performed.
- **Final verification**:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'GitWorkflowAddonReviewRegressionTests|GitAddonGarbageCollectionSafetyTests|GitWorkflowAddonRecoveryTests|WorkflowAddonExecutionIdentityTests'`
  passed 51 tests with zero failures;
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter GitWorkflowAddon`
  passed 112 tests with zero failures; and the final post-lint
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'RielaCLITests|RielaCoreTests'`
  passed 1,308 tests with zero failures. `swift build` passed, workflow
  validation returned `valid: true` with no diagnostics, targeted strict
  SwiftLint reported zero violations across the 15 revised Swift files, and
  both staged and unstaged diff checks passed.
- **Next**: Repeat Step 6 self-review and test-integrity checks, then return the
  candidate to independent Step 7 and mandatory adversarial review.

### 2026-08-06 - Step 6 Post-Revision Aggregate Verification

- **Accepted-plan alignment**: Reconfirmed full `issue-resolution` mode and the
  accepted bounded-retention, exact-retry, and unrelated-work preservation
  contracts. This rerun closes
  `codex-design-and-implement-review-loop-session-56-step6-implement-self-review-finding-1`
  delivered by `comm-000532`; no Codex-agent reference was supplied.
- **Terminal-maintenance scale correction**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitFinalizationTerminalMaintenance.swift`
  first discovers the bounded repository-matching journal candidates and then
  matches them against the persisted terminal session execution IDs without
  rejecting a legitimate session solely because it contains more than 4,096
  executions. `Tests/RielaCLITests/GitWorkflowAddonGarbageCollectionSafetyTests.swift`
  proves an exact terminal Git execution remains collectable after more than
  the finalization-directory entry limit of unrelated executions.
- **Current aggregate verification**:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter GitAddonGarbageCollectionSafetyTests`
  passed 9 tests with zero failures;
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`
  reported `Build complete`;
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter GitWorkflowAddon`
  passed 112 tests with zero failures; and
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'RielaCLITests|RielaCoreTests'`
  passed 1,309 tests with zero failures.
- **Lint and workflow verification**: Strict no-cache SwiftLint across all 31
  issue-owned changed Swift files reported zero violations. The Xcode-toolchain
  `swift run riela workflow validate codex-design-and-implement-review-loop
  --workflow-definition-dir .riela/workflows --output json` command returned
  `valid: true` with no diagnostics. Final `git diff --check` and `git diff
  --cached --check` both passed. No TypeScript file changed, so TypeScript
  post-modification checks do not apply; no applicable `riela-package.json`
  exists.
- **Finding disposition**: The current implementation now has focused and
  post-revision aggregate evidence. The prior replacement-ref, retry-retention,
  and missing-production-maintenance findings remain closed. TASK-007 and the
  no-known-high-or-mid completion criterion remain complete; TASK-008 remains
  in progress for independent Step 7 and mandatory adversarial review,
  allowlisted staging, commit, same-name upstream push, archival, and final
  handoff. No commit or push was performed.
- **Next**: Repeat Step 6 self-review before independent Step 7 and mandatory
  adversarial review.

### 2026-08-06 - Step 6 Large Terminal-Execution History Revision

- **Accepted-plan alignment**: Reconfirmed full `issue-resolution` mode and the
  accepted bounded-retention, runtime-owned terminality, and exact-journal
  eligibility contracts. This revision addresses
  `codex-design-and-implement-review-loop-session-55-step6-implement-self-review-finding-1`
  from `comm-000532`; explicit authorization, replacement-object confinement,
  exact retry ancestry, and non-force push behavior remain unchanged.
- **Bounded terminal matching**:
  `Sources/RielaCLI/ProductionNodeAdapter+GitFinalizationTerminalMaintenance.swift`
  no longer rejects a terminal session solely because it contains more than
  4,096 step executions. It derives at most 4,096 repository- and workflow-
  matched journal candidates from the bounded private-directory scan, then
  streams and validates every runtime-persisted execution id while retaining
  only ids relevant to those candidates. Exact workflow, step execution,
  repository, and journal-key proof remains required.
- **Deterministic coverage**:
  `Tests/RielaCLITests/GitWorkflowAddonGarbageCollectionSafetyTests.swift`
  creates an old published-but-unaccepted journal and supplies 4,096 unrelated
  execution ids plus the exact Git execution id. Terminal recording marks and
  collects only that exact transaction, proving the runtime callback no longer
  leaves the journal permanently ineligible.
- **Verification**:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter GitAddonGarbageCollectionSafetyTests`
  passed 9 tests with zero failures;
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter GitWorkflowAddon`
  passed 112 tests with zero failures;
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'RielaCLITests|RielaCoreTests'`
  passed 1,309 tests with zero failures; and
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`
  completed successfully.
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate codex-design-and-implement-review-loop --workflow-definition-dir .riela/workflows --output json`
  returned `valid: true` with no diagnostics. Xcode-routed
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint lint --strict --no-cache Sources/RielaCLI/ProductionNodeAdapter+GitFinalizationTerminalMaintenance.swift Tests/RielaCLITests/GitWorkflowAddonGarbageCollectionSafetyTests.swift`
  reported zero violations in both revised Swift files. `git diff --check` and
  `git diff --cached --check` passed after this progress update. No TypeScript
  file changed, and no applicable repository-root `riela-package.json` exists.
- **Plan state**: TASK-007 and the no-known-high-or-mid completion criterion are
  complete again. TASK-008 remains in progress for independent Step 7 and the
  mandatory adversarial review, allowlisted staging, commit, same-name upstream
  push, archival, and final handoff. No commit or push was performed.
- **Residual risks**: Foreign or orphaned index locks remain operator-owned;
  concurrent remote updates remain fail-closed through non-force push and live
  verification; additional platform Git and credential-helper locations remain
  unsupported; and the current branch retains pre-existing non-issue-80 commit
  `9c4af2e` beyond its configured same-name upstream.
- **Next**: Repeat Step 6 self-review and test-integrity checks, then return the
  candidate to independent Step 7 and mandatory adversarial review.

### 2026-08-06 - Step 6 Session 58 Output-Schema Validation Revision

- **Accepted-plan alignment**: Reconfirmed full `issue-resolution` mode and the
  Step 4/5 exact finalization-evidence contract before changing the candidate.
  The authoritative runtime input supplied no Step 7 messages or findings for
  `codex-design-and-implement-review-loop-session-58`; all previously recorded
  high- and mid-severity findings remain closed.
- **Verification-exposed finding**: The aggregate CLI/Core gate found that the
  workflow-output schema correctly required exact `committedFiles` evidence,
  but `DefaultWorkflowOutputValidator` rejected the schema because its
  deterministic JSON Schema subset did not yet implement `uniqueItems`. The
  issue-owned workflow-model test also retained the older four-field evidence
  expectation and omitted `committedFiles` from its accepted planning fixture.
- **Implementation**: `Sources/RielaCore/RuntimeOutputValidation.swift` now
  validates the `uniqueItems` keyword as a boolean and rejects duplicate array
  values when it is enabled. `Tests/RielaCoreTests/RuntimeOutputValidationTests.swift`
  covers duplicate rejection and malformed schema definitions.
  `Tests/RielaCoreTests/WorkflowModelTests.swift` now requires
  `committedFiles` in both finalization schema branches and supplies exact file
  evidence in the accepted fixture. These two runtime-validator files are
  added to the issue #80 ownership allowlist because they are directly needed
  to make the accepted workflow-output contract executable; no unrelated file
  was changed.
- **Focused verification**: Xcode-toolchain `swift test --filter
  'RuntimeOutputValidationTests|WorkflowModelTests'` passed 29 tests with zero
  failures. The pre-revision Git gate passed 113 tests with zero failures, and
  strict no-cache SwiftLint passed all then-current 34 changed Swift files with
  zero violations. `swift build`, JSON parsing, staged/unstaged/untracked
  whitespace checks, and the no-TypeScript-change check passed.
- **Plan state**: TASK-007 and the no-known-high-or-mid completion criterion
  remain complete. TASK-008 remains in progress for independent Step 7 and the
  mandatory adversarial review, documentation finalization, allowlisted
  staging, commit, same-name upstream push, archival, and final handoff. No
  commit or push was performed by Step 6.
- **Residual risks**: Foreign or orphaned index locks remain operator-owned;
  concurrent remote updates remain fail-closed through non-force push and live
  verification; additional platform Git and credential-helper locations remain
  unsupported; and the current branch retains pre-existing non-issue-80 commit
  `9c4af2e` beyond its configured same-name upstream.
- **Next**: Complete the post-revision aggregate gate, then return the candidate
  to Step 6 self-review, test-integrity review, independent Step 7, and the
  mandatory adversarial review.

### 2026-08-06 - Final Adversarial Corrections and Verification

- **Authorized push range**: `riela/git-push` now requires the accepted commit
  to be the sole unpublished commit above the validated tracking and live
  remote tip. It rejects a pre-existing ahead ancestor instead of silently
  publishing an unreviewed commit range.
- **Transport cleanup**: Isolated push repositories retain filesystem identity,
  use identity-safe cleanup that preserves a concurrent path replacement, and
  participate in bounded age-based recovery of crash-orphaned transport
  directories.
- **Exact terminal evidence**: Terminal workflow output must report
  `committedFiles` exactly as accepted commit evidence, including order and
  uniqueness. The workflow schemas, prompts, mock scenarios, runtime evidence
  guard, and deterministic tests enforce the same contract.
- **Review finding disposition**: All three findings from
  `codex-design-and-implement-review-loop-session-56-step7-adversarial-review-attempt-1`
  are resolved. Regression coverage includes rejection of an unrelated
  unpublished ancestor, safe transport path-replacement handling and orphan
  recovery, and rejection of missing or mismatched terminal file evidence.
- **Final verification**:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter GitWorkflowAddon`
  passed 113 tests with zero failures;
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'RuntimeOutputValidationTests|WorkflowModelTests'`
  passed 29 tests with zero failures; and
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'RielaCLITests|RielaCoreTests'`
  passed 1,319 tests with zero failures. One preceding aggregate attempt ended
  in an unrelated `WorkflowCommandTests` process-runner signal 6; the exact
  test passed independently before the clean aggregate rerun.
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`
  completed successfully. Strict no-cache SwiftLint reported zero violations
  across all 36 changed Swift files. Workflow validation returned `valid: true`
  with no diagnostics, and staged/unstaged `git diff --check` passed.
- **Plan state**: TASK-007 and the no-known-high-or-mid criterion are complete.
  Documentation and plan archival are also complete. Pre-commit security
  checks, allowlisted commit, explicit same-name upstream publication of only
  the issue #80 commit, and final handoff remain later workflow finalization
  gates. The push add-on must reject any additional unpublished ancestor.

### 2026-08-06 - Implementation-plan Completion Check

- **Accepted completion evidence**: Step 7 accepted the implementation with
  only two low-severity open findings. Step 8 refreshed `README.md`,
  `.codex/skills/riela-impl-workflow/SKILL.md`, and this plan before commit
  generation. `git diff --check` and `git diff --cached --check` passed.
- **Plan state**: TASK-008 and every implementation-plan completion criterion
  are complete. The exact-file commit and explicit same-name non-force push
  remain later workflow finalization gates, not active implementation work.
- **Archive decision**: Moved this plan from `impl-plans/active/` to
  `impl-plans/completed/` and updated `impl-plans/README.md`.
- **Residual risks**: Accepted-token markers lack bounded retention; the short
  `GitWorkflowAddon` filter omits the garbage-collection safety suite; browser
  E2E was not run because issue #80 changed no browser-facing files.
