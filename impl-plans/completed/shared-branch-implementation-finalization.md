# Shared-branch implementation finalization

**Status**: Completed
**Design Reference**: design-docs/specs/design-shared-branch-implementation-finalization.md
**Created**: 2026-09-06

## Scope and ownership

Extend native fanout with dependency waves and shared-workspace change evidence,
and adapt protected finalization evidence to the registry's new graph.
Source ownership covers the fanout model, validation, scheduling, tracking,
runner dispatch/context propagation and protected Git finalization evidence.
CLI ownership is limited to binding the workspace root in run/resume/rerun.
Preserve concurrent specialist, SQLite, package configuration and other CLI edits.

## Tasks

- [x] Reproduce the registry's checkpoint/fanout topology rejection.
- [x] Support the explicit planning checkpoint and base integration topology
  without weakening exact final commit/push matching.
- [x] Use latest combined review evidence for parent-session implementation mode.
- [x] Add missing/stale/incomplete integration evidence regression coverage.
- [x] Implement native dependency waves and immutable node-boundary evidence.
- [x] Preserve fanout context through called workflows and parent/root session lineage.
- [x] Run focused Swift finalization, model, fanout and change-evidence tests (48 passed).
- [x] Run registry branch, dependency-wave, repair and planning-only mock regressions
  with the rebuilt CLI (11 passed), Python plan-tool tests (3 passed), and all
  64 package checks. Regenerate registry metadata and distribution archives.

## Progress

2026-09-06: implemented native map/reduce extensions, evidence-policy changes and
paired registry graphs. Verification used an isolated Git archive copy with only
these changes and the pre-existing Kaiba dependency-pin correction: concurrent
specialist edits prevented a reliable build of the shared source tree. No
worktree was created. Mock tests do not exercise live model calls, remote Git
pushes or Fable knowledge-base clients. Node-boundary evidence cannot capture
every transient overwrite; combined semantic review remains mandatory.

No GitHub issue was sent: the user authorized local registry/engine fixes,
and this session does not authorize sending messages to others. Reproduction
and the proposed resolution are preserved in the linked design document.
