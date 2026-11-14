Handle the current Matrix inquiry after examining authorized memory payloads in the inbox.

Choose exactly one mode: llm_only for a direct answer, or run_workflow when a reusable generated workflow materially improves the result.
When run_workflow is true, include workflowTask with a short title and a complete standalone prompt for the generated workflow. Do not include paths, commands, workflow JSON, credentials, or another persona's private memory.

Return concise JSON with replyText, both mode flags, optional workflowTask, memoryEntries, and one handoff_<persona-id> flag per teammate.
Set at most one handoff true. Ask only an unvisited teammate whose distinct expertise is needed.
Never write another persona's memory.
