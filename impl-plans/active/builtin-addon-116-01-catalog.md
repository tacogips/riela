# builtin-addon-116-01-catalog

```json
{
  "planId": "builtin-addon-116-01-catalog",
  "planPath": "impl-plans/active/builtin-addon-116-01-catalog.md",
  "dependsOn": [],
  "writePaths": [
    "Sources/RielaAddons/RielaAddons.swift",
    "Tests/RielaAddonsTests/RielaBuiltinAddonCatalogTests.swift",
    "Tests/RielaCLITests/WorkflowHostCapabilityTests+BuiltinCatalog.swift",
    "impl-plans/active/builtin-addon-116-01-catalog-progress.md"
  ],
  "sharedPaths": [],
  "progressLog": "impl-plans/active/builtin-addon-116-01-catalog-progress.md"
}
```

## Execution contract (mandatory for this plan)

Issue: https://github.com/tacogips/riela/issues/116. Mode: `issue-resolution`.
Design: `design-docs/specs/node-addon-catalog-and-chat-reply-worker/authoring-and-resolution.md`, section “Issue #116: built-in host catalog parity”; accepted by Step 3, comm-000004, no findings. Codex-agent references: none. Cursor mapping/divergence: none.
Original HEAD: `cf69a96223cc3f65c83414a2efecbb0d5afceaf5`; branch: `fix/example-contract-migration`.
Intent: remove erroneous host executable requirements for the 12 existing built-ins used by bundled examples while preserving runtime behavior.
Non-goals: new providers, live calls, namespace-wide acceptance, aliases, unrelated examples/refactors, dependency updates, sibling repositories, releases and merges.

Before native fanout, the serial workflow owner must obtain Step 5 acceptance, commit the accepted design and all three plans, and non-force push the checkpoint to `origin/fix/example-contract-migration`. Verify push exit 0 and remote branch equals the checkpoint; a blocked push prevents dispatch. No worker performs Git mutations. No worktrees or private branches. Do not perform this checkpoint before plan acceptance.

Before each edit, freshly read the file and capture SHA-256 (or ABSENT) in the worker's own `tmp/example-contract-migration/<planId>/` evidence directory. Save an immutable intent snapshot containing plan ID, exact owned paths, planned changes and pre-edit content/hash. Recheck the hash immediately before writing; drift requires a fresh read and reconciliation, never replacement from a stale copy. Save post-edit hashes and copies/diffs as immutable output evidence. Workers edit only their declared files and their own progress log. Record each task as pending/in-progress/done/blocked, changed paths, command argv, full stdout/stderr log path, final exit code and remaining findings. Scratch belongs under tmp/, never committed.

After join, the serial owner compares observed hashes/diffs with all workers' intent/output snapshots and runtime change evidence, repairs overwritten intent serially, and reruns affected checks. Shared indexes, lockfiles, broad formatting and plan archiving are serial-only; none needs changing for this fix. Never rewrite unrelated work. Swift build/test operations sharing `.build` must be serialized; independent authoring can proceed in parallel.

Use Xcode environment for every verification shell:
```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
export TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault
export PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH
```
`swift` below must resolve to that Xcode toolchain. Record `command -v swift`, `swift --version` and `/usr/bin/xcrun --find swift`. Run commands in the foreground with complete logs and exit-code sidecars in the plan evidence directory; poll any yielded process until exit. No live model/network/provider calls; Git checkpoint/final push is the explicitly authorized transport exception. Use cached dependencies without updates; if a command requires fetching, report the concrete verification limitation rather than initiating a fetch. Never treat an incomplete log, zero matched tests or missing tool as a pass.

## Tasks and exact changes

1. Fresh-read catalog, `WorkflowValidateInspectCommands.swift` host-requirement builder, `WorkflowRequirements.swift`, and existing host tests. Keep production changes confined to `Sources/RielaAddons/RielaAddons.swift`.
2. Add version `1` descriptors for exactly: `riela/chat-persona-router`, `riela/chat-persona-memory-read`, `riela/chat-persona-memory-write`, `riela/memory-save`, `riela/memory-load`, `riela/gmail-digest`, `riela/x-digest`, `riela/gemini-sdk-worker`, `riela/codex-sdk-worker`, `riela/time-signal`, `riela/gmail-gateway-read`, `riela/x-gateway-read`. Add small coherent groups to `all`; identify the last two as deferred no-op entries in comments/group naming. Preserve existing descriptors and `supports` matching logic; add no other names.
3. Create `RielaBuiltinAddonCatalogTests.swift`, class `RielaBuiltinAddonCatalogTests`. Independently enumerate the 12 expected names; assert descriptor version 1, nil/1 supported, 2 rejected, unique catalog names, unknown `riela/issue-116-unknown` and `example/issue-116-unknown` rejected. Do not derive expected names from the catalog under test.
4. Extend `WorkflowHostCapabilityTests` in new companion file `WorkflowHostCapabilityTests+BuiltinCatalog.swift`. The existing file is 1081 lines; avoid growing it or unrelated splitting. Add file-local fixtures with distinct names because existing helpers are private. Use existing `WorkflowValidateCommand`, an injected bundle resolver and capability resolver, one used add-on node/step per bundle, no manifest/dependency declaration and empty executable map. Table-test all 12 with nil and version 1: valid strict-local host resolution without an external executable. For version 2 and both unknown names assert failure and `unresolvedAddonExecutable`, not merely nonzero exit. These tests must never call adapter execution or ambient backend probes. Preserve environment requirements and existing local-command tests.

## Invariants and acceptance

All twelve references resolve as built-ins only at supported catalog versions. Unknown names and unsupported versions do not gain a fallback; legitimate package/dependency matching remains unchanged. Deferred catalog entries do not claim gateway connectivity. No changes to host resolver or production adapter are expected; if tests reveal a required change there, report evidence to serial owner before expanding scope.

## Verification and completion

Run `swift test --skip-update --filter RielaBuiltinAddonCatalog` and `swift test --skip-update --filter WorkflowHostCapabilityTests`; retain logs, actual test counts and exit codes. `--skip-update` prevents dependency refresh; required test filters remain unchanged. Existing local-command positive/negative coverage must remain passing. Run `git diff --check`. Deliver source/tests, progress and immutable change evidence. Integration lint/build and 75-example verification belong to plan 03; this worker does not wait for formal downstream review or commit.
