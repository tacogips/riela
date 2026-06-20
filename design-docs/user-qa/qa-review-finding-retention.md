# Review Finding Retention Decision

## Question

How long should persisted workflow review findings be retained after a workflow
run, rerun, or retry completes?

## Context

Issue `tacogips/cursor-agent#123` requires review findings to remain available
across reruns so implementation retries can address earlier feedback. The design
requires at least session-lifetime retention, but the product retention duration
is still unresolved.

## Options

1. Retain findings for the lifetime of the workflow session only.
2. Retain findings with exported session/runtime records until the user deletes
   those records.
3. Retain findings for a fixed time window after workflow completion.

## Default Until Answered

Use session-lifetime retention as the minimum behavior and do not add purge
logic that can remove findings before all rerun and review gates complete.

## Impact

The decision affects storage growth, export semantics, audit history, and whether
old review feedback remains available after long-running workflows are reopened.
