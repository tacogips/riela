# wh-19: Operator docs and in-repo skills

```json
{
  "planId": "wh-19-docs-skills",
  "planPath": "impl-plans/active/wh-19-docs-skills.md",
  "wave": "W5",
  "dependsOn": [
    "wh-15-task-commands",
    "wh-16-graphql-provider"
  ],
  "writePaths": [
    "docs/work-handover.md",
    "docs/distributed-workers.md",
    "docs/preserved-history-recovery.md",
    "Resources/skills/riela-workflow-run/SKILL.md",
    "Resources/skills/riela-workflow-reference/SKILL.md",
    "impl-plans/progress/wh-19-docs-skills.md"
  ],
  "sharedPaths": [],
  "progressLog": "impl-plans/progress/wh-19-docs-skills.md"
}
```

## Intent and context

Document the shipped surfaces for operators and agents (design §12 "Skills", §21 R13: only the two in-repo skills
are updated here; `riela-workflow`, `riela-troubleshooting`, `riela-manager-control` and `riela-node-addons` live in the
riela-packages repository, so record them in the progress log as a follow-up). Flags and fields must match the code in wh-15 and wh-16
and the flags pinned in wh-18 (wh-18 runs in parallel; wh-20 re-checks that the docs match the final `--help`).

Non-goals: README index and catalog rows (wh-20), example READMEs (wh-17), and external repositories.

## Execution rules

Follow the umbrella common execution contract (hashes and intents in `tmp/work-handover/wh-19-docs-skills/`,
writePaths only, no git state changes, own progress log). Markdown only.

## Deliverables

- `docs/work-handover.md` (new operator guide). Cover: when a handover happens (S1–S4, triggers); the `handover`
  envelope with a JSON example and `riela/handover-request@1` config (`resumeStepId` required); what the packet contains and
  its bounds; statuses (`suspended`, `failed(.stalled|.cancelled|.leaseLost)`); the recipes "answer on the server, the server
  continues" (`task answer` + `task takeover`/`task run`), "take over on the laptop" (`task takeover --endpoint … --traits
  userReachable [--clone-into]`, `task serve --takeover`), orphan recovery (`task takeover --force-orphan`, `task reconcile
  --expired-leases`), plain sessions (`session resume` with an answer, `session handover [--task]`; adoption never
  switches, commits or pushes the user's checkout: the repository deliverable is `unpublished` at `HEAD` with the dirty paths
  listed, and uncommitted work stays in the checkout — design §10.5, §21 R29, user-qa Q10); sinks and locators (`kind:locator#sha256:…`,
  `--packet`); host traits (profile `hostTraits`, `worker.json traits`, `--traits`); lease defaults (300 s / 15 s, `guard.lease`);
  branch policy (`riela/task/<taskId>/g<n>`, never force, checkpoints with the `Riela-Checkpoint` trailer); `riela gc`; handover
  notifications (`loop.notifications.on: ["handover"]`); security notes (redaction, sinks publish outward, token handling).
- `docs/distributed-workers.md`: the `traits` field in `worker.json`, and that workers may run `riela/git-publish-branch` while `git-commit` and `git-push`
  stay denied.
- `docs/preserved-history-recovery.md`: import also accepts suspended and failed(stalled/cancelled/leaseLost) sources, and packet
  bundles (`importedFrom.handoverId`). A truncated bundle is refused.
- `Resources/skills/riela-workflow-run/SKILL.md`: short recipes for every new `task` and `session` command and the new exit code 5.
- `Resources/skills/riela-workflow-reference/SKILL.md`: the seven GraphQL fields with argument shapes, the auth requirement and
  the heartbeat/report protocol.

## Verification

```
grep -c -E "task (handover|takeover|answer|handovers|reconcile|serve)|session handover" Resources/skills/riela-workflow-run/SKILL.md
grep -c -E "taskHandover|tasksAwaitingHandover|requestTaskHandover|answerTask|takeoverTask|heartbeatAttempt|reportAttempt" Resources/skills/riela-workflow-reference/SKILL.md
git diff --check
```

The first count must be ≥ 7 and the second ≥ 7 (each surface mentioned). Record the outputs. `SurfaceParitySkillTests` runs in wh-20.

## Done criteria

- [ ] The three docs and two skills are updated; the external-skills follow-up is recorded; the progress log is complete
