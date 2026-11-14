Inspect the current worktree and the requested work in `workflowInput`. Read the ideal-spec review artifact when its path is supplied, but verify every claim against current source and tests.

Define the concrete user journey and implementation plan for all of these requirements:
- RielaApp assistant system instructions require a dedicated Riela workflow for every non-trivial task and require that workflow to be executed rather than merely authored.
- The task workflow is invocation-private at the Riela product boundary: it is never registered, imported, listed, or reusable by another agent. Do not claim same-OS-user filesystem isolation that the product cannot prove.
- The task run writes to the active profile's shared session store so Riela Web can show live and persisted progress by session ID even when no configured instance or surviving workflow definition exists.
- A stable Web deep link opens that run detail directly.
- One Riela Note notebook represents one workflow run, organized under workflow-specific and date-specific folder tags, with separate Input, Work log, and Response notes and a deep link to the Web run detail.
- Determine from evidence whether separate workflow view/run scopes are needed. Prefer no new scopes if unregistered ephemeral ownership plus session authorization satisfies the actual product boundary.

Preserve unrelated changes. Keep scratch output under `tmp/`. Return concise JSON with `plan`, `target_files`, `acceptance_criteria`, `verification`, and `risks`.
