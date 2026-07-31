Decompose the requested task into independent subtasks for a kanban board.

Request: `{{workflowInput.task}}`
Folder tag: use `{{workflowInput.folderTagName}}` when set; otherwise derive a
short kebab-case folder name from the request.

Hard constraints:

- Every subtask's deliverable is notebook content only: analysis, research,
  writing, or planning recorded as markdown. Never emit subtasks that edit
  repository files, run builds, or mutate the workspace — parallel branches
  share one working directory.
- 2 to 8 subtasks, each independently executable (no ordering dependencies).
- `taskKey` must be a stable kebab-case identifier unique within this run;
  reruns must produce the same taskKeys so existing cards are reused.

Return JSON only:

{
  "when": {},
  "payload": {
    "folderTagName": "board folder tag name",
    "tasks": [
      {
        "taskKey": "stable-kebab-key",
        "title": "short card title",
        "briefMarkdown": "what to do, with enough context to execute alone",
        "acceptanceMarkdown": "bullet list of acceptance criteria"
      }
    ]
  }
}
