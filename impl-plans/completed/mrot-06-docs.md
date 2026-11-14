# mrot-06: Operator documentation for manual-run overlap

**planId**: mrot-06-docs
**dependsOn**: none (wave 1). It documents the pinned contracts in the design.
**Design Reference**: design-docs/specs/design-manual-run-overlap-and-terminal-reserve.md §3.2–§3.6, §5
**Created**: 2026-11-11
**Progress log**: impl-plans/progress/mrot-06-docs.md
**Evidence root**: tmp/manual-overlap-terminal-reserve/mrot-06/

## Intent

The user asked for both behaviors to be documented in
`docs/app-instance-control.md`. The README cron-overlap paragraph should
mention that manual sessions count.

## Non-goals

- No design-doc edits; they are already done.
- No source or test edits.
- Do not document the terminal-reserve change in user docs. It is a bug fix
  with no user-facing knob, and the loop-guard design amendment already
  records it.

## File-level changes

- `docs/app-instance-control.md`, section "## Run":
  - Add `[--allow-overlap]` to the synopsis.
  - Add a paragraph explaining:
    - `riela instance run` refuses with `instance_busy` (exit 1, stdout
      `{"error":"instance_busy","sessionId":"<id|pending>","exitCode":1}`)
      when the instance already has a live execution in the App profile's
      session store, whether cron-started or manual.
    - `--allow-overlap` bypasses the check.
    - An App older than this change rejects `--allow-overlap` with
      `invalid_configured_run`.
    - Crashed (orphaned) sessions never block.
  - Add a short "Cron overlap with manual runs" paragraph:
    - Live manual runs count as running for the cron binding's
      `overlapPolicy`. `skip` records `overlap-skip:<bindingId>:<manualSessionId>`.
    - `queue` waits until the manual run ends, preserving FIFO.
    - `concurrent` counts manual runs toward `maxConcurrentRuns`.
    - `cancelRunning` never cancels a manual run; it skips.
    - Known limits: a sub-second race window before session allocation, and
      the fact that instances sharing a workflow id in one profile share the
      check.
  - In the reload error-code table, leave the `instance_busy` row unchanged.
    The run-route variant is documented in the Run section.
- `README.md`: in the cron overlap paragraph (around lines 1204–1249, near
  `overlap-skip:<bindingId>:<runningSessionId>`), add one sentence saying that
  live manual (named-instance) sessions of the same workflow in the same
  session store count as running, and link `docs/app-instance-control.md`.

## Verification

- `/usr/bin/git diff --check -- docs/app-instance-control.md README.md`: exit 0.
- `/usr/bin/grep -n "allow-overlap" docs/app-instance-control.md`: at least 2 matches.
- `/usr/bin/grep -n "instance_busy" docs/app-instance-control.md`: shows the new Run paragraph.

Record the outputs and exit codes in the progress log, plus fresh-read pre
and post hashes. Stop on drift.

## Done when

- [x] Both docs updated, with wording consistent with the pinned contracts
      (flag name, JSON shape, reason format).
- [x] Progress log complete.
