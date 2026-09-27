# Issue 116 verification findings

Workflow mode: `issue-resolution`. Issue: https://github.com/tacogips/riela/issues/116. Codex-agent references: none.

## EXAMPLE-116-01: X digest output schema reference

- Severity: low for issue 116; one example remains invalid after its catalog failure is removed.
- Example: `examples/x-follower-ai-business-digest/workflow.json` and `examples/x-follower-ai-business-digest/nodes/node-summarize-posts.json`.
- Source CLI command: `.build/arm64-apple-macosx/debug/riela workflow validate x-follower-ai-business-digest --workflow-definition-dir /Users/taco/gits/tacogips/riela-worktrees/remaining-impl-plans/examples --output json`.
- Current outcome: exit 1, `valid: false`; diagnostic: `referenced payload field 'replyText' used by step 'send-telegram-digest' must be declared in schema.properties` at `workflow.nodes.summarize-posts.output.jsonSchema.properties.replyText`. Exact stdout, stderr and exit files: `tmp/builtin-addon-116-20260927-comm000006/builtin-addon-116-03-verification/attempt-2/examples/x-follower-ai-business-digest.*`.
- Baseline outcome: `tmp/example-contract-migration/baseline/x-follower-ai-business-digest.json` was invalid with `unresolvedAddonExecutable` at `read-digest-state`, which masked later schema validation. `git diff cf69a96223cc3f65c83414a2efecbb0d5afceaf5 -- examples/x-follower-ai-business-digest` exits 0 with empty output; log and exit file are in `tmp/builtin-addon-116-20260927-comm000006/builtin-addon-116-03-verification/attempt-1/failure-example-head-diff.*`. The exact schema diagnostic is not claimed as reproduced at original HEAD.
- Disposition: classified as a separate example output-contract problem, outside the minimal built-in catalog correction. Follow-up owner: example contract migration. Do not mark this example valid or call it a catalog failure.

All 75 source CLI results and per-example evidence are in `tmp/builtin-addon-116-20260927-comm000006/builtin-addon-116-03-verification/attempt-2/example-summary.json`: 74 valid, one invalid, zero missing JSON, zero `unresolvedAddonExecutable` diagnostics. The installed Riela 0.2.1 CLI was not used.
