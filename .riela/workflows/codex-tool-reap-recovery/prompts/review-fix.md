# Task

Independently adversarially review the current uncommitted implementation of terminal Codex tool-child stall recovery against the complete design and implementation plan, then fix every high- or medium-severity finding you discover.

Read `.codex/skills/swift-coding-agent/SKILL.md` completely. Preserve unrelated dirty changes. Scratch/logs belong only under `tmp/codex-tool-reap-recovery/`. Do not commit or push.

Inspect sibling `../riela-packages` as part of parity review. If the implementation changed a contract duplicated by packaged skills or workflows, require synchronized package updates, applicable nested `AGENTS.md` compliance, refreshed package digests, and registry validation. Do not create unrelated registry churn.

Review `impl-plans/REMAINING-WORK-HANDOVER.md` independently for completeness and MECE structure. Re-run the active-plan/unchecked-item/status/git-diff orphan inventory across both repositories, ensure every item has one primary workstream, remove or cross-reference duplicates, verify dependency ordering has no cycles, and correct stale file/session/test evidence. Treat a missing active plan, an orphan checklist item, or duplicated primary ownership as at least medium severity.

Attack these boundaries explicitly:

- Riela attempting to reap a non-child, PID reuse, process-group reuse, parent replacement, TOCTOU between observation and signal, and unsupported-platform behavior
- open tool-call matching, duplicate/reordered lifecycle events, unrelated wait/status heartbeats, stream truncation, resume, cancellation, and concurrent polling
- direct child exiting before/after descendant observation; TERM/KILL escalation; pipe EOF; output drain; exactly-once `waitpid`; leaked monitor tasks
- same-attempt continuation without a trustworthy terminal result; repeated command/mutation; auto-improve retry budget bypass; non-idempotent incident/remediation persistence
- secrets in command fingerprints, diagnostics, status, GraphQL, logs, and serialized state
- backward decoding, CLI/library/GraphQL parity, local/remote execution parity, and policy defaults
- whether the integration fixture proves the real post-summary hang shape instead of only simulating generic silence
- stale model identifiers or stale stall/auto-improve guidance in either repository

Add missing adversarial tests before or with each fix. Do not waive a high/medium finding. Run focused tests, strict scoped SwiftLint, file-size checks, and `git diff --check`. Return concise JSON with findings found, fixes applied, and evidence.
