# Scoped memory history retirement

Problem: moving acquisition payloads into TTL cache and updating the permanent checkpoint leaves the prior payload reconstructible through reverse-delta history. Normal update/history semantics must remain unchanged.

Scope: an explicit single-record irreversible retirement command. Require absolute memory root, memory ID, record ID, workflow/node ownership, required tags, exact expected head, and through=head-1. Preserve current record, record identity, other records, metadata, audit references, and monotonically increasing version numbers. No filesystem sweeps or attachment deletion.

Implementation: additive schema5 retained floor; old history/show/restore below floor cannot reconstruct. Replace the head marker's reverse edge with an identity marker and remove older edges under exclusive SQLite admission. Keep the head number, so future updates/restore CAS cannot suffer version reset/ABA. Dry-run uses a read-only connection without schema migration. Busy reader/writer, attachments, incoming related references and uninspectable other-record history block retirement. Secure deletion plus VACUUM and truncated WAL runs before exclusive connection closes; report pending reclaim honestly if physical reclaim fails.

Validation: synthetic historical-body retirement and byte scanning; exact head/other records preserved; retired versions fail; future revisions preserve increasing numbers; stale-head/ownership/ref/attachment/busy reader gates; dry-run byte identity; schema4 upgrade; CLI parse/runner tests. Package-only tests use an isolated scratch path and two jobs. Root reviews before release or applying migration to real ART state.

Limit: database admission cannot recall values already copied into application heaps or exports. Applications must quiesce their own acquisition activity before apply. Version-unaware load/search audit logs are access audit, not durable version pins. They are preserved and do not block retirement (reviewed with task owner).

## Verification and review

- Issue: https://github.com/tacogips/riela/issues/152
- All 53 RielaMemory package tests passed with isolated scratch and two jobs.
- Three focused CLI tests passed, including parsed dry-run/apply/retired-version failure and existing history/show/restore behavior.
- Independent review found the cross-record retired-marker blocker and companion path exposure; both were fixed and covered by regressions.
- Root reviewed the schema-initialization race correction: schema admission now covers version read, migrations, and initialization atomically.
- Root verified a fresh copy of a real acquisition store: dry-run was byte-identical; apply retired three revisions (22,712 delta bytes), reclaimed storage, preserved the exact head object, and made the old five-body revision unavailable. Original stores were untouched.
- Release 0.2.17 is required before applying schema 5 to application-owned live stores. Apple SDK cancellation work is a separate release and is not included here.
