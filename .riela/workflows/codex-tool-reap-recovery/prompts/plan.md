# Task

Create an implementation-ready plan for the unfinished terminal Codex tool-child stall recovery work in this repository.

Read completely before editing:

- `AGENTS.md` when present
- `.codex/skills/swift-coding-agent/SKILL.md`
- `design-docs/specs/design-codex-unified-exec-stall-followup.md`
- `impl-plans/active/codex-unified-exec-stall-followup.md`
- the process, backend-event, runtime-store, supervision, CLI, GraphQL, and test code named by that plan

Preserve every unrelated dirty worktree change. Put all scratch artifacts under repository-root `tmp/codex-tool-reap-recovery/`. Do not commit or push.

Update the design document and implementation plan so they define an implementable contract for all of the following:

1. Upstream prevention boundary: explain that Riela can always reap its direct agent child but cannot `waitpid` a Codex-owned grandchild; upstream `codex-code-mode-host` remains responsible for preventing its own zombies.
2. Riela recovery boundary: correlate an unresolved Codex `command_execution` tool call with its owning direct agent PID/process group and a descendant PID plus process-start identity; never trust a PID alone.
3. Tool-call state: track matching started/completed lifecycle independently from generic backend recency so wait/status/assistant events do not mask a stuck tool.
4. Classifier: require an unresolved tool call, ownership-safe terminal/zombie descendant evidence, a live owning host, and an elapsed missing-completion grace.
5. Cleanup: request host completion first, then perform bounded ownership-checked process-group TERM/grace/KILL, and always reap Riela's direct child through one completion owner.
6. Recovery: same-attempt continuation only with acknowledged terminal tool result and intact stream; otherwise idempotent auto-improve targeted retry/rerun subject to mutation-safety and attempt budgets.
7. Durable audit/CAS state, cancellation precedence, duplicate suppression, redaction, session inspection, CLI/library/GraphQL policy parity, macOS/Linux behavior, and deterministic tests.

Also create `impl-plans/REMAINING-WORK-HANDOVER.md` as a detailed handover for every remaining task in the current `riela` worktree and every affected task in sibling `../riela-packages`. This is broader than the tool-reap feature. Audit all design documents, active/completed implementation plans, unchecked checklists, status headings, progress/inventory documents, current dirty files, unfinished review rounds, runtime/session evidence under allowed tmp roots, package synchronization requirements, and verification gaps. Do not assume a zero-checkbox document is complete.

The handover must:

- state the repository/worktree baseline and ownership rules, including changes already completed that must not be redone
- inventory every active plan with status, remaining requirements, dependencies, affected files, acceptance tests, and evidence location
- separate product implementation, correctness/security hardening, tests/verification, documentation/contracts, package-registry synchronization/digests, release/operations, and tooling/stall-recovery work
- distinguish blockers from merely pending work and identify decisions that genuinely require user input
- give a dependency-ordered execution sequence, safe parallelization boundaries, stop conditions, and exact continuation commands
- record the active/failed Riela sessions relevant to handoff without embedding secrets or machine-private content
- include a traceability matrix from every discovered unfinished source to exactly one primary workstream, with cross-cutting dependencies referenced rather than duplicated
- include an explicit exclusions/completed section and a final definition of done for the entire remaining-work program

Self-review the handover for MECE coverage. Perform an orphan scan for unchecked items/TODO status claims not represented in the matrix, an overlap scan for tasks assigned to multiple primary workstreams, a consistency scan against git status and plan status, and a dependency-cycle scan. Record the self-review method, findings, corrections, and final residual uncertainties inside the document.

Resolve design choices rather than leaving vague alternatives. Identify exact source files/types to add or change, migration/backward-compatibility rules, defaults, failure semantics, and acceptance commands. Mark only already-implemented checklist items complete. Return concise JSON describing documents changed, handover inventory counts and MECE review result, and implementation phases.
