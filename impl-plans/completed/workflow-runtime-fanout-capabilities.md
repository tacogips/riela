# Workflow Runtime Fanout Capabilities Implementation Plan

**Status**: Implemented, independently reconciled, verified, and archived
2026-09-21. The former planning-only description was superseded by bounded
fanout commit `3e0a0d57` and later cross-workflow/recovery hardening.
**Design Reference**: `design-docs/specs/design-incomplete-work-inventory.md`
§1; `Sources/RielaCore/WorkflowRuntimeCapabilityGap.swift`
**Created**: 2026-07-12

## Summary

`DeterministicWorkflowRunner` diagnoses — rather than executes — three
declared capabilities. This plan owns closing them:

1. **Live fanout transitions.** `workflow.steps.<id>.transitions.fanout`
   currently produces an error-severity capability gap
   (`WorkflowRuntimeCapabilityGap.unsupportedFeatures`); live runs cannot
   execute fanout. The data model already exists (`WorkflowStepFanout`,
   `WorkflowFanoutWriteOwnership`, `WorkflowFanoutResultOrder`,
   `WorkflowFanoutFailurePolicy` in `WorkflowModel.swift`).
2. **`run.maxConcurrency`.** Reserved for fanout execution; setting it is
   diagnosed as unsupported (`WorkflowRuntimeCapabilityGap.swift:90`).
3. **Cross-workflow/resume combination validation + library callee
   resolver.** Cross-workflow transitions without `resumeStepId` are
   diagnosed; live dispatch requires a `calleeResolver`, which library
   consumers must supply explicitly (CLI wires
   `FileSystemWorkflowCalleeResolver`; the library default is nil and the
   requirement is only documented through the capability gap diagnostics).

Scope boundary (per the handover's overlap scan): this plan owns workflow
fanout *execution*; loop-run concurrency leases are owned by
`loop-engineering-convergence-and-operations` (LB3, shipped) and are not
fanout.

## Phases (specs authored at phase start; no checkboxes until then)

- **F1 — Fanout execution core.** Execute fanout transitions with bounded
  concurrency (`run.maxConcurrency`), honoring the authored write-ownership,
  result-order, and failure-policy declarations; deterministic tests over
  mock adapters; capability-gap diagnostics removed only when execution is
  real.
- **F2 — Cross-workflow/resume combination hardening.** Promote the current
  diagnostics into validated, tested contracts (invalid combinations fail
  closed with actionable messages); document and test the library
  callee-resolver requirement (nil resolver → typed error naming the
  requirement, not a generic capability gap).
- **F3 — Observability.** Fanout branch progress records and session
  inspection surfaces, consistent with the existing `WorkflowRunEvent`
  contract (additive event types only).

## Closure evidence (2026-09-21)

- **F1 complete**: `DeterministicWorkflowRunner+Fanout.swift` executes local
  and cross-workflow fanout with bounded concurrency, deterministic input-order
  joins, declared ownership checks, dependency waves, and all three failure
  policies. `run.maxConcurrency` is an active cap rather than a capability gap.
- **F2 complete**: CLI validation resolves reachable cross-workflow callees and
  caller resume steps, while live library execution fails with a typed
  resolver-specific diagnostic when no callee resolver is wired. Unsupported
  one-sided transition combinations remain intentionally invalid contracts,
  not missing runtime capabilities.
- **F3 complete**: each fanout branch is a child runtime session with durable
  `parentSessionId`/`rootSessionId`; it forwards the existing event handler, so
  standard session/step/backend/completion events provide branch progress and
  the session store provides inspection. A dedicated regression now proves all
  branch start/completion events and inspectable terminal child sessions.
- Current verification passed 11 fanout tests, the three-test live
  cross-workflow suite (including production SIGKILL/reopen), and four focused
  capability-diagnostic tests, all with zero failures. Strict lint for the
  changed test and `git diff --check` are clean. Independent reconciliation
  found no high/medium issue.

## Verification contract

Standard repository contract: focused deterministic suites per phase, strict
SwiftLint on changed files, full `swift test` on the final tree, and an
independent adversarial review for the concurrency/ownership semantics before
the capability-gap diagnostics are lifted.
