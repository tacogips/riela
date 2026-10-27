# c5pt-05-docs-fixtures: re-apply the held Notion/cron docs and cron fixture patch

```json
{
  "planId": "c5pt-05-docs-fixtures",
  "planPath": "impl-plans/active/crypto5-prevtick-05-docs-fixtures.md",
  "dependsOn": [],
  "wave": 1,
  "writePaths": [
    "README.md",
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

This plan covers the documentation and authored-fixture deliverables in the
design: §1.4 Docs (the README part), §2.3 fixtures, §2.5, and "Continuation
rollout".

An earlier run already wrote these edits. They were taken off `main` and saved
as `tmp/crypto5-prevtick/held/cron-docs.patch` (115 lines, 6 file diffs).
**Re-apply that patch. Do not re-author the content.** The
`docs/builtin-gateway-json.md` Notion row already landed in `35a910d5`. The
patch has no hunk for it, and this plan does not own that file.

c5pt-06 (wave 2) adds a fixture-agreement test that reads the fixture files
this plan writes. That is why this plan sits in wave 1. Docs and code are
committed together in serial finalization, so no pushed revision documents
keys the code does not produce.

This plan edits only Markdown and JSON. It runs no SwiftPM command.

## File-level changes

Step 1 (preferred): from the repository root, run

```
git apply --check -v tmp/crypto5-prevtick/held/cron-docs.patch > tmp/crypto5-prevtick/c5pt-05-docs-fixtures/apply-check.log 2>&1; echo exit=$?
git apply -v tmp/crypto5-prevtick/held/cron-docs.patch > tmp/crypto5-prevtick/c5pt-05-docs-fixtures/apply.log 2>&1; echo exit=$?
```

`git apply` writes only the working tree. **Never** pass `--index` or
`--cached`, and never run `git add`.

Step 2 (fallback, only if `--check` exits non-zero or the patch file is
missing): apply the same hunks by hand. The values are fixed by the design
and listed below, and must be copied exactly:

1. **`README.md`, Notion section:** after the paragraph ending "Reader
   mutations are rejected before credentials or transport." (around line
   535), add these three lines:
   "The catalog-provided JSON-mode operations include `findChildPage` for
   reader and writer, and `ensurePagePath` for writer. See
   `riela gateway notion --role writer schema` for the writer schema."
2. **`README.md`, cron section:** insert a new `### Cron tick input`
   subsection directly before `### Overlapping cron fires` (around line 997).
   Its content is patch lines 19-46:
   - the six-key list with formats;
   - the schedule-derived, DST-aware definition;
   - the Tokyo `0 55 * * * *` example: `2026-10-27T05:55:00.000Z`, previous
     `2026-10-27T04:55:00.000Z` / `2026-10-27 13:55:00`;
   - the `windowStart`/`windowEnd` binding and the `[windowStart, windowEnd)`
     run window;
   - the no-backfill/replay sentence.
3. **`examples/event-sources/README.md`:** after "checked-in placeholder
   remains deterministic for local validation." (around line 409), add
   "Cron tick envelopes also include `previousScheduledAt` and
   `previousScheduledLocalTime`; see
   [Cron tick input](../../README.md#cron-tick-input) for formats and the
   run-window example."
4. **Fixtures:** add two keys inside `input`, directly after
   `scheduledLocalTime`, with 2-space indentation:
   - `gmail-latest-mail-hourly-cron.json`:
     `"previousScheduledAt": "2026-06-01T00:00:00.000Z"`,
     `"previousScheduledLocalTime": "2026-06-01 09:00:00"`
   - `x-follower-ai-business-hourly-cron.json`:
     `"2026-05-31T23:00:00.000Z"` / `"2026-06-01 08:00:00"`
   - `wrike-kanban-cron-tick.json`:
     `"2026-08-05T23:59:30.000Z"` / `"2026-08-06 08:59:30"`
   - `examples/memory-consolidation/README.md` sample envelope (around lines
     144-145): `"previousScheduledAt": "2026-08-08T18:00:00.000Z"`,
     `"previousScheduledLocalTime": "2026-08-09 03:00:00"`

Step 3: **overwrite** `impl-plans/progress/c5pt-05-docs-fixtures.md`. The
copy committed in `c14c3b30` describes the earlier, held-back run and is
stale. Record:

- this run's method (patch or fallback);
- the apply logs;
- pre and post `shasum -a 256` for every file this plan writes;
- the verification records.

## Invariants and non-goals

- The values and wording must equal the held patch, design §2.3 and design
  §2.5. Do not "improve" the text. Do not document Notion argument names;
  the gateway schema owns them.
- Do not touch `docs/builtin-gateway-json.md`, which already landed. Do not
  touch `examples/event-sources/payloads/telegram-time-signal-cron.json`
  (it is a workflow input, not an envelope), binding or source files,
  workflow.json, Swift files, design docs or `VERSION`.
- No changelog or release entry.
- Do not run `git commit`, `stash`, `reset`, `checkout`, `restore`, `add` or
  `push`.

## Verification (commands → required evidence)

Append the output of every command to
`tmp/crypto5-prevtick/c5pt-05-docs-fixtures/verify.log`:

```
python3 -I -m json.tool examples/event-sources/payloads/gmail-latest-mail-hourly-cron.json > /dev/null; echo exit=$?
python3 -I -m json.tool examples/event-sources/payloads/x-follower-ai-business-hourly-cron.json > /dev/null; echo exit=$?
python3 -I -m json.tool examples/wrike-project-kanban-agent/payloads/wrike-kanban-cron-tick.json > /dev/null; echo exit=$?
grep -c 'previousScheduled' README.md examples/event-sources/README.md examples/memory-consolidation/README.md examples/event-sources/payloads/gmail-latest-mail-hourly-cron.json examples/event-sources/payloads/x-follower-ai-business-hourly-cron.json examples/wrike-project-kanban-agent/payloads/wrike-kanban-cron-tick.json
grep -n 'findChildPage\|ensurePagePath' README.md docs/builtin-gateway-json.md
grep -n '0 55 \* \* \* \*' README.md
grep -n '### Cron tick input\|### Overlapping cron fires' README.md
git diff --quiet -- examples/event-sources/payloads/telegram-time-signal-cron.json docs/builtin-gateway-json.md; echo exit=$?
git diff --check -- README.md examples; echo exit=$?
```

Required results:

- All three `json.tool` runs print `exit=0`.
- `grep -c` is at least 1 for every file: 2 for each JSON fixture and for the
  memory-consolidation README, and at least 2 for README.md.
- README.md and docs/builtin-gateway-json.md each name both Notion operations.
- The `0 55` example line number is between the `### Cron tick input` and
  `### Overlapping cron fires` line numbers, and `Cron tick input` comes
  first.
- The two `git diff` checks print `exit=0`.

## Done criteria

- `git diff --stat` lists only this plan's `writePaths`. Other plans' files
  may appear from parallel workers; ignore them, but never edit them.
- Every verification record is in the progress log as
  `{command, logPath, exitStatus, testsRun: 0, failureCount: 0}`.
