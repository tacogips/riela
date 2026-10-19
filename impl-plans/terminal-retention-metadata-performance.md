# Terminal retention performance (issue #165)

Preserve fresh per-family lineage, status, revision and secondary ownership checks.
Use SQLite-maintained covering metadata expression indexes instead of rescanning
payload pages. Writable prune installs indexes transactionally; strict dry-run
never installs them and retains the legacy query fallback. Indexes contain only
identities, statuses, timestamps, lengths and reservation completion flags.

Check every existing path component freshly with portable lstat, rejecting NUL,
symlink and unexpected lookup failures. No path-validation cache is introduced.

Artifact cleanup retains secure_delete, exact transactional deletion and successful
TRUNCATE checkpoint before acknowledging each family. Compact the shared artifact
database once at finalization, reopening through fresh path checks. Always run this
finalization even with zero selected families, so interrupted cleanup can reclaim
free pages on retry. Memory reclamation and all logical protection rules remain
unchanged. Finalization errors remain failures.

Validation: 18 focused tests passed; opt-in disposable real-store benchmark is
separate. Tests cover indexed/legacy plan parity, old-writer updates, concurrent
running descendants, strict dry-run, fresh symlink/error/NUL rejection, secure
physical marker removal, zero-family compaction retry and retained running rows.
Large-copy benchmarks must start from the same pristine baseline, with full
secondary roots. No canonical prune is authorized by this change.

## Bounded maintenance

`--max-families 20` optionally bounds the total pending-recovery and newly
admitted family attempts. Omission retains full-plan behavior. Remaining
families stay eligible for a later invocation; `deferredFamilyCount` reports
them and final remaining bytes/protection are recomputed from the actual stores.
No family is split by the limit. A pending family's member cleanups consume one
family allowance together; new admission uses only the remaining allowance.
Strict dry-run applies the same pending-first allowance without writes. Final
compaction still runs once, and failure remains nonzero.
