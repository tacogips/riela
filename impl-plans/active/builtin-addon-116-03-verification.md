# builtin-addon-116-03-verification

```json
{
  "planId": "builtin-addon-116-03-verification",
  "planPath": "impl-plans/active/builtin-addon-116-03-verification.md",
  "dependsOn": [
    "builtin-addon-116-01-catalog",
    "builtin-addon-116-02-deferred"
  ],
  "writePaths": [
    "design-docs/specs/node-addon-catalog-and-chat-reply-worker/authoring-and-resolution.md",
    "impl-plans/active/builtin-addon-116-verification-findings.md",
    "impl-plans/active/builtin-addon-116-03-verification-progress.md"
  ],
  "sharedPaths": [
    "Sources/RielaAddons/RielaAddons.swift",
    "Tests/RielaAddonsTests/RielaBuiltinAddonCatalogTests.swift",
    "Tests/RielaCLITests/WorkflowHostCapabilityTests+BuiltinCatalog.swift",
    "Tests/RielaCLITests/DeferredContainerAddonTests.swift"
  ],
  "progressLog": "impl-plans/active/builtin-addon-116-03-verification-progress.md"
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

1. Join plans 01/02 and reconcile intent/hash evidence serially. Repair only their declared implementation/test paths if overwritten; record repair ownership and rerun affected tests. Do not change either worker's progress log.
2. Run combined verification under the common Xcode environment, with sequential commands:
```sh
swift test --skip-update --filter RielaBuiltinAddonCatalog
swift test --skip-update --filter WorkflowHostCapabilityTests
swift test --skip-update --filter DeferredContainerAddonTests
/usr/bin/xcrun swiftlint --quiet --no-cache
swift build --skip-update
swift build --skip-update --show-bin-path
git diff --check
```
Check counts and assertions, not exit codes alone. If `xcrun` cannot locate installed SwiftLint, use `swiftlint --quiet --no-cache` under the same environment, recording both attempts. No lint suppressions or unrelated cleanup to hide baseline failures. Build is the required compile/typecheck; no additional broad suite is mandated.
3. Use the absolute `riela` executable in the directory printed by `swift build --skip-update --show-bin-path`. Record executable hash, absolute path, build log and source HEAD/tree evidence. Read `<source-bin>/riela workflow validate --help` to confirm positional directory syntax. Then enumerate sorted `examples/*/workflow.json`, assert count 75, and run sequentially for each parent directory:
```text
<absolute-source-bin>/riela workflow validate <absolute-example-directory> --output json
```
Implement the enumeration/evidence collector only as a throwaway script under this plan's tmp directory. Use subprocess argument arrays, not shell interpolation. Capture stdout, stderr and exit code separately for every example; continue after failures to account for all 75. Write summary JSON with directory, exact argv, executable path, valid flag, diagnostics, exit code, log paths and totals. Do not run workflow nodes, registry discovery or installed CLI validation. Baseline is `tmp/example-contract-migration/baseline/`; compare all results and explicitly check the 12 supported names no longer cause unresolvedAddonExecutable. Missing JSON, incomplete processes or fewer than 75 outcomes are gaps, not passes.
4. If any targeted test or lint fails, determine whether introduced. For claimed pre-existing failures, create an original-HEAD source archive under this plan's tmp directory (`git archive cf69a96223cc3f65c83414a2efecbb0d5afceaf5`), extract there, and run the same failing command with the same Xcode environment/configuration and cached dependencies. No branch switch, new worktree, sibling edits or dependency fetch. Capture baseline/current exact diagnostics and exit codes; if reproduction is unavailable, leave the finding unresolved. Create `impl-plans/active/builtin-addon-116-verification-findings.md` only when findings exist: stable finding ID, affected file/example, severity, baseline proof, command/log links, disposition and follow-up ownership. Precisely classify remaining example failures; do not repair unrelated ones.
5. Update only the issue-116 section of the design with actual source validation totals, evidence paths, deferred semantics and stale installed-0.2.1 distinction. Keep status truthful: implementation verification does not equal independent review acceptance. No package digest refresh because no workflow/prompt/script/skill artifact is changed.

## Acceptance and downstream finalization

Step 6 completion means both implementation plans are reconciled, all required checks have terminal evidence, all 75 examples are accounted for, catalog-caused failures are removed, and test/lint failures either pass or have proven baseline status and separate tracking. Newly introduced defects must be fixed. Unsupported claims of baseline status and missing mandatory evidence block implementation completion. Existing unrelated example failures can remain only with precise evidence as accepted by the design.

Formal adversarial implementation review and combined-tree integration review are downstream gates. After acceptance, the serial finalizer updates review status, stages only this issue's design/plans/progress/source/tests and any findings document, runs `git diff --cached --check`, commits, and runs `git push origin HEAD:refs/heads/fix/example-contract-migration` without force. Verify exit 0 and `git ls-remote origin refs/heads/fix/example-contract-migration` equals local HEAD. Preserve unrelated staged/unstaged work. No parallel Git operations, release or merge. Record commit/push/review evidence and source CLI resume guidance. Do not claim the installed CLI has been updated. Review, commit and push remain pending downstream and do not make an otherwise complete Step 6 worker self-block.
