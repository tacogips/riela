# Worktree integration audit (2026-09-24)

This records integration ownership; it does not mark implementation plans complete or delete recoverable branches/worktrees.

| Worktree / branch | Evidence against current `main` | Disposition |
| --- | --- | --- |
| `gateway-sdk-addons` / `feat/gateway-sdk-addons` | Clean at `03eaee1f`; `git merge-base --is-ancestor feat/gateway-sdk-addons main` succeeds. Main includes its accepted design/plan through `4d35b6c8`. | Already integrated. Keep the clean branch/worktree as recoverable history; do not cherry-pick it again. SDK add-on implementation remains governed by its plan index status. |
| `note-hub-improve` / `feat/note-hub-improve` | Clean at `55d35af8`. Its only branch-unique commit preserves an older Mail→Gmail rename across 23 files. Main commit `582c1f89` changed the same 23 paths while adding SQLite schema-generation work; main already has `impl-plans/progress/plans/gmail-gateway-addons.json`. | Do not replay the older commit over newer main. Retain the branch/worktree for recovery. This is a superseded rename, not proof that any Note implementation plan is complete. |
| `tauri-dashboard-app` / `feat/tauri-dashboard-app` | Clean at `d2c6991`; branch is an ancestor of main. | Feature integration already present. |
| `tauri-integration` / `integrate/tauri-dashboard-app` | Clean at `0bd95e8`; branch is an ancestor of main, including the current-main integration record. | Re-integration already present; retain history, no additional merge. |

The remaining Riela Note ownership and checklist reconciliation is tracked in
[`riela-note-extraction-audit.md`](riela-note-extraction-audit.md). That audit
explicitly leaves the active Note plans unresolved; this worktree audit does
not close them. Monja `tenant-sharding-d48` and unrelated live worktrees were
not modified.
