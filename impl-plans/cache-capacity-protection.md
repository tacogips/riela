# Pending retrieval cache capacity protection

Issue: https://github.com/tacogips/riela/issues/158

Add persisted per-entry capacity protection to the separate retrieval cache.
Default put behavior remains LRU; protected replacement stays protected until
revision-checked explicit release. All put/configure/prune operations honor the
same flag under BEGIN IMMEDIATE. Insufficient capacity rolls back, including
expiry, changes, sequence increments, and attempted evictions. TTL remains fixed
and independent. Release does not delete or touch access order.

Schema 2 migration defaults old entries to unprotected; old clients fail closed.
Operators must quiesce older shared-cache clients and protect existing pending
body/image references before resuming writers. No live migration is performed as
part of development or release.

Gates: fake-clock core tests, cross-scope writers, full-batch rollback, stale
revision release, sticky replacement, release/LRU ordering, policy-shrink
rollback, schema migration, CLI roundtrip, lint, independent review.
