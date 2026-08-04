Verify the implementation in the current worktree and repair failures caused by it.

Run focused Swift tests for RielaApp support/API and Note CLI/service changes. Run Web unit tests, typecheck, lint/audit, and build for changed TypeScript. Build RielaApp, run SwiftLint with the repository's Xcode toolchain environment, run `git diff --check`, and inspect changed Swift file sizes. Perform one realistic isolated journey under `tmp/` that creates/runs a direct private workflow into a shared session store, removes the workflow definition, loads the run detail through the definition-independent layer, and creates the three-note workflow-run notebook under its folder path.

Do not hide failures. Fix in-scope regressions, distinguish unrelated pre-existing failures, and return concise JSON with commands, results, and evidence gaps.
