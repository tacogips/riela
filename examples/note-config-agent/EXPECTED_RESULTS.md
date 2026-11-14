# note-config-agent expected results

- The agent first returns an auditable proposal.
- Follow-up workflow steps execute note GraphQL mutations for the proposed tag class, tag, auto-action, and ingestion workflow scaffold.
- The note store contains the `business-idea` class and tag after the mock run.
- `configureNoteAutoAction` stores `config-agent-auto-tagging-business-idea`.
- `scaffoldNoteIngestionWorkflow` writes `note-ingest-business-idea` under the supplied `workflowInput.workflowRoot`.
