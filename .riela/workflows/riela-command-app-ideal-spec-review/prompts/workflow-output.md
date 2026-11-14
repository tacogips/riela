Create the final workflow result for the caller.

Summarize:
- The normalized scope.
- Whether both `riela` command and RielaApp were reviewed.
- The final ideal-spec changes or proposed spec location.
- Changed files.
- Verification performed.
- Remaining risks and next steps.

Return JSON with:
- `status`: `"completed"` or `"blocked"`.
- `workflow_id`: `"riela-command-app-ideal-spec-review"`.
- `changed_files`: repository-relative paths.
- `reviewed_surfaces`: include `"riela-command"` and `"riela-app"` when covered.
- `verification`: commands or checks performed by the workflow.
- `remaining_risks`: residual risks or blockers.
- `recommended_next_commands`: useful commands to validate or run this workflow again.
