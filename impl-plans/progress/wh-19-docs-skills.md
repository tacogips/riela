# wh-19 docs and skills progress

- Plan: `impl-plans/active/wh-19-docs-skills.md`
- Design: `design-docs/specs/design-work-handover-and-takeover.md` §§3, 6–12, §21 R13/R29/R34
- Workflow mode: `issue-resolution`
- Branch: `feat/work-handover-and-takeover`
- Issue reference: no GitHub issue was supplied; work is tracked by the design and `impl-plans/active/work-handover-and-takeover.md`.
- Dependency: `wh-18-remote-takeover` is present in the fanout item's accepted plan IDs. Its answered-S1 contract includes `TakeoverTaskPayload.answer`; wh-20 owns generated SDL/catalog registration.
- Codex-agent references: Step 6 implementation route repairing adversarial communication `comm-000332` (wh-18 R28); Step 7 adversarial review `comm-000336` (`step7-adversarial-review-attempt-1-exec-353`) accepted wh-18 with no findings.

## Changes

- Added `docs/work-handover.md`: S1-S4 and orphan behavior, the envelope and `riela/handover-request@1`, packet bounds and digest-bearing sink locators, status and exit-code meanings, answer/server, remote laptop, orphan, plain-session and adoption recipes, host traits, lease defaults, checkpoint branch rules, GC, notifications and security guidance.
- Updated `docs/distributed-workers.md`: documented declared `worker.json` traits and the worker rule allowing `riela/git-publish-branch` when explicitly allowed while continuing to deny `riela/git-commit` and `riela/git-push`.
- Updated `docs/preserved-history-recovery.md`: documented imports from suspended and failed(stalled/cancelled/leaseLost) sessions, packet-bundle lineage through `importedFrom.handoverId`, and refusal of truncated bundles.
- Updated `Resources/skills/riela-workflow-run/SKILL.md`: added recipes and key flags for task handover, takeover, answer, handovers, reconcile, serve, and session handover; documented suspended exit code 5 and adoption behavior.
- Updated `Resources/skills/riela-workflow-reference/SKILL.md`: documented all seven GraphQL query/mutation fields, arguments and inputs, returned answered-S1 data, manager bearer authorization, optional manager-session header, and heartbeat/report credential flow.
- Recorded per-file fresh prehash/preimage and write intent under `tmp/work-handover/wh-19-docs-skills/attempt-1/`. Source edits were not made. Existing wh-18 source and progress changes in the shared worktree were preserved.

## Completion criteria

- [x] Three docs and two in-repo skills updated for commands, flags, exit code 5 and GraphQL fields; the two required grep counts exceed 7.
- [x] R13 external-skills follow-up recorded: `riela-workflow`, `riela-troubleshooting`, `riela-manager-control`, and `riela-node-addons` live in the separate `riela-packages` repository and are outside this plan's write paths.
- [x] Plan-local progress and evidence paths recorded.

## Verification

| Command | Result | Evidence |
| --- | --- | --- |
| `grep -c -E "task (handover|takeover|answer|handovers|reconcile|serve)|session handover" Resources/skills/riela-workflow-run/SKILL.md` | 17 matches (required ≥ 7), exit 0 | `tmp/work-handover/wh-19-docs-skills/run-skill-grep-final.log` |
| `grep -c -E "taskHandover|tasksAwaitingHandover|requestTaskHandover|answerTask|takeoverTask|heartbeatAttempt|reportAttempt" Resources/skills/riela-workflow-reference/SKILL.md` | 10 matches (required ≥ 7), exit 0 | `tmp/work-handover/wh-19-docs-skills/reference-skill-grep-final.log` |
| `git diff --check` | exit 0 | `tmp/work-handover/wh-19-docs-skills/diff-check-final.log` |
| Python trailing-whitespace scan of the new guide and progress log | none, exit 0 | `tmp/work-handover/wh-19-docs-skills/untracked-whitespace-final.log` |

## Remaining ownership and risks

- Formal integrity, adversarial and serial integration reviews are downstream workflow steps; none is claimed complete here.
- wh-20 rechecks command help and registers catalog/SDL surfaces, then owns final combined-tree verification. This plan did not edit generated SDL/catalog files.
- External R13 skills require a separate `riela-packages` follow-up.
- No material implementation risks or verification gaps were found within this Markdown-only plan.
