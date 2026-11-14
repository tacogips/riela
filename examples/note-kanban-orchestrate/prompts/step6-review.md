Review every kanban card from the joined branch records.

`{{fanoutJoin}}` contains `branches[]` in input order. Each
branch record has `status` (`completed` or `failed`), the branch `item` (the
card: taskKey, notebookId, title, briefMarkdown, acceptanceMarkdown, round),
and for completed branches the final branch `output` (the mark-review payload;
the executed result was recorded on the card's notebook). A branch whose item
was skipped by a claim conflict carries `conflict: true` in its output —
treat that card as already handled elsewhere and pass it through unless its
status is `failed`.

Round bookkeeping: the current round is 1 + the highest `round` value found
on any branch item (items without `round` count as round 1). The rework
budget is `{{workflowInput.maxReworkRounds}}` rounds (default 3 when empty).

Verdicts: a card passes when its branch completed and its result satisfies
the card's acceptance criteria. A card fails when the branch failed (use the
`failureReason`) or the result misses acceptance criteria.

Routing flags you must set exactly:

- every card passed → `all_pass: true`, `needs_rework: false`
- failures exist and current round < budget → `all_pass: false`,
  `needs_rework: true`
- failures exist and current round >= budget → `all_pass: false`,
  `needs_rework: false` (finalize with unresolved cards)

Return JSON only:

{
  "when": { "all_pass": false, "needs_rework": false },
  "payload": {
    "round": 1,
    "maxReworkRounds": 3,
    "verdicts": [
      { "taskKey": "…", "notebookId": "…", "passed": true, "reason": "…" }
    ],
    "passedTasks": [
      { "taskKey": "…", "notebookId": "…", "title": "…", "progress": "review" }
    ],
    "failedTasks": [
      {
        "taskKey": "…",
        "notebookId": "…",
        "title": "…",
        "briefMarkdown": "…",
        "acceptanceMarkdown": "…",
        "progress": "review",
        "round": 2,
        "feedback": "specific, actionable reviewer feedback"
      }
    ]
  }
}

`failedTasks[].progress` must be the card's current status name (rework
claims use it as the compare-and-set expectation; a card failed before its
claim still holds its previous status). `failedTasks[].round` is the round
the rework will run (current round + 1).
