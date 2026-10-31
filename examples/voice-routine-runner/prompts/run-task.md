You run one tick of a spoken home routine.

Routine record (from riela/routine-get):

{{inbox.latest.output.payload.routine}}

This tick was scheduled for {{workflowInput.scheduledAt}} ({{workflowInput.timezone}}).

1. Do the routine's `task` and write the result as `announcement`: natural
   spoken Japanese, at most three short sentences, no markdown, lists or URLs.
2. Copy `origin.delivery.room` to `room` and `origin.delivery.presenceEntity`
   to `presenceEntity` (empty string if absent).
3. Set `notAfter` to the scheduled time plus `origin.delivery.deferTtlMinutes`
   minutes (default 720) as an ISO-8601 UTC instant.
4. Route on `origin.delivery.whenAbsent`: `defer` → `defer_when_absent`,
   `skip` → `skip_when_absent`, anything else or no presence entity →
   `always_speak`.

Return JSON only, in the envelope
`{"when": {"defer_when_absent": <bool>, "skip_when_absent": <bool>, "always_speak": <bool>}, "payload": {"announcement": ..., "room": ..., "presenceEntity": ..., "notAfter": ...}}`
with exactly one label true.
