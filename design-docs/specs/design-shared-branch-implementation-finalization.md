# Shared-branch implementation finalization

Status: implemented; verification tracked in the accompanying implementation plan.

## Request and runtime evidence

The registry's design/implementation workflows now checkpoint all accepted plans,
run dependency-ready implementation/review branches concurrently in one working
directory and branch, reconcile overwritten work after joining, then commit,
push and integrate the base branch. Worktrees are explicitly excluded.

Native fanout already supports shared-directory branch execution. Dependency-wave
selection and cooperative change evidence extend it without introducing an
ownership guarantee. The existing protected Codex finalization
policy, however, assumes exactly one commit node, push immediately preceding
workflow-output, and step6-implement appearing in the parent session. The new
graph fails with `git_finalization_evidence_invalid: protected workflow
finalization policy is missing or ambiguous` even with successful mock branches.

## Change

Keep exact accepted commit/push evidence matching. Identify the unique final
commit directly feeding the unique final push. Permit one additional named
plan-git-commit only when it feeds dispatch-plans with a fanout transition;
continue rejecting detached/ambiguous extra Git nodes. Permit the explicit
base-branch-integrate hop to terminal output and require accepted integration
evidence matching implementation commit, branch, remote and final base status.

For parallel runs, the latest integration-review in the parent is the mode
authority: accepted=true, needs_revision=false and plans_remaining=false are
required. A failed or incomplete latest review must never fall back to an old
acceptance or planning-only output. Existing sequential and planning-only evidence
remain supported. Branch-level acceptance never substitutes for combined review.

## Registry contract

Single design and plan authors create a DAG of plan IDs, paths, shared-write
intent and acceptance tests. Native fanout validates dependency waves and preserves
immutable node-boundary snapshots, hashes and modes, including untracked and
deleted files. Workers use fresh contextual edits and preserve concurrent work.
Hash drift is an investigation signal, not proof of lost behavior. After all
workers stop, one writer repairs overwritten changes and a separate reviewer
checks all plan behavior, including earlier waves. Git operations are serialized.

The native tracker is cooperative evidence, not a filesystem lock or an assurance that
every concurrent overwrite is detected. Stable combined-tree acceptance tests
and semantic review remain mandatory. Existing user edits and other ongoing
Riela source work must be preserved.

## Verification

Focused Swift finalization/model tests cover accepted parallel evidence, missing
base evidence, incomplete/latest rejected review, ambiguous Git topology and all
existing exact-evidence rejection cases. Registry mock tests exercise branch
review loops, multi-plan join, planning-only, integration repair and finalization.
Temporary local filesystem fixtures exercise change evidence and DAG
validation without model calls or network pushes.

Native API and terminology: [Fanout dependency waves and change evidence](design-fanout-dependency-waves-and-change-evidence.md).
