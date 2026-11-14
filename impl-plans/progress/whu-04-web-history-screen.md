# whu-04 web history screen progress

- Mode: issue-resolution implementation; no issue (workflowInput.requestedOutcome, opus-terra-design-and-implement-review-loop-session-631, comm-012347).
- Plan has no dependencies and matches design §7. Added Versions routes, GraphQL history client, list/diff/restore/undo and proposal controls, plus route and client tests. Confirmations require reasons except approval; restore/undo send the displayed head as CAS.
- The amended plan authorizes `web/node_modules` and `web/dist`. `bun --version` returned 1.4.4; `cd web && bun install --frozen-lockfile` exited 0. Before and after SHA-256 for `web/bun.lock`: `beccd6ab85aa617c037012dec0764e9d0a727c1a4ea5bcb66d4595610f50392f`. Complete install and hash evidence is under `tmp/workflow-history-unification/whu-04-web-history-screen/`.
- The first installed-dependency typecheck exposed TypeScript errors; fixed tuple inference, conditional dialog rendering, and test fixture/index typing. Its prior log is `tmp/workflow-history-unification/whu-04-web-history-screen/typecheck-initial-after-install.log`.
- Final-source `cd web && bun run lint`, `bun run typecheck`, `bun test src`, and `bun run build` each exited 0. Tests: 113 passed, 0 failed. Complete logs are `lint-final.log`, `typecheck-final.log`, `test-final.log`, and `build-final.log` under the evidence directory.
- `git status --short web`: modified `web/src/routes.ts`, `web/src/routes.test.ts`, `web/src/views/WorkflowRunConfigurationsView.tsx`; untracked `web/src/workflows/history/`. No other web paths shown.
- Completion criteria: routes/view implemented, all four gates passed, and web write-scope checked. Formal review and final commit are downstream.
