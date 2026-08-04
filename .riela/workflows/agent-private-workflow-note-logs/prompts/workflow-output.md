Audit the completed work against every acceptance criterion in `workflowInput` and the prior workflow messages. Return concise JSON with:
- `status` (`complete` only when every requirement is proven);
- `workflow_privacy_contract`;
- `web_progress_and_deep_link`;
- `note_worklog_contract`;
- `view_run_scope_decision`;
- `changed_files`;
- `verification`;
- `residual_risks`;
- `user_journey`.

Do not claim completion from intent or partial tests. Preserve exact session IDs and artifact paths when available.
