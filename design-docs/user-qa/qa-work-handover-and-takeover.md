# Work handover and takeover user-QA

Design: `design-docs/specs/design-work-handover-and-takeover.md` §19.
Plan: `impl-plans/active/work-handover-and-takeover.md`.
Each question states a default; implementation proceeds on the default
until the user answers here.

## Q1. Attempt branch template and checkpoint squashing

**Question**: Keep `riela/task/<taskId>/g<generation>` as the default
branch template, and keep step-boundary checkpoint commits in the branch
history after acceptance?

**Context**: Checkpoints bound the work lost on an orphan takeover to one
step, but they add many small commits with a `Riela-Checkpoint:` trailer.

**Options**: (a) keep checkpoints, squash only when the task's completion
contract asks for a single commit; (b) always squash at accept-time
finalization; (c) never checkpoint by default (`handover.checkpoint: none`).

**Default until answered**: (a).

**Impact**: (b) changes the existing git finalization path; (c) makes S3
recovery lose a whole attempt's work.

## Q2. Default sinks

**Question**: With no `handover.sinks` configured, should the packet be
mirrored to the default kaiba instance when one exists?

**Options**: (a) store only; (b) store + kaiba note when a default,
reachable instance exists.

**Default until answered**: (a). Mirroring publishes the packet outside the
host; opt-in keeps that explicit.

**Impact**: (b) makes cross-host reads work with no configuration but
writes a note for every handover.

## Q3. `task serve --takeover` timing

**Question**: Ship the unattended successor poller in H6 as its own loop,
or wait for Work Runtime P3's `task serve`?

**Default until answered**: ship in H6; fold into `task serve` when P3
lands.

**Impact**: Waiting means S2 takeovers on the user's machine are always
manual (`task takeover`) until P3.

## Q4. Lease defaults

**Question**: Lease TTL 300 s and heartbeat 15 s?

**Context**: Loop leases use 600 s staleness; distributed job leases use
30 s with 1 s polling. A task attempt heartbeats on every snapshot save
plus a timer.

**Default until answered**: 300 s / 15 s, per-task override in
`guard.lease`.

**Impact**: A shorter TTL makes orphan recovery faster and false fencing of
a paused laptop more likely.

## Q5. Envelope key

**Question**: Reserve the top-level output key `handover`, or namespace it
as `riela.handover`?

**Default until answered**: `handover`, rejected by validate when a node's
`output.jsonSchema` declares it as a business property.

**Impact**: Namespacing avoids collisions with existing payloads that
already use the word; none were found in `examples/`.

## Q6. Adoption of plain sessions

**Question**: Should `session handover` create the intent and task
automatically with default guard and director policies, or require
`--task <existing taskId>`?

**Default until answered**: automatic adoption with defaults; `--task`
optional to attach to an existing task.

**Impact**: Automatic adoption is what makes the feature usable for
`workflow run` sessions without a Work Runtime setup.

## Q7. Per-invocation host traits (added 2026-09-30, design §10.3 / §21 R5)

**Question**: May `task takeover --traits userReachable` (and `task serve
--takeover --traits …`) declare traits for that invocation, in addition to
the persistent declaration in the app profile / `worker.json`?

**Context**: There is no `riela config` command; persistent local traits
live in the app profile state beside backend declarations. A user sitting
at the successor host is itself the evidence of `userReachable`.

**Options**: (a) allow `--traits`, recorded in the takeover's placement
evidence; (b) persistent declaration only.

**Default until answered**: (a).

**Impact**: (b) forces a profile edit before every first takeover on a
laptop; (a) lets an operator claim a trait the host does not have, which is
visible in the evidence.

## Q8. Handover sink configuration scope (added 2026-09-30, design §8 / §21 R6)

**Question**: Configure sinks only on the task and the workflow (plus
`--sink` on `task handover` / `session handover`), with no user-profile
default?

**Default until answered**: yes, task and workflow only. Consistent with
Q2 (store only unless opted in).

**Impact**: A user-wide default sink would need a new profile field and
would publish packets from every task without per-task opt-in.
