# Work Brief: Web workflow observability & management UX (2026-07-29)

This is a pre-researched brief for ONE cohesive work package. Treat the entire
brief as exactly ONE feature / ONE work package (`has_feature_fanout` must be
false). Do not split it into fanout items.

## Question being answered

"Can the web UI handle workflow config, workflow logs, and workflow editing
without problems? What features are missing? What other UI defects exist?"

Survey answer (verified 2026-07-29 against `web/src` and `Sources/RielaGraphQL`):
the web UI today is a read-mostly control panel. It CANNOT show run/step-level
logs, CANNOT view or edit workflow definitions, and exposes none of the mutable
workflow registry. Several concrete UX defects exist. This package closes the
highest-value gaps.

## Verified current-state facts (do not re-derive; spot-check only)

- Frontend: SolidJS, 5 views, no router (view signal in `web/src/App.tsx`),
  hand-written REST client `web/src/api.ts` (CSRF + `expectedRevision`/409
  optimistic concurrency). Workflow data flows over REST `/api/v1/*` only.
  GraphQL `/graphql` is used by the web ONLY for Notes (`web/src/notes/client.ts`)
  — so a web GraphQL client pattern already exists and may be reused.
- `web/src/views/InstancesView.tsx`: instance cards + `InstanceEditor` editing
  working dir, env file, inline env vars, and workflow variables as a raw JSON
  textarea with an UNGUARDED `JSON.parse` (~line 67) — malformed JSON degrades
  to a generic error banner, no inline validation. `Instance.nodePatchCount`
  (`web/src/contracts.ts` ~:27) is displayed as a bare number; the patches
  themselves are not viewable.
- `web/src/views/LogsView.tsx`: instance → latest-100 session rows only
  (sessionId, workflowId, status, currentStepId, activeStepIds count,
  updatedAt, diagnostics strings). NO per-step detail, NO node execution
  records, NO LLM messages, NO live updates. No polling anywhere in the app
  despite "Live state"/"OBSERVABILITY" copy — every fetch is one-shot per
  mount with a manual Refresh button.
- `web/src/views/WorkflowsView.tsx`: workflow source discovery only (list
  dirs/repos/discovered workflows, add one directory via
  `POST /api/v1/workflows/sources/directories`). No definition viewer/editor.
- Server-side GraphQL that the web does NOT use (see
  `Sources/RielaGraphQL/GraphQLContracts.swift`,
  `WorkflowRegistryGraphQLSchema.swift`):
  - Queries: `workflowSession` (full run detail: `stepExecutions`, `logs`,
    `llmSessionMessages`, loop evidence/gates/recovery), `workflowSessions`,
    `sessionProgress`, `sessionHealth`, `workflows(filter:)`,
    `workflow(target:)`, loop-evidence queries.
  - Mutations: full mutable-registry set — `registerMutableWorkflow`,
    `updateMutableWorkflow`, `deleteMutableWorkflow`, `activateWorkflow`,
    `deactivateWorkflow`, `consolidateWorkflows`.
  - There are NO GraphQL mutations for run/resume/rerun/retry-step/patchNodes;
    do NOT attempt to add run-control features in this package.
- e2e: `web/e2e/dashboard.spec.ts` covers Run-logs empty state, Instances
  editor save/secret-masking, Workflows add-directory + 409 recovery, Settings,
  mobile nav. Nothing for session detail, registry, or polling.
- `cli-serve` host mode hides all views except Notes (`web/src/App.tsx:24`);
  new views must respect the same gating.
- No TODO/FIXME markers in web/src; loading/error/empty states are otherwise
  thorough; mutations route through `MutationMessage` with 409 Refresh
  handling — follow these established patterns (`web/src/components/Primitives.tsx`).

## Scope of THIS work package (one package, four workstreams)

1. **Run detail view (workflow logs).** From a session row in Run logs, open a
   detail view showing step executions (step id, status, timing), step-level
   logs/diagnostics, and gate/loop evidence where present. Source the data from
   the existing GraphQL `workflowSession` query (reuse the Notes GraphQL client
   pattern) OR a new REST projection endpoint following the existing
   `/api/v1` router patterns — pick ONE in design and justify; do not build both.
2. **Live-ness.** Add lightweight auto-refresh polling (interval + pause when
   `document.hidden`, manual Refresh preserved) to Instances, Run logs, and the
   new run detail view. No WebSockets/SSE — the server has none; do not add a
   streaming transport in this package.
3. **Config UX fixes.** (a) Inline pre-save JSON validation for the workflow
   variables textarea (guarded parse, inline error, disable Save while
   invalid). (b) Make node patches inspectable: show patch contents (read-only
   is acceptable) instead of a bare count, extending the instances projection
   if the payload lacks them.
4. **Workflow definition visibility + mutable registry editing.** Extend the
   Workflows view: (a) read-only definition inspector for discovered workflows
   (steps/nodes/transitions summary via existing `workflow(target:)`/
   `workflows(filter:)` GraphQL or an equivalent REST projection); (b) mutable
   registry management — list mutable workflows, edit definition JSON with
   validation feedback, activate/deactivate, delete with confirmation, using
   the existing registry GraphQL mutations. `consolidateWorkflows` UI is OUT of
   scope. Creating brand-new workflows from scratch in the browser is OUT of
   scope beyond `registerMutableWorkflow` with a pasted/edited JSON payload.

## Out of scope

- Run control (start/resume/rerun) from the web — no control-plane support.
- Streaming transports (WebSocket/SSE).
- Native-app (menu-bar) features, package install UI, Notes features.
- Visual redesign beyond what the new views need; reuse Primitives.

## Constraints

- ONE work package; `has_feature_fanout` must be false.
- Follow existing web architecture: SolidJS signals, hand-written clients,
  Primitives components, MutationMessage/409 pattern, CSRF handling, host-mode
  gating. Match existing code style; no new frontend dependencies.
- Server changes only where a projection/endpoint is genuinely missing; reuse
  existing GraphQL contracts wherever possible. Preserve auth symmetry
  (whatever auth the Notes GraphQL calls use applies to new calls).
- Do not modify unrelated files. Do not touch `.riela/workflows` fixtures.
- All new UI must have loading/error/empty states and e2e coverage in
  `web/e2e/` consistent with existing specs (use `exact: true` role selectors
  to avoid strict-mode collisions).

## Acceptance criteria

- A session row opens a run detail view showing step executions and step-level
  logs sourced from real server data.
- Instances and Run logs update automatically while visible; polling pauses
  when the tab is hidden; manual Refresh still works.
- Invalid JSON in the variables editor shows an inline error before save and
  blocks Save; valid JSON saves as before.
- Node patches for an instance are viewable in the UI.
- Discovered workflow definitions are viewable read-only; mutable workflows
  can be listed, edited, activated/deactivated, and deleted from the web with
  server-validated feedback.
- `cd web && bun run build` and `bun test` pass; `swift build` and the
  relevant filtered Swift test suites pass if server code changed; new e2e
  specs added for run detail, polling indicator, JSON validation, and registry
  edit (written; operator runs the full e2e suite separately).
