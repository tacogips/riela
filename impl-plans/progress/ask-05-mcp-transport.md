# ask-05-mcp-transport

## Implemented

- ACP v1 and v2 now carry typed stdio MCP servers. Relative commands and backends without gateway MCP support fail before the first request. Older adapter input decodes with an empty server list.
- Ask selects MCP for eligible Codex and Claude hosts with an absolute Riela path. Each MCP turn makes one adapter call and uses the same read-only tool executor as rounds. CLI hosts supply the running binary and RielaApp uses its bundled sibling. The script switch and explicit rounds override still select rounds.
- The MCP tool server uses the host's registry, session root and scope. Tool calls share store budgets, record activity and persist references for citations. The protocol tests use a real CLI subprocess and fixture stores.
- Host-only redaction bindings cross the process boundary through a private, per-turn file in the store scratch root. The handoff excludes secret names and bound values from the server environment. Posted values remain available during the turn and are removed on completion, cancellation, deadline, provider failure and stale-runner recovery. Missing or malformed handoff files fail with `redaction_values_unavailable`.
- The preset contract tests retain the default argument arrays. The MCP-only variant retains strict vendor configuration, drops the conflicting empty configuration and limits Claude to Ask MCP tool names.

## Completion criteria

- [x] ACP v1/v2 adapter request, MCP protocol, registry, shared budgets, redaction and private file lifecycle verified.
- [x] Default argv preserved. No `mcpServers: []` literal remains in adapter requests.
- [x] Vendor flags and remaining live checks recorded below.
- [x] Required Swift behavioral gate and changed-file SwiftLint passed.
- [x] The package criterion passes against the accepted ask-01 baseline per integration-review finding ASK-05-PACKAGE-DIFF.

## Per-edit hashes

`tmp/ask-riela/ask-05-mcp-transport/edit-intentions.md` records parent edits. Delegated edits are in `adapter-edits.log`, `cli-edits.log` and `server-edits.log` in the same directory. `changed-files.json` lists plan-local paths and SHA-256 values from the pre-node snapshot and current tree. No Git staging, commits or pushes occurred.

## Verification

- `arch -arm64 /bin/zsh -lc 'swift test --filter "AskToolServerTests|AskTransportTests|AskAgentPolicyTests|AskTurnEngineTests|AskPromptInjectionTests|AskCommandTests|AskExampleWalkthroughTests|AgentToolPolicyPresetContractTests|AgentToolPolicyResolutionTests|AgentGatewayNodeAdapterTests|AgentGatewayACPV2Tests|GatewayScriptedAgentTests|SurfaceCatalogTests|SurfaceParityCLITests|SubcommandHelpTests|CommandParsingTests"'` exited 0. 77 XCTest and 75 Swift Testing tests passed. Full log `tmp/ask-riela/ask-05-mcp-transport/test.log`. The gate wrapper supplies isolated home, credential and XDG directories.
- `arch -arm64 /bin/zsh -lc 'swift test --skip-build --filter "AskToolExecutorTests|AskReadOnlyTests|AskContextTests|AskActionTests|SurfaceParityGraphQLTests|SurfaceParityExecutorCoverageTests|SurfaceParitySkillTests|SurfaceParityLibraryTests"'` exited 0. 30 XCTest and 11 Swift Testing tests passed. XCTest skipped the SDL regeneration test, which runs from its dedicated script. Full log `tmp/ask-riela/ask-05-mcp-transport/test-extra.log`.
- `arch -arm64 /bin/zsh -lc 'changed_swift_manifest=tmp/ask-riela/ask-05-mcp-transport/changed-swift.nul; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\n" "No Swift files changed; selected-file SwiftLint not run."; fi'` exited 0 on 34 Swift paths. Full log `tmp/ask-riela/ask-05-mcp-transport/swiftlint.log`.
- `grep -rn "mcpServers: \[\]" Sources/RielaAdapters` returned 1 with no matches. `git diff --check` exited 0. Logs `tmp/ask-riela/ask-05-mcp-transport/mcp-literals.log` and `tmp/ask-riela/ask-05-mcp-transport/diff-check.log`.
- `git diff --numstat Package.swift` returned exactly one addition and two deletions, `git diff Package.resolved` returned no output, and `shasum -a 256 Package.swift Package.resolved` matched `package-before.sha256` byte for byte. All commands and expected-output checks passed in `tmp/ask-riela/ask-05-mcp-transport/package-baseline.log`.
- `source-before-test.sha256` and `source-after-test.sha256` matched across the required behavioral run. `verification-exits.log` and `static-exits.log` record exits within the evidence directory.
- On redispatch, the same focused arm64 Swift filter ran through `verify-tests.sh` with isolated home, credential and XDG directories. It exited 0 with 77 XCTest and 75 Swift Testing tests passed and zero failures. Full log `tmp/ask-riela/ask-05-mcp-transport/test-redispatch.log`. The pre- and post-run source manifests matched, as recorded in `source-redispatch-cmp.log` in the evidence directory.
- On redispatch, the same selected-file SwiftLint command exited 0 on 34 Swift paths and the adapter grep exited 1 with no matches. Logs `swiftlint-redispatch.log`, `mcp-literals-redispatch.log` and `static-redispatch-exits.log` in the evidence directory.

## Deviations

- The literal `git diff Package.swift Package.resolved` check prints the accepted, uncommitted ask-01 hunk removing the `RielaAppSupport` resources entry. The package criterion is met against the accepted baseline per integration-review finding ASK-05-PACKAGE-DIFF. See `tmp/ask-riela/ask-05-mcp-transport/package-baseline.log`.
- `test-first.log` exited 1 before tests because a test parameter's visibility was narrower than its method. `test-second.log` exited 1 because the labelled log fixture triggered generic redaction and hid the host-specific placeholder. Replaced that log entry with an unlabelled synthetic value that only the host binding can redact. The final aggregate passed. The first supplemental run completed its tests but the zsh status recorder failed. The supplemental rerun recorded its exit separately.

## Open items

- Confirmed with Codex CLI 0.172.0 `exec --help`: `-c/--config`, `--disable`, `--strict-config`, `--sandbox`, `--skip-git-repo-check`, `--ephemeral`, `--ignore-user-config` and `--ignore-rules`. The existing preset records Codex CLI 0.164.0 as its original verification point. Confirm actual strict-config feature overrides, server visibility and tool restriction in a live turn.
- Confirmed with Claude Code 2.1.318 `--help`: `--tools ""`, `--strict-mcp-config`, `--mcp-config`, `--allowedTools` with comma-separated entries, `--disable-slash-commands`, `--setting-sources` and `--permission-mode`. Confirm the exact `mcp__riela-ask__<tool>` names, their interaction with the disabled built-ins and process shutdown with each live client. The stdio server exits on EOF. A signal with stdin held open was not exercised.
- The approved fallback is `RIELA_ASK_TOOL_TRANSPORT=rounds`. No live vendor turn ran during implementation.
- Test integrity, adversarial and serial integration decisions remain downstream.
