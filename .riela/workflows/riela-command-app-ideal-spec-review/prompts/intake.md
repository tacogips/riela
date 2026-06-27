Read `workflowInput` and normalize the user-facing ideal-spec review request.

Expected `workflowInput` fields, all optional unless the caller supplies them:
- `requestedWork`: Natural-language request.
- `featureName`: Feature, package, workflow, or product surface being reviewed.
- `sourceDocumentPaths`: Existing design, QA, README, implementation-plan, or user-review documents.
- `outputDocumentPath`: Repository-relative markdown path to update with the improved ideal specification. If absent, do not create a new document unless the request explicitly asks for one.
- `implementationHints`: Relevant source directories, commands, or package names.
- `constraints`: Constraints such as no commits, no network, or compatibility assumptions.

Gather only repository-local evidence. Prefer existing docs and source over assumptions. Inspect likely sources for both surfaces:
- Riela command documentation, CLI sources, package/workflow command docs, and tests.
- RielaApp documentation, app support sources, import/list/run surfaces, package metadata surfaces, and tests.

Return JSON with:
- `accepted`: true when the request is clear enough to continue.
- `scope`: concise normalized scope.
- `source_documents`: paths read or missing.
- `command_evidence_targets`: paths or commands the command-review step should inspect.
- `app_evidence_targets`: paths or code areas the app-review step should inspect.
- `output_document_path`: resolved path or null.
- `constraints`: normalized constraints.
- `open_questions`: only blockers that cannot be answered from local context.
