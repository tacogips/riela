# CLI Session Store Decode Resilience: Scope Decision

## Issue reference

Title-only issue: “Make CLIWorkflowSessionStore skip undecodable record_json
rows instead of aborting the command”

## Decision required

May implementation add a narrow raw-session-ID observation API in
`Sources/RielaCore/RuntimeStore.swift`, with focused tests, in addition to the
requested `Sources/RielaCLI/CLIWorkflowSessionStore.swift` and
`Tests/RielaCLITests/CLIWorkflowSessionStoreResilienceTests.swift` changes?

Recommended decision: allow the narrow scope expansion. The current
`InMemoryWorkflowRuntimeStore` advances its monotonic session counter only when
`seedSession(_:)` receives a fully decoded `WorkflowSession`. Once `loadAll()`
skips an incompatible highest-numbered record, the next allocation can reuse
that row’s `session_id`. Reading raw IDs inside the CLI store is insufficient
because the CLI module has no public way to advance the runtime store’s
generator without also inserting a placeholder session.

The proposed seam must only observe raw `session_id` plus `workflow_id`; it
must not decode, delete, mutate, or expose the incompatible record as a
runtime session.

If the scope expansion is declined, the implementation can deliver resilient
reads and warnings but cannot honestly satisfy the stated requirement that
session numbering remain correct without depending on decoded `record_json`.
