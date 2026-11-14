# example-contract-01-chat

```json
{
  "planId": "example-contract-01-chat",
  "planPath": "impl-plans/active/example-contract-01-chat.md",
  "dependsOn": [],
  "writePaths": [
    "examples/chat-event-attachment-judgement/EXPECTED_RESULTS.md",
    "examples/chat-event-attachment-judgement/mock-scenario-unsupported.json",
    "examples/chat-event-attachment-judgement/mock-scenario.json",
    "examples/chat-event-attachment-judgement/nodes/node-judge-attachments.json",
    "examples/chat-event-attachment-judgement/prompts/judge-attachments.md",
    "examples/chat-event-attachment-judgement/workflow.json",
    "examples/chat-reply-webhook/EXPECTED_RESULTS.md",
    "examples/chat-reply-webhook/workflow.json",
    "examples/chat-supervisor-collaboration/.riela-events/bindings/chat-task-to-collaboration.json",
    "examples/chat-supervisor-collaboration/.riela-events/destinations/coordinator-chat.json",
    "examples/chat-supervisor-collaboration/.riela-events/destinations/shared-brainstorm-chat.json",
    "examples/chat-supervisor-collaboration/.riela-events/destinations/workflow-a-review-chat.json",
    "examples/chat-supervisor-collaboration/.riela-events/destinations/workflow-b-review-chat.json",
    "examples/chat-supervisor-collaboration/.riela-events/sources/collaboration-chat.json",
    "examples/chat-supervisor-collaboration/EXPECTED_RESULTS.md",
    "examples/chat-supervisor-collaboration/mock-scenario.json",
    "examples/chat-supervisor-collaboration/nodes/node-workflow-a-brainstorm.json",
    "examples/chat-supervisor-collaboration/nodes/node-workflow-b-brainstorm.json",
    "examples/chat-supervisor-collaboration/nodes/node-workflow-c-request-review.json",
    "examples/chat-supervisor-collaboration/nodes/node-workflow-c-spec-and-implementation.json",
    "examples/chat-supervisor-collaboration/nodes/node-workflow-output.json",
    "examples/chat-supervisor-collaboration/prompts/workflow-a-brainstorm.md",
    "examples/chat-supervisor-collaboration/prompts/workflow-b-brainstorm.md",
    "examples/chat-supervisor-collaboration/prompts/workflow-c-request-review.md",
    "examples/chat-supervisor-collaboration/prompts/workflow-c-spec-and-implementation.md",
    "examples/chat-supervisor-collaboration/prompts/workflow-output.md",
    "examples/chat-supervisor-collaboration/workflow.json",
    "examples/discord-agent-trio-chat/EXPECTED_RESULTS.md",
    "examples/discord-agent-trio-chat/mock-scenario.json",
    "examples/discord-agent-trio-chat/nodes/node-read-mika-memory.json",
    "examples/discord-agent-trio-chat/nodes/node-read-rina-memory.json",
    "examples/discord-agent-trio-chat/nodes/node-read-yui-memory.json",
    "examples/discord-agent-trio-chat/nodes/node-write-mika-memory.json",
    "examples/discord-agent-trio-chat/nodes/node-write-rina-memory.json",
    "examples/discord-agent-trio-chat/nodes/node-write-yui-memory.json",
    "examples/discord-agent-trio-chat/workflow.json",
    "examples/discord-codex-chat/EXPECTED_RESULTS.md",
    "examples/discord-codex-chat/mock-scenario.json",
    "examples/discord-codex-chat/nodes/node-answer-discord-message.json",
    "examples/discord-codex-chat/prompts/answer-discord-message.md",
    "examples/discord-codex-chat/workflow.json",
    "examples/discord-persona-chat/EXPECTED_RESULTS.md",
    "examples/discord-persona-chat/nodes/node-answer-persona-message.json",
    "examples/discord-persona-chat/prompts/answer-persona-message.md",
    "examples/discord-persona-chat/workflow.json",
    "examples/enterprise-matrix-agent-personas/EXPECTED_RESULTS.md",
    "examples/enterprise-matrix-agent-personas/nodes/node-compliance-counsel.json",
    "examples/enterprise-matrix-agent-personas/nodes/node-customer-success.json",
    "examples/enterprise-matrix-agent-personas/nodes/node-finance-analyst.json",
    "examples/enterprise-matrix-agent-personas/nodes/node-incident-lead.json",
    "examples/enterprise-matrix-agent-personas/nodes/node-legal-counsel.json",
    "examples/enterprise-matrix-agent-personas/nodes/node-procurement-lead.json",
    "examples/enterprise-matrix-agent-personas/nodes/node-product-engineer.json",
    "examples/enterprise-matrix-agent-personas/nodes/node-security-analyst.json",
    "examples/enterprise-matrix-agent-personas/nodes/node-support-lead.json",
    "examples/enterprise-matrix-agent-personas/prompts/enterprise-agent-reply.md",
    "examples/enterprise-matrix-agent-personas/prompts/enterprise-agent-system.md",
    "examples/enterprise-matrix-agent-personas/workflow.json",
    "examples/enterprise-matrix-customer-escalation/EXPECTED_RESULTS.md",
    "examples/enterprise-matrix-customer-escalation/README.md",
    "examples/enterprise-matrix-customer-escalation/mock-scenario.json",
    "examples/enterprise-matrix-customer-escalation/workflow.json",
    "examples/enterprise-matrix-security-incident/EXPECTED_RESULTS.md",
    "examples/enterprise-matrix-security-incident/README.md",
    "examples/enterprise-matrix-security-incident/mock-scenario.json",
    "examples/enterprise-matrix-security-incident/workflow.json",
    "examples/enterprise-matrix-vendor-onboarding/EXPECTED_RESULTS.md",
    "examples/enterprise-matrix-vendor-onboarding/README.md",
    "examples/enterprise-matrix-vendor-onboarding/mock-scenario.json",
    "examples/enterprise-matrix-vendor-onboarding/workflow.json",
    "examples/gmail-latest-mail-digest-telegram/EXPECTED_RESULTS.md",
    "examples/gmail-latest-mail-digest-telegram/nodes/node-summarize-new-mail.json",
    "examples/gmail-latest-mail-digest-telegram/prompts/summarize-new-mail.md",
    "examples/gmail-latest-mail-digest-telegram/workflow.json",
    "examples/matrix-agent-trio-chat/EXPECTED_RESULTS.md",
    "examples/matrix-agent-trio-chat/mock-scenario.json",
    "examples/matrix-agent-trio-chat/nodes/node-read-mika-memory.json",
    "examples/matrix-agent-trio-chat/nodes/node-read-rina-memory.json",
    "examples/matrix-agent-trio-chat/nodes/node-read-yui-memory.json",
    "examples/matrix-agent-trio-chat/nodes/node-write-mika-memory.json",
    "examples/matrix-agent-trio-chat/nodes/node-write-rina-memory.json",
    "examples/matrix-agent-trio-chat/nodes/node-write-yui-memory.json",
    "examples/matrix-agent-trio-chat/workflow.json",
    "examples/matrix-chat-reply/EXPECTED_RESULTS.md",
    "examples/matrix-chat-reply/README.md",
    "examples/matrix-chat-reply/local-synapse/run-local-matrix-sample.sh",
    "examples/matrix-chat-reply/workflow.json",
    "examples/routine-chat-manager/EXPECTED_RESULTS.md",
    "examples/routine-chat-manager/mock-scenario.json",
    "examples/routine-chat-manager/nodes/node-parse-instruction.json",
    "examples/routine-chat-manager/prompts/parse-instruction.md",
    "examples/routine-chat-manager/workflow.json",
    "examples/shared-agent-trio-personas/nodes/node-mika-claude.json",
    "examples/shared-agent-trio-personas/nodes/node-rina-cursor.json",
    "examples/shared-agent-trio-personas/nodes/node-yui-codex.json",
    "examples/shared-agent-trio-personas/prompts/mika-system.md",
    "examples/shared-agent-trio-personas/prompts/persona-reply.md",
    "examples/shared-agent-trio-personas/prompts/rina-system.md",
    "examples/shared-agent-trio-personas/prompts/yui-system.md",
    "examples/shared-agent-trio-personas/workflow.json",
    "examples/slack-agent-trio-chat/EXPECTED_RESULTS.md",
    "examples/slack-agent-trio-chat/mock-scenario.json",
    "examples/slack-agent-trio-chat/nodes/node-read-mika-memory.json",
    "examples/slack-agent-trio-chat/nodes/node-read-rina-memory.json",
    "examples/slack-agent-trio-chat/nodes/node-read-yui-memory.json",
    "examples/slack-agent-trio-chat/nodes/node-write-mika-memory.json",
    "examples/slack-agent-trio-chat/nodes/node-write-rina-memory.json",
    "examples/slack-agent-trio-chat/nodes/node-write-yui-memory.json",
    "examples/slack-agent-trio-chat/workflow.json",
    "examples/slack-codex-chat/EXPECTED_RESULTS.md",
    "examples/slack-codex-chat/mock-scenario.json",
    "examples/slack-codex-chat/nodes/node-answer-slack-message.json",
    "examples/slack-codex-chat/prompts/answer-slack-message.md",
    "examples/slack-codex-chat/workflow.json",
    "examples/telegram-agent-trio-chat/EXPECTED_RESULTS.md",
    "examples/telegram-agent-trio-chat/mock-scenario.json",
    "examples/telegram-agent-trio-chat/nodes/node-read-mika-memory.json",
    "examples/telegram-agent-trio-chat/nodes/node-read-rina-memory.json",
    "examples/telegram-agent-trio-chat/nodes/node-read-yui-memory.json",
    "examples/telegram-agent-trio-chat/nodes/node-write-mika-memory.json",
    "examples/telegram-agent-trio-chat/nodes/node-write-rina-memory.json",
    "examples/telegram-agent-trio-chat/nodes/node-write-yui-memory.json",
    "examples/telegram-agent-trio-chat/workflow.json",
    "examples/telegram-agent-trio-time-signal/EXPECTED_RESULTS.md",
    "examples/telegram-agent-trio-time-signal/workflow.json",
    "examples/telegram-sdk-trio-chat/EXPECTED_RESULTS.md",
    "examples/telegram-sdk-trio-chat/mock-scenario.json",
    "examples/telegram-sdk-trio-chat/workflow.json",
    "impl-plans/progress/example-contract-01-chat.md"
  ],
  "sharedPaths": [],
  "progressLog": "impl-plans/progress/example-contract-01-chat.md",
  "status": "planned; Step 5 review pending",
  "workflowCount": 20
}
```

## Intent, authority, and invariants

Mode: `issue-resolution`. Issue reference: null. Codex-agent references: [].
Accepted source: `design-docs/specs/design-agent-node-output-contract.md` §12,
Step 3 `comm-000004`, accepted with no findings. Review all 75 examples for
installed Riela 0.2.1 while preserving each example's teaching behavior.
Use branch `fix/example-contract-migration` and the current shared checkout.
No registry discovery, riela-packages edits, engine redesign, model migration,
new frameworks, unrelated cleanup, live model/provider calls, worktrees, private
branches, or concurrent Git operations. Do not change workflow IDs or remove
examples to achieve a passing count. No Codex-reference or Cursor adapter work.

Native Riela dispatch starts only after independent plan acceptance and the
accepted design plus ALL plans are committed and non-force pushed on this branch
by the serial workflow checkpoint owner. Workers never stage, commit, or push.
A failed checkpoint stops dispatch. Do not launch a second orchestration workflow.

Before every edit, reread the current file and applicable guidance. Record its
SHA-256 (ABSENT for a new file), a preimage, and a write-once intent snapshot
with requirement and proposed change under
`tmp/example-contract-migration/<planId>/<attempt>/`. Recheck the hash immediately
before writing; on drift, reread and reconcile instead of applying stale content.
Record posthash and patch. At join the serial owner compares all posthashes and
intent snapshots with the current tree, transfers ownership explicitly, repairs
lost changes from fresh contents, and reruns affected checks. Never reset others'
work. Workers edit only their own progress log. Shared indexes, lockfiles, broad
formatting, and global archiving are reserved for serial finalization; none is
needed merely for this migration. No dependency upgrades or fetching packages.

Progress logs must record task status, reviewed and changed paths, rationale,
pre/post hashes, immutable snapshot paths, command argv/cwd, CLI version, full
stdout/stderr log paths, final exit codes, assertion counts/results, findings,
blocked prerequisites, and remaining tasks. Record unchanged bundles too.
Logs must distinguish implementation completion from later review/finalization.
Initialize the named progress log at implementation start, not as a claim of work
already performed. Retain scratch evidence through review; preserve durable
summaries before cleanup. Never commit scratch evidence.

All commands run in the foreground. Poll yielded sessions through exit. No `&`,
nohup, disown, setsid, or detached processes, including inside verification
scripts. A service-based script must use an explicitly owned Riela lifecycle or
remain blocked with the exact operation recorded. Do not invoke an unsafe script
just because it is named verify. Mock mode is not proof of side-effect isolation.
Incomplete logs, zero selected tests, and blocked commands are not passes.

## Tasks and precise intended changes

- [ ] Inventory: create one evidence row per assigned workflow; read workflow.json,
  inline nodes, every referenced node/prompt, all scenario variants and docs.
  Resolve called-workflow and shared-persona edges; cross-owner producers are
  read-only dependencies until join. Record required shared edits for plan 03.
- [ ] Sandbox: edit only affected workflow.json or nodes/*.json fields after
  reading the actual role. Use read-only for nonwriting work and workspace-write
  for required authoring/test writes. Do not add sandbox to SDK-only backends;
  document any necessary retained elevated permission rather than widening it.
- [ ] Payloads: trace producer -> forwarding add-ons -> consumer templates and
  branch decisions. Add output.jsonSchema only where needed, with real required
  fields, nested types and applicable enums. Keep routing envelope separate.
  Preserve valid terminal description-only outputs. Align the corresponding
  prompts and mock payloads in the same edit batch; never use vacuous schemas.
- [ ] Portability: repair only evidenced missing/wrong shipped paths, arguments,
  fixture contracts, or prerequisite docs. Classify unresolvedAddonExecutable
  by examining actual executable references before calling it environmental.
  Preserve SDK/provider responsibilities. For an engine defect, retain a minimal
  reproduction and upstream-report handoff before any separately scoped fix.
- [ ] Verification: inspect every scenario's executable/add-on paths for live
  calls before execution. Run every mock-scenario.json and changed decision's
  alternate scenarios; compare stable step order, branch outcomes, payloads,
  terminal states and intentional failures with EXPECTED_RESULTS.md. Update only
  inaccurate README/EXPECTED_RESULTS statements. Do not snapshot run IDs/times.
- [ ] Handoff: every bundle row includes reviewed files, defect or unchanged
  rationale, repair paths, sandbox/schema rationale, exact expanded commands,
  final status, full logs and prerequisite classification. Hand off cross-owner
  edge contracts and posthashes; do not claim independent review already passed.

## Verification commands and evidence

From repository root, first run `riela --version` (must identify 0.2.1).
For each listed workflow read its authored workflowId and its documented definition root; for this inventory the
bundles are direct children of examples, so use `--workflow-definition-dir examples`.
Record the resulting literal command for each row, never just this template:

```sh
riela workflow validate "$example_id" --workflow-definition-dir examples --output json
riela workflow inspect "$example_id" --workflow-definition-dir examples --output json
riela workflow run "$example_id" --workflow-definition-dir examples --mock-scenario "$scenario_path" --variables-file "$fixture_variables" --session-store "$attempt_dir/sessions" --artifact-root "$attempt_dir/artifacts" --output json
 git diff --check
```

Here example_id comes from that bundle, scenario_path is the exact reviewed
scenario, attempt_dir is unique under this plan's tmp directory, and
fixture_variables is a JSON file there containing the example's documented
fixture inputs ({} if none). Never invent live credentials. Retain stdout/stderr
and final exit codes separately for each invocation. A rejection scenario may
have an expected failure exit only when its asserted diagnostic and step match.
Use distinct attempt directories for each run; rerun changed mock behavior once
and compare stable assertions to establish determinism. Validation and inspection
must both be attempted for every assigned bundle, even if validation fails.
Do not use these commands to rediscover the orchestration workflow.

Do not run shared Swift builds/tests concurrently; plan 03 owns them. When local
TypeScript is changed, use the package's existing typecheck command with already
installed tooling; report missing dependencies, do not install from the network.

## Completion criteria

All assigned bundles have reviewed rows and both CLI check outcomes. Every safe
mock scenario has terminal evidence and matching documentation; blocked scenarios
name the missing prerequisite/unmocked operation, never a fabricated pass.
No unresolved authoring defect or high/mid finding. All repairs remain within the
explicit manifest below; new needed fixture/doc files require a bounded ownership
entry in this progress log before editing. Worker completion hands off behavioral
evidence and residual environment limits; downstream formal review, documentation
refresh, commit and push belong to later workflow steps.

## Exact existing file manifest

These are permitted review/repair candidates, not a requirement to change every
file. workflow.json defines graph/backend fields; node JSON defines sandbox and
output schemas; prompts define business output instructions; mock/fixture JSON
defines deterministic inputs/outputs; scripts/TypeScript receive only evidenced
portability/fixture corrections; README/EXPECTED_RESULTS document verified use.
Lockfiles are excluded. Referenced files outside this manifest remain read-only
and are handed to the serial owner if a concrete correction is needed.

- `examples/chat-event-attachment-judgement/EXPECTED_RESULTS.md`
- `examples/chat-event-attachment-judgement/mock-scenario-unsupported.json`
- `examples/chat-event-attachment-judgement/mock-scenario.json`
- `examples/chat-event-attachment-judgement/nodes/node-judge-attachments.json`
- `examples/chat-event-attachment-judgement/prompts/judge-attachments.md`
- `examples/chat-event-attachment-judgement/workflow.json`
- `examples/chat-reply-webhook/EXPECTED_RESULTS.md`
- `examples/chat-reply-webhook/workflow.json`
- `examples/chat-supervisor-collaboration/.riela-events/bindings/chat-task-to-collaboration.json`
- `examples/chat-supervisor-collaboration/.riela-events/destinations/coordinator-chat.json`
- `examples/chat-supervisor-collaboration/.riela-events/destinations/shared-brainstorm-chat.json`
- `examples/chat-supervisor-collaboration/.riela-events/destinations/workflow-a-review-chat.json`
- `examples/chat-supervisor-collaboration/.riela-events/destinations/workflow-b-review-chat.json`
- `examples/chat-supervisor-collaboration/.riela-events/sources/collaboration-chat.json`
- `examples/chat-supervisor-collaboration/EXPECTED_RESULTS.md`
- `examples/chat-supervisor-collaboration/mock-scenario.json`
- `examples/chat-supervisor-collaboration/nodes/node-workflow-a-brainstorm.json`
- `examples/chat-supervisor-collaboration/nodes/node-workflow-b-brainstorm.json`
- `examples/chat-supervisor-collaboration/nodes/node-workflow-c-request-review.json`
- `examples/chat-supervisor-collaboration/nodes/node-workflow-c-spec-and-implementation.json`
- `examples/chat-supervisor-collaboration/nodes/node-workflow-output.json`
- `examples/chat-supervisor-collaboration/prompts/workflow-a-brainstorm.md`
- `examples/chat-supervisor-collaboration/prompts/workflow-b-brainstorm.md`
- `examples/chat-supervisor-collaboration/prompts/workflow-c-request-review.md`
- `examples/chat-supervisor-collaboration/prompts/workflow-c-spec-and-implementation.md`
- `examples/chat-supervisor-collaboration/prompts/workflow-output.md`
- `examples/chat-supervisor-collaboration/workflow.json`
- `examples/discord-agent-trio-chat/EXPECTED_RESULTS.md`
- `examples/discord-agent-trio-chat/mock-scenario.json`
- `examples/discord-agent-trio-chat/nodes/node-read-mika-memory.json`
- `examples/discord-agent-trio-chat/nodes/node-read-rina-memory.json`
- `examples/discord-agent-trio-chat/nodes/node-read-yui-memory.json`
- `examples/discord-agent-trio-chat/nodes/node-write-mika-memory.json`
- `examples/discord-agent-trio-chat/nodes/node-write-rina-memory.json`
- `examples/discord-agent-trio-chat/nodes/node-write-yui-memory.json`
- `examples/discord-agent-trio-chat/workflow.json`
- `examples/discord-codex-chat/EXPECTED_RESULTS.md`
- `examples/discord-codex-chat/mock-scenario.json`
- `examples/discord-codex-chat/nodes/node-answer-discord-message.json`
- `examples/discord-codex-chat/prompts/answer-discord-message.md`
- `examples/discord-codex-chat/workflow.json`
- `examples/discord-persona-chat/EXPECTED_RESULTS.md`
- `examples/discord-persona-chat/nodes/node-answer-persona-message.json`
- `examples/discord-persona-chat/prompts/answer-persona-message.md`
- `examples/discord-persona-chat/workflow.json`
- `examples/enterprise-matrix-agent-personas/EXPECTED_RESULTS.md`
- `examples/enterprise-matrix-agent-personas/nodes/node-compliance-counsel.json`
- `examples/enterprise-matrix-agent-personas/nodes/node-customer-success.json`
- `examples/enterprise-matrix-agent-personas/nodes/node-finance-analyst.json`
- `examples/enterprise-matrix-agent-personas/nodes/node-incident-lead.json`
- `examples/enterprise-matrix-agent-personas/nodes/node-legal-counsel.json`
- `examples/enterprise-matrix-agent-personas/nodes/node-procurement-lead.json`
- `examples/enterprise-matrix-agent-personas/nodes/node-product-engineer.json`
- `examples/enterprise-matrix-agent-personas/nodes/node-security-analyst.json`
- `examples/enterprise-matrix-agent-personas/nodes/node-support-lead.json`
- `examples/enterprise-matrix-agent-personas/prompts/enterprise-agent-reply.md`
- `examples/enterprise-matrix-agent-personas/prompts/enterprise-agent-system.md`
- `examples/enterprise-matrix-agent-personas/workflow.json`
- `examples/enterprise-matrix-customer-escalation/EXPECTED_RESULTS.md`
- `examples/enterprise-matrix-customer-escalation/README.md`
- `examples/enterprise-matrix-customer-escalation/mock-scenario.json`
- `examples/enterprise-matrix-customer-escalation/workflow.json`
- `examples/enterprise-matrix-security-incident/EXPECTED_RESULTS.md`
- `examples/enterprise-matrix-security-incident/README.md`
- `examples/enterprise-matrix-security-incident/mock-scenario.json`
- `examples/enterprise-matrix-security-incident/workflow.json`
- `examples/enterprise-matrix-vendor-onboarding/EXPECTED_RESULTS.md`
- `examples/enterprise-matrix-vendor-onboarding/README.md`
- `examples/enterprise-matrix-vendor-onboarding/mock-scenario.json`
- `examples/enterprise-matrix-vendor-onboarding/workflow.json`
- `examples/gmail-latest-mail-digest-telegram/EXPECTED_RESULTS.md`
- `examples/gmail-latest-mail-digest-telegram/nodes/node-summarize-new-mail.json`
- `examples/gmail-latest-mail-digest-telegram/prompts/summarize-new-mail.md`
- `examples/gmail-latest-mail-digest-telegram/workflow.json`
- `examples/matrix-agent-trio-chat/EXPECTED_RESULTS.md`
- `examples/matrix-agent-trio-chat/mock-scenario.json`
- `examples/matrix-agent-trio-chat/nodes/node-read-mika-memory.json`
- `examples/matrix-agent-trio-chat/nodes/node-read-rina-memory.json`
- `examples/matrix-agent-trio-chat/nodes/node-read-yui-memory.json`
- `examples/matrix-agent-trio-chat/nodes/node-write-mika-memory.json`
- `examples/matrix-agent-trio-chat/nodes/node-write-rina-memory.json`
- `examples/matrix-agent-trio-chat/nodes/node-write-yui-memory.json`
- `examples/matrix-agent-trio-chat/workflow.json`
- `examples/matrix-chat-reply/EXPECTED_RESULTS.md`
- `examples/matrix-chat-reply/README.md`
- `examples/matrix-chat-reply/local-synapse/run-local-matrix-sample.sh`
- `examples/matrix-chat-reply/workflow.json`
- `examples/routine-chat-manager/EXPECTED_RESULTS.md`
- `examples/routine-chat-manager/mock-scenario.json`
- `examples/routine-chat-manager/nodes/node-parse-instruction.json`
- `examples/routine-chat-manager/prompts/parse-instruction.md`
- `examples/routine-chat-manager/workflow.json`
- `examples/shared-agent-trio-personas/nodes/node-mika-claude.json`
- `examples/shared-agent-trio-personas/nodes/node-rina-cursor.json`
- `examples/shared-agent-trio-personas/nodes/node-yui-codex.json`
- `examples/shared-agent-trio-personas/prompts/mika-system.md`
- `examples/shared-agent-trio-personas/prompts/persona-reply.md`
- `examples/shared-agent-trio-personas/prompts/rina-system.md`
- `examples/shared-agent-trio-personas/prompts/yui-system.md`
- `examples/shared-agent-trio-personas/workflow.json`
- `examples/slack-agent-trio-chat/EXPECTED_RESULTS.md`
- `examples/slack-agent-trio-chat/mock-scenario.json`
- `examples/slack-agent-trio-chat/nodes/node-read-mika-memory.json`
- `examples/slack-agent-trio-chat/nodes/node-read-rina-memory.json`
- `examples/slack-agent-trio-chat/nodes/node-read-yui-memory.json`
- `examples/slack-agent-trio-chat/nodes/node-write-mika-memory.json`
- `examples/slack-agent-trio-chat/nodes/node-write-rina-memory.json`
- `examples/slack-agent-trio-chat/nodes/node-write-yui-memory.json`
- `examples/slack-agent-trio-chat/workflow.json`
- `examples/slack-codex-chat/EXPECTED_RESULTS.md`
- `examples/slack-codex-chat/mock-scenario.json`
- `examples/slack-codex-chat/nodes/node-answer-slack-message.json`
- `examples/slack-codex-chat/prompts/answer-slack-message.md`
- `examples/slack-codex-chat/workflow.json`
- `examples/telegram-agent-trio-chat/EXPECTED_RESULTS.md`
- `examples/telegram-agent-trio-chat/mock-scenario.json`
- `examples/telegram-agent-trio-chat/nodes/node-read-mika-memory.json`
- `examples/telegram-agent-trio-chat/nodes/node-read-rina-memory.json`
- `examples/telegram-agent-trio-chat/nodes/node-read-yui-memory.json`
- `examples/telegram-agent-trio-chat/nodes/node-write-mika-memory.json`
- `examples/telegram-agent-trio-chat/nodes/node-write-rina-memory.json`
- `examples/telegram-agent-trio-chat/nodes/node-write-yui-memory.json`
- `examples/telegram-agent-trio-chat/workflow.json`
- `examples/telegram-agent-trio-time-signal/EXPECTED_RESULTS.md`
- `examples/telegram-agent-trio-time-signal/workflow.json`
- `examples/telegram-sdk-trio-chat/EXPECTED_RESULTS.md`
- `examples/telegram-sdk-trio-chat/mock-scenario.json`
- `examples/telegram-sdk-trio-chat/workflow.json`
