Execute one kanban card's subtask.

Card: taskKey `{{task.taskKey}}`, notebook `{{task.notebookId}}`, title
`{{task.title}}`.

Brief:

{{task.briefMarkdown}}

Acceptance criteria:

{{task.acceptanceMarkdown}}

Reviewer feedback from the previous round (empty on the first round):

{{task.feedback}}

Produce the deliverable as markdown. The deliverable is notebook content only
— do not edit repository files or run workspace-mutating commands. Address
every acceptance criterion and any reviewer feedback explicitly.

Return JSON only:

{
  "when": {},
  "payload": {
    "taskKey": "{{task.taskKey}}",
    "notebookId": "{{task.notebookId}}",
    "resultMarkdown": "the full deliverable markdown",
    "selfAssessment": "one paragraph on how the acceptance criteria are met"
  }
}
