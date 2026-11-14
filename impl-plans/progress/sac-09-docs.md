# sac-09-docs implementation progress

- Mode: issue-resolution, Step 6. Issue: no GitHub issue; manager dispatch comm-019851, session opus-terra-design-and-implement-review-loop-session-849.
- Implemented mode precedence, discovery, channel and command partition, local reload, upgrade and error guidance in `docs/app-instance-control.md`; updated the CLI paragraph in `README.md`.
- Evidence directory: `tmp/serverless-app-control/sac-09-docs/`. Documentation checks ran against the shared working tree; serial integration and formal review remain downstream.
- `git diff --check -- docs/app-instance-control.md README.md`: exit 0 (`diff-check.log`).
- `grep -n 'app_not_running\|control.sock\|app.lock\|--server' docs/app-instance-control.md`: exit 0 (`grep.log`); all four terms present.
- `! grep -n 'RIELA_APP_SERVER\|--in-process' docs/app-instance-control.md README.md`: exit 0 (`forbidden.log`, empty).
- `git diff --stat -- README.md`: exit 0 (`readme-stat.log`), one insertion and one deletion in one paragraph.
- No source or test files changed. Formal review, integration verification, commit and push are downstream.
