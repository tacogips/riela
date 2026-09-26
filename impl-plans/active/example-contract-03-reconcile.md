# Example migration: serial reconciliation and verification

```json
{
  "planId": "example-contract-03-reconcile",
  "planPath": "impl-plans/active/example-contract-03-reconcile.md",
  "dependsOn": [
    "example-contract-01-chat",
    "example-contract-02-core-sdk"
  ],
  "writePaths": [
    "examples/README.md",
    "examples/catalog/showcase-and-utility-examples.md",
    "examples/catalog/digest-gateway-and-reply.md",
    "examples/catalog/workflow-composition-and-coding.md",
    "examples/catalog/chat-persona-and-agent-trio.md",
    "examples/event-sources/README.md",
    "examples/event-sources/payloads/chat-message.json",
    "examples/event-sources/payloads/chat-sdk-discord-message.json",
    "examples/event-sources/payloads/gmail-latest-mail-hourly-cron.json",
    "examples/event-sources/payloads/file-change-created.json",
    "examples/event-sources/payloads/chat-sdk-telegram-message.json",
    "examples/event-sources/payloads/enterprise-matrix-security-message.json",
    "examples/event-sources/payloads/telegram-gateway-photo-message.json",
    "examples/event-sources/payloads/chat-supervisor-dispatch-start-managed.json",
    "examples/event-sources/payloads/s3-object-created.json",
    "examples/event-sources/payloads/telegram-time-signal-cron.json",
    "examples/event-sources/payloads/chat-sdk-attachment-judgement-unsupported.json",
    "examples/event-sources/payloads/chat-sdk-attachment-judgement-message.json",
    "examples/event-sources/payloads/enterprise-matrix-customer-message.json",
    "examples/event-sources/payloads/slack-gateway-persona-message-with-history.json",
    "examples/event-sources/payloads/matrix-room-message.json",
    "examples/event-sources/payloads/chat-sdk-slack-message.json",
    "examples/event-sources/payloads/telegram-gateway-message.json",
    "examples/event-sources/payloads/discord-gateway-message-with-history.json",
    "examples/event-sources/payloads/chat-reply-message.json",
    "examples/event-sources/payloads/slack-gateway-message-with-history.json",
    "examples/event-sources/payloads/matrix-persona-message.json",
    "examples/event-sources/payloads/chat-supervised-start.json",
    "examples/event-sources/payloads/chat-supervisor-dispatch.json",
    "examples/event-sources/payloads/x-follower-ai-business-hourly-cron.json",
    "examples/event-sources/payloads/enterprise-matrix-vendor-message.json",
    "examples/event-sources/watched-docs/.gitkeep",
    "examples/event-sources/.riela-events/destinations/slack-gateway-persona-replies.json",
    "examples/event-sources/.riela-events/destinations/enterprise-matrix-vendor-replies.json",
    "examples/event-sources/.riela-events/destinations/matrix-persona-replies.json",
    "examples/event-sources/.riela-events/destinations/slack-gateway-codex-replies.json",
    "examples/event-sources/.riela-events/destinations/release-matrix-chat.json",
    "examples/event-sources/.riela-events/destinations/enterprise-matrix-customer-replies.json",
    "examples/event-sources/.riela-events/destinations/chat-sdk-slack-replies.json",
    "examples/event-sources/.riela-events/destinations/chat-sdk-discord-replies.json",
    "examples/event-sources/.riela-events/destinations/enterprise-matrix-security-replies.json",
    "examples/event-sources/.riela-events/destinations/telegram-gateway-persona-replies.json",
    "examples/event-sources/.riela-events/destinations/example-reply-chat.json",
    "examples/event-sources/.riela-events/destinations/chat-sdk-telegram-replies.json",
    "examples/event-sources/.riela-events/destinations/discord-gateway-persona-replies.json",
    "examples/event-sources/.riela-events/supervisors/default-chat-dispatcher.json",
    "examples/event-sources/.riela-events/sources/gmail-latest-mail-hourly-cron.json",
    "examples/event-sources/.riela-events/sources/discord-gateway-personas.json",
    "examples/event-sources/.riela-events/sources/team-matrix.json",
    "examples/event-sources/.riela-events/sources/example-webhook.json",
    "examples/event-sources/.riela-events/sources/enterprise-matrix.json",
    "examples/event-sources/.riela-events/sources/incoming-docs.json",
    "examples/event-sources/.riela-events/sources/telegram-gateway-personas.json",
    "examples/event-sources/.riela-events/sources/chat-sdk-telegram.json",
    "examples/event-sources/.riela-events/sources/telegram-time-signal-cron.json",
    "examples/event-sources/.riela-events/sources/sequential-list.json",
    "examples/event-sources/.riela-events/sources/chat-sdk-slack.json",
    "examples/event-sources/.riela-events/sources/local-docs.json",
    "examples/event-sources/.riela-events/sources/example-reply-webhook.json",
    "examples/event-sources/.riela-events/sources/chat-sdk-discord.json",
    "examples/event-sources/.riela-events/sources/x-follower-ai-business-hourly-cron.json",
    "examples/event-sources/.riela-events/sources/nightly-cron.json",
    "examples/event-sources/.riela-events/sources/slack-gateway-personas.json",
    "examples/event-sources/.riela-events/sources/slack-gateway-codex.json",
    "examples/event-sources/.riela-events/bindings/sequential-list-to-arithmetic.json",
    "examples/event-sources/.riela-events/bindings/webhook-supervised-arithmetic.json",
    "examples/event-sources/.riela-events/bindings/slack-gateway-personas-to-workflow.json",
    "examples/event-sources/.riela-events/bindings/x-follower-ai-business-hourly-to-workflow.json",
    "examples/event-sources/.riela-events/bindings/discord-gateway-personas-to-workflow.json",
    "examples/event-sources/.riela-events/bindings/chat-sdk-discord-to-workflow.json",
    "examples/event-sources/.riela-events/bindings/slack-gateway-codex-to-workflow.json",
    "examples/event-sources/.riela-events/bindings/telegram-time-signal-cron-to-workflow.json",
    "examples/event-sources/.riela-events/bindings/s3-doc-to-arithmetic.json",
    "examples/event-sources/.riela-events/bindings/cron-to-arithmetic.json",
    "examples/event-sources/.riela-events/bindings/chat-sdk-slack-schedule-registration.json",
    "examples/event-sources/.riela-events/bindings/chat-sdk-discord-to-agent-trio.json",
    "examples/event-sources/.riela-events/bindings/enterprise-matrix-security-to-workflow.json",
    "examples/event-sources/.riela-events/bindings/enterprise-matrix-vendor-to-workflow.json",
    "examples/event-sources/.riela-events/bindings/chat-sdk-telegram-to-workflow.json",
    "examples/event-sources/.riela-events/bindings/webhook-supervisor-dispatch-demo.json",
    "examples/event-sources/.riela-events/bindings/chat-sdk-slack-to-workflow.json",
    "examples/event-sources/.riela-events/bindings/matrix-agent-trio-to-workflow.json",
    "examples/event-sources/.riela-events/bindings/matrix-release-chat-to-workflow.json",
    "examples/event-sources/.riela-events/bindings/webhook-to-arithmetic.json",
    "examples/event-sources/.riela-events/bindings/webhook-to-chat-reply.json",
    "examples/event-sources/.riela-events/bindings/local-docs-to-arithmetic.json",
    "examples/event-sources/.riela-events/bindings/telegram-gateway-personas-to-workflow.json",
    "examples/event-sources/.riela-events/bindings/telegram-gateway-sdk-trio-to-workflow.json",
    "examples/event-sources/.riela-events/bindings/enterprise-matrix-customer-to-workflow.json",
    "examples/event-sources/.riela-events/bindings/gmail-latest-mail-hourly-to-workflow.json",
    "impl-plans/progress/example-contract-03-reconcile.md"
  ],
  "sharedPaths": [
    "examples/README.md",
    "examples/catalog/showcase-and-utility-examples.md",
    "examples/catalog/digest-gateway-and-reply.md",
    "examples/catalog/workflow-composition-and-coding.md",
    "examples/catalog/chat-persona-and-agent-trio.md",
    "examples/event-sources/README.md",
    "examples/event-sources/payloads/chat-message.json",
    "examples/event-sources/payloads/chat-sdk-discord-message.json",
    "examples/event-sources/payloads/gmail-latest-mail-hourly-cron.json",
    "examples/event-sources/payloads/file-change-created.json",
    "examples/event-sources/payloads/chat-sdk-telegram-message.json",
    "examples/event-sources/payloads/enterprise-matrix-security-message.json",
    "examples/event-sources/payloads/telegram-gateway-photo-message.json",
    "examples/event-sources/payloads/chat-supervisor-dispatch-start-managed.json",
    "examples/event-sources/payloads/s3-object-created.json",
    "examples/event-sources/payloads/telegram-time-signal-cron.json",
    "examples/event-sources/payloads/chat-sdk-attachment-judgement-unsupported.json",
    "examples/event-sources/payloads/chat-sdk-attachment-judgement-message.json",
    "examples/event-sources/payloads/enterprise-matrix-customer-message.json",
    "examples/event-sources/payloads/slack-gateway-persona-message-with-history.json",
    "examples/event-sources/payloads/matrix-room-message.json",
    "examples/event-sources/payloads/chat-sdk-slack-message.json",
    "examples/event-sources/payloads/telegram-gateway-message.json",
    "examples/event-sources/payloads/discord-gateway-message-with-history.json",
    "examples/event-sources/payloads/chat-reply-message.json",
    "examples/event-sources/payloads/slack-gateway-message-with-history.json",
    "examples/event-sources/payloads/matrix-persona-message.json",
    "examples/event-sources/payloads/chat-supervised-start.json",
    "examples/event-sources/payloads/chat-supervisor-dispatch.json",
    "examples/event-sources/payloads/x-follower-ai-business-hourly-cron.json",
    "examples/event-sources/payloads/enterprise-matrix-vendor-message.json",
    "examples/event-sources/watched-docs/.gitkeep",
    "examples/event-sources/.riela-events/destinations/slack-gateway-persona-replies.json",
    "examples/event-sources/.riela-events/destinations/enterprise-matrix-vendor-replies.json",
    "examples/event-sources/.riela-events/destinations/matrix-persona-replies.json",
    "examples/event-sources/.riela-events/destinations/slack-gateway-codex-replies.json",
    "examples/event-sources/.riela-events/destinations/release-matrix-chat.json",
    "examples/event-sources/.riela-events/destinations/enterprise-matrix-customer-replies.json",
    "examples/event-sources/.riela-events/destinations/chat-sdk-slack-replies.json",
    "examples/event-sources/.riela-events/destinations/chat-sdk-discord-replies.json",
    "examples/event-sources/.riela-events/destinations/enterprise-matrix-security-replies.json",
    "examples/event-sources/.riela-events/destinations/telegram-gateway-persona-replies.json",
    "examples/event-sources/.riela-events/destinations/example-reply-chat.json",
    "examples/event-sources/.riela-events/destinations/chat-sdk-telegram-replies.json",
    "examples/event-sources/.riela-events/destinations/discord-gateway-persona-replies.json",
    "examples/event-sources/.riela-events/supervisors/default-chat-dispatcher.json",
    "examples/event-sources/.riela-events/sources/gmail-latest-mail-hourly-cron.json",
    "examples/event-sources/.riela-events/sources/discord-gateway-personas.json",
    "examples/event-sources/.riela-events/sources/team-matrix.json",
    "examples/event-sources/.riela-events/sources/example-webhook.json",
    "examples/event-sources/.riela-events/sources/enterprise-matrix.json",
    "examples/event-sources/.riela-events/sources/incoming-docs.json",
    "examples/event-sources/.riela-events/sources/telegram-gateway-personas.json",
    "examples/event-sources/.riela-events/sources/chat-sdk-telegram.json",
    "examples/event-sources/.riela-events/sources/telegram-time-signal-cron.json",
    "examples/event-sources/.riela-events/sources/sequential-list.json",
    "examples/event-sources/.riela-events/sources/chat-sdk-slack.json",
    "examples/event-sources/.riela-events/sources/local-docs.json",
    "examples/event-sources/.riela-events/sources/example-reply-webhook.json",
    "examples/event-sources/.riela-events/sources/chat-sdk-discord.json",
    "examples/event-sources/.riela-events/sources/x-follower-ai-business-hourly-cron.json",
    "examples/event-sources/.riela-events/sources/nightly-cron.json",
    "examples/event-sources/.riela-events/sources/slack-gateway-personas.json",
    "examples/event-sources/.riela-events/sources/slack-gateway-codex.json",
    "examples/event-sources/.riela-events/bindings/sequential-list-to-arithmetic.json",
    "examples/event-sources/.riela-events/bindings/webhook-supervised-arithmetic.json",
    "examples/event-sources/.riela-events/bindings/slack-gateway-personas-to-workflow.json",
    "examples/event-sources/.riela-events/bindings/x-follower-ai-business-hourly-to-workflow.json",
    "examples/event-sources/.riela-events/bindings/discord-gateway-personas-to-workflow.json",
    "examples/event-sources/.riela-events/bindings/chat-sdk-discord-to-workflow.json",
    "examples/event-sources/.riela-events/bindings/slack-gateway-codex-to-workflow.json",
    "examples/event-sources/.riela-events/bindings/telegram-time-signal-cron-to-workflow.json",
    "examples/event-sources/.riela-events/bindings/s3-doc-to-arithmetic.json",
    "examples/event-sources/.riela-events/bindings/cron-to-arithmetic.json",
    "examples/event-sources/.riela-events/bindings/chat-sdk-slack-schedule-registration.json",
    "examples/event-sources/.riela-events/bindings/chat-sdk-discord-to-agent-trio.json",
    "examples/event-sources/.riela-events/bindings/enterprise-matrix-security-to-workflow.json",
    "examples/event-sources/.riela-events/bindings/enterprise-matrix-vendor-to-workflow.json",
    "examples/event-sources/.riela-events/bindings/chat-sdk-telegram-to-workflow.json",
    "examples/event-sources/.riela-events/bindings/webhook-supervisor-dispatch-demo.json",
    "examples/event-sources/.riela-events/bindings/chat-sdk-slack-to-workflow.json",
    "examples/event-sources/.riela-events/bindings/matrix-agent-trio-to-workflow.json",
    "examples/event-sources/.riela-events/bindings/matrix-release-chat-to-workflow.json",
    "examples/event-sources/.riela-events/bindings/webhook-to-arithmetic.json",
    "examples/event-sources/.riela-events/bindings/webhook-to-chat-reply.json",
    "examples/event-sources/.riela-events/bindings/local-docs-to-arithmetic.json",
    "examples/event-sources/.riela-events/bindings/telegram-gateway-personas-to-workflow.json",
    "examples/event-sources/.riela-events/bindings/telegram-gateway-sdk-trio-to-workflow.json",
    "examples/event-sources/.riela-events/bindings/enterprise-matrix-customer-to-workflow.json",
    "examples/event-sources/.riela-events/bindings/gmail-latest-mail-hourly-to-workflow.json"
  ],
  "progressLog": "impl-plans/progress/example-contract-03-reconcile.md",
  "status": "planned; Step 5 review pending",
  "serialRepairPaths": "Exact writePaths of plans 01 and 02, only after recorded ownership transfer at join"
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

## Tasks, deliverables, and dependencies

- [ ] Wait for both repair plans. Merge their evidence into exactly 75 distinct
  workflow rows, plus separate auxiliary SDK test evidence. Compare initial
  inventory against current workflow files; missing/duplicate entries fail.
  Validate all worker hashes and immutable intent snapshots. Explicitly take
  ownership of drifted files before serial repair; preserve both accepted intents.
- [ ] Resolve every cross-owner producer/callee/persona contract against the
  combined tree. Repair coupled schemas, prompts, mocks and callers together,
  using the exact manifests in plans 01/02 as transferred write paths. Re-run
  affected mock scenarios and CLI checks after repair, not merely old logs.
- [ ] Read examples/README.md, examples/catalog/* and examples/event-sources/**.
  Change only concrete documentation or fixture references made inaccurate by
  bundle repairs. Do not start listeners or deliver chat messages. Root README.md
  and repository skills are read-only review targets; report any necessary update
  to the downstream documentation owner with exact requirement and path.
- [ ] Run the focused source and example tests below serially. Read test setup
  first to identify fetch/build/provider side effects. Use only installed local
  dependencies and mock paths. If a suite would fetch missing dependencies,
  record the exact dependency and blocked command, not a false pass. Do not
  weaken existing assertions/counts to hide failed examples. A necessary test
  change outside examples requires an explicit scope/ownership amendment after
  reporting the observed mismatch; no production Swift changes are planned.
- [ ] Prepare a durable review handoff in this progress log: 75-row coverage,
  each material finding and repair, exception classifications, literal commands,
  final exit codes, complete log paths, stable assertions, changed-file list,
  and unresolved limitations. Baseline 59 valid/16 host failures is historical
  intake evidence only. Do not convert an unexplained failure into an exception.

## Verification commands

```sh
riela --version
rg --files examples -g workflow.json
swift test --skip-update --filter 'AgentNodeOutputContractValidationTests|WorkflowOutputContractPreflightTests|RuntimeOutputValidationTests'
swift test --skip-update --filter 'RielaExampleParityTests|RielaExampleLoopGateTests|RielaSlackExampleParityTests|TaskRuntimeExampleTests'
bun test examples/monja-agent-collaboration
bun test examples/monja-project-task-orchestrator/scheduler.test.ts
git diff --check
```

Expected evidence: CLI 0.2.1; 75 unchanged workflow identities; nonzero selected
Swift/Bun tests, all passing (swift test also supplies compilation/type checking);
no whitespace errors. --skip-update avoids updating resolved dependencies but
is not an offline guarantee: inspect availability first and block missing local
dependencies rather than fetching. Capture each full log and exit status under
`tmp/example-contract-migration/example-contract-03-reconcile/<attempt>/`.
Do not repeat already passing unchanged Bun suites if worker terminal evidence
is complete. Reuse unmodified per-bundle CLI evidence; run plan 01's exact
validate/inspect/mock command forms for every changed-at-join bundle and all
cross-owner call paths. Verify every row contains both CLI command outcomes.

If an approved Swift test/source amendment occurs, additionally run:

```sh
swiftlint lint --quiet --no-cache
```

Read `.swiftlint.yml` and installed command help to apply repository tool options
without changing lint policy. TypeScript edits require the respective plan 02
package typecheck. No new generalized test harness is required; scratch assertion
scripts belong under tmp and compare meaningful business behavior.

## Downstream formal gates (not Step 6 worker blockers)

Implementation completion requires the tasks above, passing relevant tests,
complete evidence, no unresolved authoring defects/high/mid findings, and precise
classification of any unavailable host/SDK checks. Missing material verification
must remain explicitly blocked; do not claim full acceptance. Formal independent
review, post-review documentation refresh, commit and push are later Riela steps,
not work this worker may self-authorize or mark done early.

Independent review must inspect the combined diff and deterministic evidence,
resolve all material findings, and verify teaching intent and no live calls.
The documentation owner then refreshes affected docs with accepted results.
The serial finalization owner alone may update this package's plan indexes or
archive its completed plans if required by repository convention; workers do not
write those indexes. Finalization uses the workflow's reviewed exact file allowlist
and commit message, followed by non-force push on fix/example-contract-migration.
Record commit and pushed hashes, exact committed files and terminal evidence;
never add tmp, unrelated files, or modify other worktrees. Do not merge to base.

## Acceptance and progress

Completion is the accepted design §12 contract: 75 reviewed bundles, 150 recorded
validate/inspect attempts using 0.2.1, deterministic scenario evidence and matching
docs, relevant passing tests/typechecks (SwiftLint if applicable), no unresolved
high/mid findings, and later independent review plus commit/push evidence.
Environment-only limitations identify the failing command, diagnostic, prerequisite,
and untested behavior separately from authoring correctness. Each worker progress
log remains independently owned; this log records join results and later gate
status without rewriting worker history. No unresolved user decision is assumed.
