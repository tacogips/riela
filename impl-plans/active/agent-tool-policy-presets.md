# Agent tool-policy presets: plan set index

Mode: `issue-resolution`. The issue comes from workflowInput: "Agent tool-policy
presets (none / web-search) for Codex, Claude Code and SDK backends incl.
Gemini". It has no GitHub issue number. There are no Codex-agent references.

Sources of truth:

- Design: `design-docs/specs/design-agent-tool-policy-presets.md`, accepted by
  Step 3 review in session 503 (DR-1 and DR-2 fixed, DR-3 citation fixed).
- Open decisions: `design-docs/user-qa/qa-agent-tool-policy-presets.md`.
  Implement the recommended decision for Q1, Q2 and Q3.

No worker edits this file. Serial finalization updates it together with
`impl-plans/README.md` and `impl-plans/PROGRESS.json`.

## Waves

| Wave | planId | Plan | dependsOn |
|---|---|---|---|
| 1 | atp-01-core-contract | `agent-tool-policy-presets-01-core-contract.md` | — |
| 1 | atp-02-agent-gateway-pin | `agent-tool-policy-presets-02-agent-gateway-pin.md` | — |
| 2 | atp-03-core-resolution | `agent-tool-policy-presets-03-core-resolution.md` | atp-01 |
| 2 | atp-04-core-validation | `agent-tool-policy-presets-04-core-validation.md` | atp-01 |
| 2 | atp-05-adapter-websearch | `agent-tool-policy-presets-05-adapter-websearch.md` | atp-01, atp-02 |
| 1 | atp-06-docs | `agent-tool-policy-presets-06-docs.md` | — |
| 3 | atp-07-live-smoke | `agent-tool-policy-presets-07-live-smoke.md` | atp-03, atp-04, atp-05, atp-06 |

The `writePaths` of all plans are disjoint. No plan has `sharedPaths`.
`Package.resolved` belongs to atp-02 only.

## Shared worker protocol

Every plan follows this protocol.

- **Workspace.** Work in the repository root `/Users/taco/gits/tacogips/riela`,
  on the feature branch the workflow checked out for this run. Do not create
  branches or worktrees. Do not run `git commit`, `stash`, `reset`, `checkout`,
  `add` or `push`. The serial finalization step commits and pushes.
- **Edit scope.** Edit only your own `writePaths`.
- **Hash every edit.** Before each edit:
  1. Read the file fresh.
  2. Record `shasum -a 256 <file>` (the pre-hash) and a one-line intent
     snapshot in your progress log.
  3. After the edit, record the post-hash.

  If a pre-hash differs from your last recorded post-hash, another writer
  changed the file. Re-read it and re-apply your intent on top. Never revert a
  foreign change, and log the drift.
- **Peer breakage.** If the build fails in a file outside your `writePaths`, or
  SwiftPM is busy resolving or holding the `.build` lock (atp-02 changes the
  pin in wave 1), log it as peer drift. Retry up to 3 times, a few minutes
  apart. Never edit the other file.
- **Scratch files.** Scratch files and logs go only under
  `tmp/agent-tool-policy-preset/<planId>/`. Never commit them.
- **Progress log.** Write only to `impl-plans/progress/<planId>.md`. It holds:
  - task checkboxes;
  - the hash records;
  - decisions taken;
  - one record per verification, as `{command, logPath, exitStatus, testsRun,
    failureCount}`. `testsRun` and `failureCount` are the integer totals from
    the XCTest `Executed N tests, with F failures` lines and the swift-testing
    `Test run with N tests … passed/failed` lines, summed.

  A blocked check is recorded as `blocked: <reason>` with the exact command
  and exit status. Never record it as a pass.
- **Commands.** Run every command in the foreground, from an arm64 shell, in
  this form:

  ```
  arch -arm64 /bin/zsh -lc '<cmd> > tmp/agent-tool-policy-preset/<planId>/<name>.log 2>&1'
  ```

  Lint only the files you own, with
  `swiftlint lint --quiet --no-cache <files>`.
- **Out of scope for every plan.** VERSION bump, release, agent-gateway source
  changes, GraphQL SDL changes (`AgentToolPolicy` is not exposed there), and
  any `cursorArguments` behavior change.

## Final gate (serial reconciliation, not a per-plan gate)

```
arch -arm64 /bin/zsh -lc 'swift build'
arch -arm64 /bin/zsh -lc "swift test --filter 'AgentToolPolicy|AgentPromptGuardTests|WorkflowBackendPolicyTests|OpenModelProviderRoutingTests|AgentNodeOutputContractValidationTests|WorkflowModelTests|DynamicWorkflow|RielaAdaptersTests'"
arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet --no-cache <every touched Swift file>'
```

The gate also requires the live smoke evidence from atp-07, plus this note in
the final report: "Gemini live check not run: GEMINI_API_KEY unset".
