# QA: efficient history and session storage

These are open decisions for `design-docs/specs/design-efficient-history-and-storage.md`.
Each question gives a recommended decision, and the design already assumes
it. Answer only to override a recommendation.

## Q1: What does "session payload retention applies automatically at run end" delete?

Superseded on 2026-10-30. The "built-in default policy" alternative below was
adopted with these values: results 30 days, messages deleted with their
results, logs 30 days. See `design-session-storage-efficiency-and-default-gc.md`
§4 and `qa-session-storage-default-gc.md`.

Recommended decision: at the end of each run, Riela automatically does two
bounded things:

- releases the finished family's unreferenced payload rows (normally there are
  none, because they are already freed when a payload is replaced);
- runs a bounded `incremental_vacuum` on the session database.

The new storage model removes the duplicate CLI copy, the whole-JSON rewrites
and the embedded nested copies. Run-end work therefore no longer has to delete
whole sessions to keep their size bounded.

Deleting whole terminal sessions stays governed by the `retention` config.
This keeps the accepted invariant "no config means no deletion" from
`design-automatic-retention.md` §8.1.

Alternative: ship a built-in default policy, for example results/messages at
30 days, that applies when no config exists. That would reverse the earlier
decision.

## Q2: Command names and the legacy snapshot store

The issue names `riela workflow versions`, `version show`, `version diff`,
`restore` and `riela workflow undo|redo`. In the code, those first four
commands belong to the file-based registry snapshot store (`WorkflowHistoryStore`,
content-addressed chunks). The #179 SQLite definition store, which the issue's
C0 facts describe, uses `riela workflow definition history|show|diff|restore`.

Recommended decision:

- Implement the retention and "dropped by retention" reporting on the
  `workflow definition` commands.
- Add undo and redo as `riela workflow definition undo|redo`, plus the GraphQL
  mutations.
- Leave the registry snapshot store unchanged. It was not part of the measured
  growth, and chunk dedupe already bounds it.

Alternative: also add top-level `riela workflow undo|redo` aliases for the
definition store.

## Q3: Which sessions protect a definition version?

Recommended decision: every session that still exists in its store protects
its version, whatever its status. `riela session rerun` of a terminal session
loads its pinned version, so a status-based rule would break rerun.

Pins are released when the session is pruned. The window therefore only
shrinks once old sessions are pruned under the `retention` policy.

## Q4: Attachment files of dropped memory versions

Recommended decision: leave the files in place, because they were not part of
the measured growth. `riela doctor storage` reports them as
`unreferencedAttachmentBytes`. Deleting them is a follow-up.

## Q5: Audit rows of dropped definition versions

Recommended decision: delete an audit row only when both its `version_id` and
its `previous_version_id` were dropped. Every audit row that describes a
change into or out of a retained version stays.

## Q6: Is snapshot-store history configurable?

Recommended decision: no. `riela/snapshot-store` writes always use one
generation (no history). Retained snapshot labels (TTL pins) still protect the
versions they reference, which covers rollback. A memory's declared
`historyRetention` applies to its ordinary records only.

## Q7: Abandoned-run age threshold

Recommended decision: 24 hours by default (`--abandoned-after-hours`, range
1...8760). It applies to nested-invocation settlement and `created`-child
cancellation in `session reconcile` and `storage compact`. The existing
reconcile of `running` sessions keeps its flock-only rule and has no age
threshold.
