Review the live-progress loop evidence persistence slice.

Check:
- The implementation projects evidence from the same bundle/session inputs used by final persistence.
- The live persistence callback does not mutate JSONL progress record shapes.
- The regression test observes persisted loop evidence while the command node is still running.
- No unrelated dirty worktree changes are reverted.
