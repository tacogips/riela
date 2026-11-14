You are executing one scheduled tick of the routine "{{workflowInput.routineName}}" (routine id: {{workflowInput.routineId}}).

Scheduled at: {{workflowInput.scheduledLocalTime}} ({{workflowInput.timezone}})

## Task to perform now

{{workflowInput.task}}

## Completion criteria

{{workflowInput.completionCriteria}}

(An empty criteria means the routine never completes itself.)

## Instructions

1. Perform the task above to the extent possible in this run.
2. Decide whether the completion criteria is now fully and verifiably satisfied. When the criteria is empty or you are not certain it is satisfied, it is not met.

Return JSON only:

{
  "result": "<short summary of what you did this tick>",
  "conditionMet": false,
  "completionNote": "<why the criteria is met; empty string when conditionMet is false>"
}

Set "conditionMet" to true only when the completion criteria is clearly satisfied.
