# c5pt-05-docs-fixtures progress

Status: implementation complete; ready for independent review.

## Method

Re-applied the held authored patch exactly with `git apply` to the working tree (no index/cache flags). The preflight check passed and the patch applied cleanly to all six intended content files. The patch is preserved as `tmp/crypto5-prevtick/c5pt-05-docs-fixtures/intended.patch`; per-edit progress intent is `tmp/crypto5-prevtick/c5pt-05-docs-fixtures/intended-progress.md`.

- Preflight log: `tmp/crypto5-prevtick/c5pt-05-docs-fixtures/apply-check.log` (exit 0).
- Apply log: `tmp/crypto5-prevtick/c5pt-05-docs-fixtures/apply.log` (exit 0).
- The README now documents the Notion catalog operations and cron input/window contract, the event-sources README links to that section, and the three JSON fixtures plus memory-consolidation sample include the design §2.3 previous-tick values directly after `scheduledLocalTime`.

## SHA-256 records

Pre-edit hashes were captured before applying the patch in `tmp/crypto5-prevtick/c5pt-05-docs-fixtures/pre-edit-sha256.txt`. Post-edit hashes for content files:

| File | Pre-edit SHA-256 | Post-edit SHA-256 |
| --- | --- | --- |
| `README.md` | `c543c0f30d41ac5dc641668b8a11d4f7db24abf9e7ad9e87c63a7937c32a839b` | `501f287418fdb158efee3dc5728d7d04407ed24184aaa970528c396cfa154002` |
| `examples/event-sources/README.md` | `1b065c60140c0f49f19063833b0b2f15815fe1f8b26ba675abebff375dd77337` | `9be59d6d4f2052a7abcd7533f342dc2ae38bb1b251301c2278b68bd0f6627838` |
| `examples/event-sources/payloads/gmail-latest-mail-hourly-cron.json` | `85eead19412f93bd07b34ca4e2dfcf965045d65c5da66a8154b7cab280842b30` | `f2a0c5c26afb95b3c12e04b8601b5e8d61febd77cda8b09217ac63c8b3cd3c9c` |
| `examples/event-sources/payloads/x-follower-ai-business-hourly-cron.json` | `8bfc5950dc6a3d13edc2e7e4a854e145063d7808e6a4175bc5f0cf796349a1e6` | `188dd4b9f518b7ea71527ce2fbde3e95856b96221c7785b0f9b5b02a1eb1c617` |
| `examples/wrike-project-kanban-agent/payloads/wrike-kanban-cron-tick.json` | `a8924fa3416ea583fb615ac09b6a4961fb823fb721831a2bd7d002ed51ed2a92` | `8d2bd83d1beb60aa7875737c4c7f79faaf9589694f6c86113e22c1d9025e0818` |
| `examples/memory-consolidation/README.md` | `596fb1562fe79307a8aeb6486c59e3c9cb18db6199bb7d112db79dcd3b66821a` | `ec8f042460d125f048d6261c86ec081a14232dc17db356299e940ea6eda8ebb3` |
| `impl-plans/progress/c5pt-05-docs-fixtures.md` | `ec6d592c2e1e7e228f35bcda895ee887e249a43530f133a89d0077998e09c262` | Recorded after overwrite in `tmp/crypto5-prevtick/c5pt-05-docs-fixtures/post-edit-sha256.txt` (self-hash is external to avoid a self-referential value). |

## Verification

All records have `testsRun: 0` and `failureCount: 0`; this docs/fixtures plan runs no SwiftPM checks. Each listed log is complete under `tmp/crypto5-prevtick/c5pt-05-docs-fixtures/`.

| Command | Exit | Log |
| --- | ---: | --- |
| `git apply --check -v tmp/crypto5-prevtick/held/cron-docs.patch` | 0 | `apply-check.log` |
| `git apply -v tmp/crypto5-prevtick/held/cron-docs.patch` | 0 | `apply.log` |
| `python3 -I -m json.tool examples/event-sources/payloads/gmail-latest-mail-hourly-cron.json > /dev/null; echo exit=$?` | 0 | `json-gmail.log` |
| `python3 -I -m json.tool examples/event-sources/payloads/x-follower-ai-business-hourly-cron.json > /dev/null; echo exit=$?` | 0 | `json-x-follower.log` |
| `python3 -I -m json.tool examples/wrike-project-kanban-agent/payloads/wrike-kanban-cron-tick.json > /dev/null; echo exit=$?` | 0 | `json-wrike.log` |
| `grep -c 'previousScheduled' README.md examples/event-sources/README.md examples/memory-consolidation/README.md examples/event-sources/payloads/gmail-latest-mail-hourly-cron.json examples/event-sources/payloads/x-follower-ai-business-hourly-cron.json examples/wrike-project-kanban-agent/payloads/wrike-kanban-cron-tick.json` | 0 | `grep-previous.log` |
| `grep -n 'findChildPage\|ensurePagePath' README.md docs/builtin-gateway-json.md` | 0 | `grep-notion.log` |
| `grep -n '0 55 \* \* \* \*' README.md` | 0 | `grep-cron-example.log` |
| `grep -n '### Cron tick input\|### Overlapping cron fires' README.md` | 0 | `grep-cron-headings.log` |
| `git diff --quiet -- examples/event-sources/payloads/telegram-time-signal-cron.json docs/builtin-gateway-json.md; echo exit=$?` | 0 | `diff-untouched.log` |
| `git diff --check -- README.md examples; echo exit=$?` | 0 | `diff-check.log` |

The heading order was observed at lines 1000 and 1028; the example is between them at line 1016. `grep-previous.log` reports six matches in `README.md`, two in the event-sources README, two in the memory-consolidation README, and two in each JSON fixture. The unrelated Telegram workflow input and the already-landed builtin gateway JSON docs are unchanged.

## Scope and ownership

Only the six authored content files and this plan's progress file are owned here. The shared working tree also contains Swift source/test changes owned by other plans; they were preserved and not included in this plan's edits. No commit, staging, SwiftPM, or lint command was run.

Machine-readable verification records:

```json
[
  {"command":"git apply --check -v tmp/crypto5-prevtick/held/cron-docs.patch","logPath":"tmp/crypto5-prevtick/c5pt-05-docs-fixtures/apply-check.log","exitStatus":0,"testsRun":0,"failureCount":0},
  {"command":"git apply -v tmp/crypto5-prevtick/held/cron-docs.patch","logPath":"tmp/crypto5-prevtick/c5pt-05-docs-fixtures/apply.log","exitStatus":0,"testsRun":0,"failureCount":0},
  {"command":"python3 -I -m json.tool examples/event-sources/payloads/gmail-latest-mail-hourly-cron.json > /dev/null; echo exit=$?","logPath":"tmp/crypto5-prevtick/c5pt-05-docs-fixtures/json-gmail.log","exitStatus":0,"testsRun":0,"failureCount":0},
  {"command":"python3 -I -m json.tool examples/event-sources/payloads/x-follower-ai-business-hourly-cron.json > /dev/null; echo exit=$?","logPath":"tmp/crypto5-prevtick/c5pt-05-docs-fixtures/json-x-follower.log","exitStatus":0,"testsRun":0,"failureCount":0},
  {"command":"python3 -I -m json.tool examples/wrike-project-kanban-agent/payloads/wrike-kanban-cron-tick.json > /dev/null; echo exit=$?","logPath":"tmp/crypto5-prevtick/c5pt-05-docs-fixtures/json-wrike.log","exitStatus":0,"testsRun":0,"failureCount":0},
  {"command":"grep -c 'previousScheduled' README.md examples/event-sources/README.md examples/memory-consolidation/README.md examples/event-sources/payloads/gmail-latest-mail-hourly-cron.json examples/event-sources/payloads/x-follower-ai-business-hourly-cron.json examples/wrike-project-kanban-agent/payloads/wrike-kanban-cron-tick.json","logPath":"tmp/crypto5-prevtick/c5pt-05-docs-fixtures/grep-previous.log","exitStatus":0,"testsRun":0,"failureCount":0},
  {"command":"grep -n 'findChildPage\\|ensurePagePath' README.md docs/builtin-gateway-json.md","logPath":"tmp/crypto5-prevtick/c5pt-05-docs-fixtures/grep-notion.log","exitStatus":0,"testsRun":0,"failureCount":0},
  {"command":"grep -n '0 55 \\* \\* \\* \\*' README.md","logPath":"tmp/crypto5-prevtick/c5pt-05-docs-fixtures/grep-cron-example.log","exitStatus":0,"testsRun":0,"failureCount":0},
  {"command":"grep -n '### Cron tick input\\|### Overlapping cron fires' README.md","logPath":"tmp/crypto5-prevtick/c5pt-05-docs-fixtures/grep-cron-headings.log","exitStatus":0,"testsRun":0,"failureCount":0},
  {"command":"git diff --quiet -- examples/event-sources/payloads/telegram-time-signal-cron.json docs/builtin-gateway-json.md; echo exit=$?","logPath":"tmp/crypto5-prevtick/c5pt-05-docs-fixtures/diff-untouched.log","exitStatus":0,"testsRun":0,"failureCount":0},
  {"command":"git diff --check -- README.md examples; echo exit=$?","logPath":"tmp/crypto5-prevtick/c5pt-05-docs-fixtures/diff-check.log","exitStatus":0,"testsRun":0,"failureCount":0}
]
```
