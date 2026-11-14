# whu-04-web-history-screen: workflow history and rollback screen (web console `versions` tab)

```json
{
  "planId": "whu-04-web-history-screen",
  "planPath": "impl-plans/active/workflow-history-unification-04-web-history-screen.md",
  "dependsOn": [],
  "wave": 1,
  "writePaths": [
    "web/src/routes.ts",
    "web/src/routes.test.ts",
    "web/src/views/WorkflowRunConfigurationsView.tsx",
    "web/src/workflows/history",
    "web/node_modules",
    "web/dist",
    "impl-plans/progress/whu-04-web-history-screen.md"
  ],
  "sharedPaths": [],
  "artifactRoots": ["web/node_modules", "web/dist"]
}
```

**Checkpoint amendment (integration finding WHU-INT-03).**

- `web/node_modules` (the dependency install) and `web/dist` (the default
  Vite build output; `web/vite.config.ts` sets no `outDir`) are owned
  artifact roots. They are recorded as digest/count manifests, never as
  source. Both are gitignored (`.gitignore`: `node_modules/`, `dist/`).
- The authored audit record is this plan's progress log
  `impl-plans/progress/whu-04-web-history-screen.md`. It records:
  - `bun --version`;
  - the install command and its exit code;
  - `shasum -a 256 web/bun.lock` before and after the install, which must
    be equal.
- Resume from the preserved authored web sources: routes, view, history
  client and tests. Do not re-author them.

## Intent and context

Design §7. The screen gives the user:

- a version list with actor, reason and time;
- a structured diff between any two versions, or against the current head;
- restore and undo with a confirmation that requires a reason and uses CAS;
- pending regression-rollback proposals with approve and reject.

It is backed only by GraphQL. Follow the execution protocol in the index
plan. Node and bun commands run in `web/`, not through `arch`.

Repository context:

- Routes are in `web/src/routes.ts`. The `workflow-detail` tab union is
  `'settings' | 'history' | 'definition'`, and `parseViewHash` /
  `viewHash` have tests in `web/src/routes.test.ts`.
- The tab UI is `web/src/views/WorkflowRunConfigurationsView.tsx`:
  - `ConfigurationTab` type: `:15`;
  - nav buttons: `:90-93`;
  - tab bodies: `:94-99`;
  - the workflow name is available as `source()?.workflowId ??
    configurations()[0]?.workflowId`.
- The GraphQL transport pattern is `web/src/console/client.ts`: class
  `ConsoleClient` with an injectable `{request, appHeaders}` environment,
  `execute<T>(query, variables, operationName, signal)` mapping
  `errors[0].extensions.code` into `APIError`, and a default client built
  on `rielaFetch` + `api.noteHeaders()`. Tests are in
  `web/src/console/client.test.ts` (`harness` with canned responses).
- UI primitives: `components/ConfirmationDialog.tsx` (`title`,
  `confirmLabel`, `danger`, `onConfirm`, `onCancel`, `children`),
  `components/ActionButton.tsx`, and `ErrorBanner`, `LoadingState` and
  `PageHeader` from `components/Primitives.tsx`.

## Non-goals

- No Swift changes and no new REST routes.
- Do not edit `console/client.ts`, `App.tsx` or `contracts.ts`. Keep the
  history client self-contained in `web/src/workflows/history/`.
- No bundle-snapshot (file) restore UI. The design restores the service
  definition only.
- No new dependencies and no `bun.lock` changes.

## GraphQL operations used (binding names; existing ones verified in `Sources/RielaGraphQL/WorkflowDefinitionGraphQL.swift`)

- `workflowDefinitionHistory(workflowName, limit: 50)` →
  `[WorkflowDefinitionAuditRecord]`, with fields `auditId operation
  versionId previousVersionId reason evidence actor { kind id } createdAt
  retained`.
- `workflowDefinition(workflowName)` → `{ versionId revision }`, used to
  get the current head and revision.
- `workflowDefinitionDiff(workflowName, fromVersionId, toVersionId)` →
  `[{ path op before after }]`, where `before` and `after` are JSON
  strings.
- `restoreWorkflowDefinition(input: {workflowName, versionId, reason,
  expectedVersionId})` → `{ version { versionId } audit { auditId } }`.
  whu-03 adds the optional `expectedVersionId` to
  `RestoreWorkflowDefinitionInput`; whu-05 and whu-10 enforce it as a CAS.
- `undoWorkflowDefinition(input: {workflowName, reason, expectedVersionId})`
  → same payload.
- `workflowRollbackProposals(workflowName, status: "pending")`,
  `approveWorkflowRollbackProposal(input: {workflowName, proposalId,
  reason})` and `rejectWorkflowRollbackProposal(input: {workflowName,
  proposalId, reason})`, with the exact shapes pinned in
  `impl-plans/active/workflow-history-unification-03-graphql-contract.md`.

Restore and undo both send `expectedVersionId` = the head `versionId` the
user saw (design §7 CAS). A stale head returns `DEFINITION_STALE`, and the
view shows "History changed — reload".

## File-level changes

1. **`routes.ts` and `routes.test.ts`.** Add `'versions'` to the tab
   union. Parse and build both routes:
   - `#/workflows/{sourceId}/versions` → `{view: 'workflow-detail',
     sourceId, tab: 'versions'}`;
   - `#/workflows/{sourceId}/configurations/{cfg}/versions`.

   Existing routes stay unchanged, and `#/workflows/{id}` still has no tab.
2. **`WorkflowRunConfigurationsView.tsx`.** Extend `ConfigurationTab`.
   - Add a nav button "Versions" with `aria-pressed`.
   - Render `<WorkflowVersionsView workflowName={…} />` when `props.tab
     === 'versions'`, even when no configuration is selected.
   - The other tabs render only for `settings` / `history`.
3. **`web/src/workflows/history/historyClient.ts` (new).**
   - `WorkflowHistoryClient` takes the same environment shape as
     `ConsoleClient`, with one method per operation above and typed
     results, plus a default instance.
   - Errors become `APIError` carrying the GraphQL code.
4. **`web/src/workflows/history/WorkflowVersionsView.tsx` (new)** and
   **`history.css` (new)**. The view has:
   - **Version list.** One row per audit, showing operation, actor
     kind/id, reason, local time, short version id (first 12 characters),
     a "current" marker on the head, and a "not retained" badge.
     Audit-only rows (`versionId == previousVersionId`) get a "no
     definition change" label.
   - **Diff.** Two selectors (from, to), where `to` defaults to "current".
     It renders entries as `op path` with preformatted pretty-printed
     before/after JSON.
   - **Restore.** Shown on retained, non-current versions. It opens
     `ConfirmationDialog` with the diff from the head to that version, a
     required reason textarea (confirm is disabled while the trimmed
     value is empty), and the text "Restores the service definition;
     workflow files are unchanged." It calls the mutation with
     `expectedVersionId`, then reloads.
   - **Undo.** Same dialog, with `expectedVersionId` = the head seen.
   - **Pending proposals.** For each: workflow versions (regressed →
     rollback-to), regressions (`kind`, `gateId`, `detail`), baseline and
     target session ids, and policy.
     - Approve opens a confirmation with the diff from the regressed
       version to the rollback target, plus an optional reason.
     - Reject requires a reason.
     - Both reload the list.
   - **Errors.** Show `ErrorBanner` with the message. For codes
     `DEFINITION_STALE`, `DEFINITION_STALE_REVISION`,
     `ROLLBACK_SUPERSEDED` and `DEFINITION_ROLLBACK_IN_PROGRESS`, also show
     a reload hint.

   Language and visual style are English, low-text and monochrome, and
   reuse existing classes (`page`, `filter-row`, `surface-notice`).
5. **`web/src/workflows/history/historyClient.test.ts` (new).** Uses
   `bun:test` with the harness pattern from `console/client.test.ts`.

## Pitfalls

- Never send restore or undo without a non-empty trimmed reason.
- Never send approve or reject without explicit confirmation.
- Do not decode `before` and `after` as objects without `try`. They are
  JSON text and may be scalars.
- The lint step runs `scripts/audit-source.ts` too. Keep to the existing
  import and style conventions (no `any`, no unused variables).

## Tests (input → expected)

- `parseViewHash('#/workflows/s1/versions')` → `{view:'workflow-detail',
  sourceId:'s1', tab:'versions'}`. `viewHash` round-trips it, and the
  configuration form round-trips too.
- The client sends `operationName` and the exact variables for each method,
  for example restore →
  `{input:{workflowName, versionId, reason, expectedVersionId}}`.
- A GraphQL error with `extensions.code = 'ROLLBACK_SUPERSEDED'` → an
  `APIError` with that code.
- `workflowRollbackProposals` maps the `regressions` array.

## Verification (run in `web/`; logs under `tmp/workflow-history-unification/whu-04/`)

- First, install dependencies into the `web/node_modules` artifact root:
  `bun --version > ../tmp/workflow-history-unification/whu-04/bun-version.txt; shasum -a 256 bun.lock > ../tmp/workflow-history-unification/whu-04/lock-before.sha256; bun install --frozen-lockfile > ../tmp/workflow-history-unification/whu-04/install.log 2>&1; echo exit=$?; shasum -a 256 bun.lock > ../tmp/workflow-history-unification/whu-04/lock-after.sha256`
  → `exit=0`, and the before/after lock hashes are equal. Never run a plain
  `bun install` that could rewrite `bun.lock`.
- `bun run lint > ../tmp/workflow-history-unification/whu-04/lint.log 2>&1; echo exit=$?`
  → `exit=0`.
- `bun run typecheck > ../tmp/workflow-history-unification/whu-04/typecheck.log 2>&1; echo exit=$?`
  → `exit=0`.
- `bun test src > ../tmp/workflow-history-unification/whu-04/test.log 2>&1; echo exit=$?`
  → `exit=0`, and the log includes the new test names.
- `bun run build > ../tmp/workflow-history-unification/whu-04/build.log 2>&1; echo exit=$?`
  → `exit=0`.

## Done criteria

- [ ] Both routes parse and build. The Versions tab renders the view.
- [ ] All four web commands exit 0, with logs recorded.
- [ ] No files outside `writePaths` changed (check `git status --short web`
      in the progress log).
