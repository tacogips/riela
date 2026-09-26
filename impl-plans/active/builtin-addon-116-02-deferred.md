# builtin-addon-116-02-deferred

```json
{
  "planId": "builtin-addon-116-02-deferred",
  "planPath": "impl-plans/active/builtin-addon-116-02-deferred.md",
  "dependsOn": [],
  "writePaths": [
    "Tests/RielaCLITests/DeferredContainerAddonTests.swift",
    "impl-plans/active/builtin-addon-116-02-deferred-progress.md"
  ],
  "sharedPaths": [],
  "progressLog": "impl-plans/active/builtin-addon-116-02-deferred-progress.md"
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

1. Read `Sources/RielaCLI/ProductionNodeAdapter.swift` deferred dispatch and `Tests/RielaCLITests/GmailGatewayAddonTests.swift` runner injection fixtures. Create only `Tests/RielaCLITests/DeferredContainerAddonTests.swift`, class `DeferredContainerAddonTests`.
2. Test both `riela/gmail-gateway-read` and `riela/x-gateway-read` using `BuiltinWorkflowAddonResolver(environment: [:], localGatewayGraphQLRunner: ...)`, fixed workflow/step/node IDs, version 1, empty inputs/variables and `AdapterExecutionContext`. Use a recording runner that fails if called; assert call count zero after execution. Use existing recording type only if visible; otherwise add a small test-local concurrency-safe recorder. No production injection framework or adapter edits.
3. Assert exact payload keys/values (`status: ok`, add-on name, fixed stepId), provider `riela-builtin-addon`, model equal to add-on name, empty prompt and completionPassed true. This captures actual current semantics, not a mock replacement response. Do not reinterpret the response as fetched mail/posts or invoke provider workers.

## Invariants and acceptance

Both deferred names keep their exact no-op response and perform no gateway request. The distinct live `riela/gmail-gateway-reader` is neither aliased nor changed. Tests must fail if deferred execution starts using the injected gateway runner or changes its output contract.

## Verification and completion

Run `swift test --skip-update --filter DeferredContainerAddonTests` and `git diff --check`; record nonzero matched test count, full logs and exit codes. This plan is independent of catalog additions and can author tests in parallel with plan 01; serialize SwiftPM invocations. Deliver tests, own progress and immutable change evidence. Final build/lint and review belong downstream.
