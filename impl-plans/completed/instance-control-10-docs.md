# Instance control 10: documentation

**Status**: Completed; accepted by Step 6 test-integrity and Step 7 adversarial review (2026-11-10). Combined-tree re-verification after the rebase onto main is a finalization step
**planId**: instance-control-10-docs
**dependsOn**: instance-control-04-cli-commands, instance-control-09-app-reload-route (so flags and codes are final)
**Design Reference**: design-docs/specs/design-instance-reload-run-cli.md D7, D2 rollout, D5, §6
**Created**: 2026-11-10
**Evidence root**: tmp/instance-control/instance-control-10-docs/

## Intent and context

Operators and agents need one page that explains how to control resident RielaApp instances from the CLI. The page must also state the **one-time App upgrade** prerequisite.

## Non-goals

- No code changes.
- No edits to design docs other than the one lifecycle note.
- No CHANGELOG or release notes.

## File-level changes

1. **`docs/app-instance-control.md` (new)**, with these sections:
   - Overview.
   - Prerequisites:
     - *Running App 0.3.1*: start the web server once from Console > Settings > Web Config server. `run`/`executions` then work; `reload` needs the upgrade.
     - *One-time upgrade*: replace RielaApp with a build containing this change, once. After that the listener autostarts from `web-server.json` `isEnabled`, and no further restarts are needed.
   - Endpoint and profile discovery: `RIELA_APP_ROOT`, `web-server.json`, `active-profile.json`, `--server`, `--profile`.
   - Identities:
     - list identities are accepted everywhere;
     - `--profile` resolves ambiguity;
     - App instances are read-only for `instance update/remove`.
   - One subsection per command (`reload`, `run`, `executions`), with flags, a JSON output example and exit codes. Copy flag names, defaults, ranges and codes from `Sources/RielaCLI/InstanceAppCommands.swift`, not from memory.
   - Reload semantics:
     - definition-only reloads never interrupt;
     - binding/triggerDefaults changes use the admission barrier;
     - `instance_run_in_flight` and `--wait-idle`;
     - `--interrupt-running`;
     - `handoff: lost` and re-running;
     - `reload-handoff` receipts and `riela events replay`;
     - force import discards store-only edits (audited).
   - Error code table.
   - Security notes: loopback only, csrf/profile/revision unchanged, no environment values printed.
2. **`README.md`**: one bullet or short paragraph in the CLI section linking to `docs/app-instance-control.md`. Do not restructure the README.
3. **`Resources/skills/riela-workflow-run/SKILL.md`**: a short "Resident RielaApp instances" pointer listing the three commands and linking the doc. Keep the skill frontmatter unchanged.
4. **`design-docs/specs/design-rielaapp-web-server-lifecycle-packaging.md` §2.2**: append one note line under the `On app launch, isEnabled: true triggers startup` bullet: "Implemented 2026-11-10 by design-instance-reload-run-cli.md D2 (previously only `--start-web-server` was honoured)."

## Verification

1. `mkdir -p tmp/instance-control/instance-control-10-docs && grep -n -e "instance reload" -e "instance run" -e "instance executions" -e "one-time" docs/app-instance-control.md README.md Resources/skills/riela-workflow-run/SKILL.md > tmp/instance-control/instance-control-10-docs/grep.log; echo exit=$?` — exit 0, and every file appears.
2. Cross-check: every error code in `Sources/RielaAppSupport/RielaAppInstanceReloadContract.swift` (`RielaAppInstanceReloadCode` raw values) appears in the doc's error table. Record the comparison in the progress log.
3. If the repo has a skill/doc test (for example `SurfaceParitySkillTests`), run `arch -arm64 /bin/zsh -lc 'swift test --filter SurfaceParitySkillTests 2>&1 | tee tmp/instance-control/instance-control-10-docs/skill-test.log; exit ${pipestatus[1]}'` — 0 failures.

## Edit safety

- Fresh-read before each edit; record the pre- and post-edit sha256.
- `README.md` and the lifecycle design are sharedPaths limited to the additions above.

## Completion criteria

- [x] The doc exists and is accurate against the code.
- [x] Pointers have been added.
- [x] Verification recorded.

## Progress Log

### Session: 2026-11-10
Plan authored (Opus). Not started.

### Session: 2026-11-11 — implementation
- Added the operator guide, README and skill pointers, and the lifecycle §2.2 note; skill frontmatter is unchanged.
- Grep exit 0 with all three files present: `tmp/instance-control/instance-control-10-docs/grep.log` and `grep-check.log`.
- Compared `RielaAppInstanceReloadCode` raw values against the guide table: 15 contract codes, 15 table rows, no missing or extra codes; exit 0, `tmp/instance-control/instance-control-10-docs/code-cross-check.log`.
- `arch -arm64 /bin/zsh -lc` with isolated HOME and RIELA_APP_ROOT, `swift test --filter SurfaceParitySkillTests`: exit 0, 7 tests, 0 failures; `tmp/instance-control/instance-control-10-docs/skill-test.log`.
- `git diff --check`: exit 0; `tmp/instance-control/instance-control-10-docs/diff-check.log`. Formal integrity and adversarial review remain downstream.

## Amendment 2026-11-10 (blocked-wave-scope-or-contract, round 1)

**Why.** This plan is not blocked yet, but it would hit the same blocker: its `swift test --filter SurfaceParitySkillTests` writes SwiftPM build output.

**Change.**
- `writePaths` and `artifactRoots` add `.build`.
- `dependsOn` is unchanged; through 09 it runs after both build lanes.
- The verification commands are unchanged and authorized as written.

**Rules:**
- Never pass `--scratch-path`.
- Never run `swift package clean`, `reset`, `update`, or anything that rewrites `Package.resolved`.
- Wait on a held `.build` lock.
