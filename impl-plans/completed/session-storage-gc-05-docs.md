# sgc-05-docs: document the representation, defaults, automatic maintenance and overrides

**Status**: Ready
**planId**: sgc-05-docs
**dependsOn**: sgc-01-payload-fragments, sgc-02-default-retention, sgc-03-automatic-maintenance (wave W3)
**Design Reference**: design-docs/specs/design-session-storage-efficiency-and-default-gc.md §7 (plus §3-§6 for content); QA Q1-Q7
**Progress log**: impl-plans/progress/sgc-05-docs.md
**Evidence root**: tmp/session-storage-gc/sgc-05-docs/

## Intent and context

The acceptance criteria require that the docs describe four things:

- the storage representation;
- the built-in defaults;
- automatic maintenance;
- the overrides and opt-outs.

The current docs say the opposite in places:

- `README.md` "Runtime Data Retention" (line ~777) says "Retention ... is off
  when no `retention` policy is configured".
- The last paragraph of `docs/storage-doctor-and-compact.md` describes a
  4,096-page run-end vacuum that "does not ... change terminal-session
  retention policy".

Write from the shipped code. Read the merged sources of sgc-01, sgc-02 and
sgc-03 first, so that every number and name matches:

- `Sources/RielaCore/RuntimePayloadFragmentEncoder.swift`;
- `Sources/RielaCore/RielaRetentionConfiguration.swift` (`builtInDefault`);
- `Sources/RielaCLI/RunEndStorageMaintenance.swift` (budgets and caps);
- `Sources/RielaCLI/StorageMaintenanceCursor.swift`;
- `Sources/RielaCLI/GarbageCollectionCommand.swift` (help text).

The sgc-04 doctor fields are documented from the design §6 contract, because
sgc-04 runs in parallel. Name them exactly `reclaimable.remainingBytes`,
`reclaimable.remainingBytesIsUpperBound`, `reclaimable.recovery` and
`session.maintenance`.

## Non-goals

- No source or test edits.
- No design-doc edits; the baseline supersession notes already exist.
- No changes to `Resources/skills`, because the skill does not state
  no-config behavior (verified with grep).
- No version or changelog bump.

## File-level changes

### `docs/storage-doctor-and-compact.md`

- **New section "Payload representation".**
  - New execution payloads store each `inputSnapshot` subtree of 1024 bytes
    or more once per root session, as a content-addressed fragment.
  - Every older form stays readable: legacy inline snapshots, legacy CLI
    copies, embedded nested payloads and generation-11 payloads.
  - Digests are sha256 of the stored canonical JSON, and they are verified on
    read.
  - Schema generation 12: older binaries refuse the store.
  - No compression is used.
- **Replace the last paragraph with "Automatic maintenance".**
  - Hosts: `workflow run`, `session resume/rerun/continue`, `events serve`,
    `serve` and RielaApp.
  - Only terminal sessions with free locks are converted.
  - Outcome classes, including busy retry, parking after 3 failed attempts
    with the warning text, and the retired skip.
  - The `storage-maintenance.json` cursor location under the retention state
    directory.
  - Budgets and retry share per profile (runEnd 16/256/2 s with share
    8/128/1 s; scheduled 64/1024/10 s with share 32/512/5 s).
  - Incremental vacuum caps of 4096 and 65536 pages; never a full VACUUM.
  - Opt-out: `"automatic": false` or `RIELA_RETENTION_AUTOMATIC=0`.
- **Doctor fields.** Add `remainingBytes` (an upper bound), `recovery` for
  `auto_vacuum=NONE` (required versus available free bytes and the steps), and
  `session.maintenance` parked rows. Note that `storage compact --apply` can
  convert parked rows.
- **Compact prune step.** It now applies the effective policy, including the
  defaults.

### `README.md` ("Runtime Data Retention" section only)

- **Defaults.** Replace "off when no `retention` policy is configured" with
  the built-in defaults: results 30 days, messages deleted with their
  results, logs 30 days, no byte cap. Only fully terminal
  (`completed|failed|cancelled`), unprotected families are deleted. Running,
  suspended or locked sessions and members of a retained tree are kept.
- **Per-category fill.** Any category missing from a `retention` object uses
  its default. To opt out, use `{"keepForever": true}` per category,
  `"automatic": false`, or `RIELA_RETENTION_AUTOMATIC=0`.
- **Upgrade note.** Stores without config start removing terminal data older
  than 30 days.
- **Generated sweep.** The generated sweep (workflow history snapshots, event
  receipts, handover files) runs only with an explicit
  `results.maxAgeDays`.
- **`riela gc --dry-run`.** It shows the defaults with
  `policySource: default`.
- Do not edit other README sections. Another workflow edits main
  concurrently, so keep the diff inside this section.

### `docs/terminal-retention.md`

- Add a short note that automatic passes and `riela gc` apply the built-in
  default policy when no config exists, with a link to README "Runtime Data
  Retention". `session prune` itself is unchanged.

## Pitfalls

- **Accuracy.** Every number must match the merged code. If the code differs
  from the design, document the code and record the mismatch in the progress
  log for review. Do not silently "fix" the docs toward the design.
- **Phrasing.** Do not claim compression or a guaranteed size ratio on real
  stores. State only the mechanism and the tested ≥5x synthetic result.
- Keep the existing `VACUUM INTO` recovery wording. Link to it rather than
  duplicating it.

## Acceptance criteria

- `rg -n "off when no .retention. policy" README.md` → no match.
- `rg -n "built-in default" README.md docs/storage-doctor-and-compact.md docs/terminal-retention.md`
  → matches in all three files.
- `rg -n "storage-maintenance.json|parked|remainingBytes|_rielaPayloadRefs|1024" docs/storage-doctor-and-compact.md`
  → matches for each term.
- `git diff --stat -- README.md` touches only the retention section. Check
  with `git diff -U0 -- README.md`: every hunk is within that section.

## Verification

This plan runs no `swift build`, `swift test` or `swiftlint`, so it writes
nothing to `.build/`. `artifactRoots` is intentionally empty (see the index,
"Build cache").

```
mkdir -p tmp/session-storage-gc/sgc-05-docs
rg -n "off when no .retention. policy" README.md; echo "exit=$?"   # expect exit=1 (no match)
rg -n "built-in default" README.md docs/storage-doctor-and-compact.md docs/terminal-retention.md | tee tmp/session-storage-gc/sgc-05-docs/defaults.log
rg -n "storage-maintenance.json|parked|remainingBytes|_rielaPayloadRefs" docs/storage-doctor-and-compact.md | tee tmp/session-storage-gc/sgc-05-docs/terms.log
git diff -U0 -- README.md docs/storage-doctor-and-compact.md docs/terminal-retention.md > tmp/session-storage-gc/sgc-05-docs/docs.diff
```

`git diff` is read-only and allowed. What each command must show:

- The first command prints no match and `exit=1`.
- `defaults.log` has matches in all three files.
- `terms.log` has a match for each term.
- `docs.diff` hunks stay inside the stated sections.

## Progress-log expectations

Record in `impl-plans/progress/sgc-05-docs.md`: hashes, each command's output
or exit, the list of code facts checked (with file:line) behind each
documented number, and any design-versus-code mismatch.
