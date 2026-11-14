# Workflow Runtime Fanout Capabilities Implementation Plan

**Status**: PLANNING — authoritative owner plan for the W10 runtime capability
gaps (created 2026-07-12 per `REMAINING-WORK-HANDOVER.md` §5/W10, which
required these items to gain an owning plan instead of hiding under the
loop-engineering workstreams). No implementation has started; each phase below
is an explicitly accepted deferral — owner: next runtime-capabilities session;
trigger: a workflow author needs live fanout (today mock scenarios are the
only way to exercise fanout-shaped workflows).
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

## Verification contract

Standard repository contract: focused deterministic suites per phase, strict
SwiftLint on changed files, full `swift test` on the final tree, and an
independent adversarial review for the concurrency/ownership semantics before
the capability-gap diagnostics are lifted.
