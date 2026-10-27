# c5pt-05 docs and fixtures progress

Status: implementation complete; ready for downstream review and integration.

## Changes

- `README.md`: documented catalog-provided Notion JSON operations and writer schema command; added `Cron tick input` immediately before `Overlapping cron fires`, including all six input keys and formats, schedule-derived DST-aware previous occurrence, the Tokyo `0 55 * * * *` example, the binding window, and replay/no-backfill behavior.
- `docs/builtin-gateway-json.md`: Notion table row names `findChildPage` for reader and writer and `ensurePagePath` for writer; table columns remain intact.
- `examples/event-sources/README.md`: cron docs name both previous tick keys and link to the README subsection.
- Three authored cron JSON fixtures and the memory-consolidation README sample contain the design §2.3 previous tick values immediately after `scheduledLocalTime`. `telegram-time-signal-cron.json` was not changed.

## Verification

Complete command output: `tmp/crypto5-prevtick/c5pt-05-docs-fixtures/verify.log`.
All checks below exited 0; non-test checks ran zero tests and had zero failures.

| Command | Exit | Tests run | Failures |
| --- | ---: | ---: | ---: |
| `python3 -I -m json.tool examples/event-sources/payloads/gmail-latest-mail-hourly-cron.json > /dev/null; echo exit=$?` | 0 (`exit=0`) | 0 | 0 |
| `python3 -I -m json.tool examples/event-sources/payloads/x-follower-ai-business-hourly-cron.json > /dev/null; echo exit=$?` | 0 (`exit=0`) | 0 | 0 |
| `python3 -I -m json.tool examples/wrike-project-kanban-agent/payloads/wrike-kanban-cron-tick.json > /dev/null; echo exit=$?` | 0 (`exit=0`) | 0 | 0 |
| `grep -n 'previousScheduled' README.md examples/event-sources/README.md examples/memory-consolidation/README.md examples/event-sources/payloads/*.json examples/wrike-project-kanban-agent/payloads/wrike-kanban-cron-tick.json` | 0 | 0 | 0 |
| `grep -n 'findChildPage\|ensurePagePath' README.md docs/builtin-gateway-json.md` | 0 | 0 | 0 |
| `grep -n '0 55 \* \* \* \*' README.md` | 0 | 0 | 0 |
| `grep -n '### Cron tick input\|### Overlapping cron fires' README.md` | 0 | 0 | 0 |
| `git diff --quiet -- examples/event-sources/payloads/telegram-time-signal-cron.json` | 0 | 0 | 0 |
| `git diff --check` | 0 | 0 | 0 |

The cron headings appear at README lines 1000 and 1028, in the required order. The three JSON parser commands each reported `exit=0`. Grep output confirms the new keys in the three fixtures and memory-consolidation sample, both READMEs, both Notion docs, and the Tokyo schedule example.

## Completion criteria

- Assigned Notion and cron documentation is present and correctly placed.
- Fixture values and field order match design §2.3; JSON is valid.
- No Swift files changed, so no Swift build, test, or lint command is owned by this plan.
- Changed-file scope is exactly the seven documentation/fixture paths in this plan plus this progress log.

## Final source SHA-256

- `README.md`: `501f287418fdb158efee3dc5728d7d04407ed24184aaa970528c396cfa154002`
- `docs/builtin-gateway-json.md`: `d5f945e4f8a70c2ad6067d1d1254eb31f24a55e3d5fc48d1bb7eeefd43de27a2`
- `examples/event-sources/README.md`: `9be59d6d4f2052a7abcd7533f342dc2ae38bb1b251301c2278b68bd0f6627838`
- `examples/event-sources/payloads/gmail-latest-mail-hourly-cron.json`: `f2a0c5c26afb95b3c12e04b8601b5e8d61febd77cda8b09217ac63c8b3cd3c9c`
- `examples/event-sources/payloads/x-follower-ai-business-hourly-cron.json`: `188dd4b9f518b7ea71527ce2fbde3e95856b96221c7785b0f9b5b02a1eb1c617`
- `examples/wrike-project-kanban-agent/payloads/wrike-kanban-cron-tick.json`: `8d2bd83d1beb60aa7875737c4c7f79faaf9589694f6c86113e22c1d9025e0818`
- `examples/memory-consolidation/README.md`: `ec8f042460d125f048d6261c86ec081a14232dc17db356299e940ea6eda8ebb3`
