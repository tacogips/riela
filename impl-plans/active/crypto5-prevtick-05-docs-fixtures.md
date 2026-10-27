# c5pt-05-docs-fixtures: Notion and cron docs, cron fixture payloads

```json
{
  "planId": "c5pt-05-docs-fixtures",
  "planPath": "impl-plans/active/crypto5-prevtick-05-docs-fixtures.md",
  "dependsOn": [],
  "wave": 1,
  "writePaths": [
    "README.md",
    "docs/builtin-gateway-json.md",
    "examples/event-sources/README.md",
    "examples/event-sources/payloads/gmail-latest-mail-hourly-cron.json",
    "examples/event-sources/payloads/x-follower-ai-business-hourly-cron.json",
    "examples/wrike-project-kanban-agent/payloads/wrike-kanban-cron-tick.json",
    "examples/memory-consolidation/README.md",
    "impl-plans/progress/c5pt-05-docs-fixtures.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

This plan covers the documentation and authored-fixture deliverables of the
design (§1.4 Docs, §2.3 fixtures, §2.5). The fixture values are precomputed in
the design and were verified by Step 3. c5pt-06 adds a test asserting that
these fixtures agree with the code.

This plan edits only Markdown and JSON and runs no SwiftPM command, so it is
safe in wave 1 alongside c5pt-01.

## File-level changes

1. **`README.md`**
   - §"Notion pages and images" (around line 528): add one or two sentences.
     `riela/notion-gateway-read` and `riela/notion-gateway-write` accept
     `findChildPage`, and `riela/notion-gateway-write` also accepts
     `ensurePagePath`. Both are available in JSON mode
     (`config.operation` + `config.arguments`) because the operation list
     comes from the gateway catalog. Do not document argument names; they are
     owned by the gateway schema. Point to
     `riela gateway notion --role writer schema` instead.
   - New subsection `### Cron tick input`, inserted directly **before**
     `### Overlapping cron fires` (around line 997):
     - A key list: `scheduledAt`, `scheduledLocalTime`,
       `previousScheduledAt`, `previousScheduledLocalTime`, `firedAt`,
       `timezone`. Give each a format: the ISO-8601 UTC keys use fractional
       seconds, and the local keys use `yyyy-MM-dd HH:mm:ss` in the source
       timezone.
     - The definition. "Previous" is the latest occurrence of the same
       schedule strictly before `scheduledAt`. It is computed from the
       schedule and timezone only, so a tick that was skipped, coalesced or
       missed still counts. It is DST-aware: a skipped local time has no
       occurrence, and a repeated local time occurs twice.
     - The `0 55 * * * *` example, worded exactly as in design §2.5:
       - source `{"kind":"cron","schedule":"0 55 * * * *","timezone":"Asia/Tokyo"}`;
       - tick `2026-10-27 14:55:00`, with `scheduledAt`
         `2026-10-27T05:55:00.000Z`;
       - `previousScheduledAt` `2026-10-27T04:55:00.000Z` and
         `previousScheduledLocalTime` `2026-10-27 13:55:00`;
       - a binding template showing
         `"windowStart": "{{event.input.previousScheduledAt}}"` and
         `"windowEnd": "{{event.input.scheduledAt}}"`;
       - the statement that `[windowStart, windowEnd)` is the run window.
     - One sentence: receipts written before this release do not contain the
       new keys, and `events replay` reuses stored envelopes verbatim.
2. **`docs/builtin-gateway-json.md`**: in the Notion row (line 22) or the
   Notion notes, mention `findChildPage` (reader and writer) and
   `ensurePagePath` (writer), both catalog-provided. Keep the table's column
   format intact.
3. **`examples/event-sources/README.md`**, cron section (around line 402,
   where the cron sources are introduced): add one sentence naming
   `previousScheduledAt` and `previousScheduledLocalTime`, with a link to the
   README `Cron tick input` subsection.
4. **Fixtures.** Add both keys inside `input`, directly after
   `scheduledLocalTime`, and keep 2-space JSON indentation. Values:
   - `examples/event-sources/payloads/gmail-latest-mail-hourly-cron.json`:
     `"previousScheduledAt": "2026-06-01T00:00:00.000Z"`,
     `"previousScheduledLocalTime": "2026-06-01 09:00:00"`
   - `examples/event-sources/payloads/x-follower-ai-business-hourly-cron.json`:
     `"2026-05-31T23:00:00.000Z"` / `"2026-06-01 08:00:00"`
   - `examples/wrike-project-kanban-agent/payloads/wrike-kanban-cron-tick.json`:
     `"2026-08-05T23:59:30.000Z"` / `"2026-08-06 08:59:30"`
   - `examples/memory-consolidation/README.md`: in the sample envelope (around
     lines 145-148), add `"previousScheduledAt": "2026-08-08T18:00:00.000Z"`
     and `"previousScheduledLocalTime": "2026-08-09 03:00:00"`.

## Non-goals and pitfalls

- Do not edit `examples/event-sources/payloads/telegram-time-signal-cron.json`.
  It is a workflow input, not a cron envelope.
- Do not edit any binding file, workflow.json or source file in the examples.
- Do not bump VERSION. Do not add a release or changelog entry. Do not edit
  design docs; Step 2 already updated
  `design-docs/specs/event-listener-workflow-trigger/provider-source-types.md`.
- Keep the README style: short paragraphs and fenced `json` blocks.

## Verification (commands → required evidence)

```
python3 -I -m json.tool examples/event-sources/payloads/gmail-latest-mail-hourly-cron.json > /dev/null; echo exit=$?
python3 -I -m json.tool examples/event-sources/payloads/x-follower-ai-business-hourly-cron.json > /dev/null; echo exit=$?
python3 -I -m json.tool examples/wrike-project-kanban-agent/payloads/wrike-kanban-cron-tick.json > /dev/null; echo exit=$?
grep -n 'previousScheduled' README.md examples/event-sources/README.md examples/memory-consolidation/README.md examples/event-sources/payloads/*.json examples/wrike-project-kanban-agent/payloads/wrike-kanban-cron-tick.json
grep -n 'findChildPage\|ensurePagePath' README.md docs/builtin-gateway-json.md
grep -n '0 55 \* \* \* \*' README.md
```

Write all output to `tmp/crypto5-prevtick/c5pt-05-docs-fixtures/verify.log`.

Required results:

- All three `json.tool` runs end with `exit=0`.
- The grep finds the keys in all four example files plus both READMEs.
- Both Notion operations appear in README.md and in
  `docs/builtin-gateway-json.md`.
- The `0 55` example is present in README.md, before the
  `### Overlapping cron fires` heading. Check the line numbers.

## Done criteria

- `git diff --stat` touches only this plan's `writePaths`.
- Every grep above is non-empty, and the verification records are in the
  progress log.
