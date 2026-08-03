Handle the current Matrix inquiry after examining authorized memory payloads in the inbox.

Choose exactly one mode: llm_only for a direct answer, or run_workflow only when the allow-listed enterprise task workflow materially improves the result.

Return concise JSON with replyText, both mode flags, noteEntries, and one handoff_<persona-id> flag per teammate.
Set at most one handoff true. Ask only an unvisited teammate whose distinct expertise is needed.
Never write another persona's memory.
