Synthesize the intake, `riela` command review, and RielaApp review into one user-facing ideal specification.

The specification must cover both surfaces instead of treating one as an implementation detail of the other. It should be useful to product/design reviewers and to engineers planning implementation.

Include these sections:
- `Problem Statement`: The user pain and product goal.
- `User Personas And Jobs`: At least command user, app user, and package author/operator when relevant.
- `Ideal Cross-Surface Model`: Shared concepts, package states, required env metadata, disabled/enabled behavior, readiness, update status, and source/scope vocabulary.
- `Riela Command Experience`: Commands, flags, output fields, status labels, errors, examples, and acceptance criteria.
- `RielaApp Experience`: List/table states, controls, dialogs, confirmations, secret handling, error copy, and acceptance criteria.
- `Metadata Contract`: Manifest fields, package/workflow env metadata, disabled state, readiness fields, update fields, and compatibility assumptions.
- `Review And Verification Plan`: CLI tests, app support tests, UI QA, docs/examples, and regression checks.
- `Prioritized Backlog`: Must/should/could changes with rationale.
- `Open Questions And Non-Goals`: Explicitly separate real unknowns from deferred implementation detail.

If `workflowInput.outputDocumentPath` is present, update that repository-relative markdown file with the improved specification. Preserve useful existing content, but do not preserve unclear or stale text for backward compatibility. If no output path is present, return the full proposed specification in JSON instead of editing files.

Return JSON with:
- `updated_files`: repository-relative paths changed.
- `ideal_spec_summary`: concise summary of the synthesized specification.
- `spec_sections`: list of sections produced.
- `command_coverage`: coverage notes for the command surface.
- `app_coverage`: coverage notes for the app surface.
- `backlog`: prioritized backlog entries.
- `verification_recommendations`: commands or QA paths to run later.
- `open_questions`: remaining non-blocking questions.
