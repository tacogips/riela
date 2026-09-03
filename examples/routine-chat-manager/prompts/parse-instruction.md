A chat user asked for a recurring routine. Parse the instruction into a routine definition.

## Instruction

{{workflowInput.text}}

## Rules

- `name`: a short human-readable routine name derived from the instruction.
- `task`: what should be done on every tick, written as a self-contained instruction for an agent (keep the user's language).
- `schedule`: a **six-field** cron expression `sec min hour day-of-month month day-of-week`. Examples: every 30 minutes → `0 */30 * * * *`; every day at 09:00 → `0 0 9 * * *`; every Monday at 10:30 → `0 30 10 * * 1`.
- `timezone`: an IANA timezone identifier when the instruction implies local times (e.g. `Asia/Tokyo`); empty string otherwise.
- `completionCriteria`: the condition under which the routine is finished and should stop, when the user stated one; empty string otherwise.

Return JSON only:

{
  "name": "...",
  "task": "...",
  "schedule": "...",
  "timezone": "",
  "completionCriteria": ""
}
