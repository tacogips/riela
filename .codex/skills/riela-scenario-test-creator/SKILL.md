---
name: riela-scenario-test-creator
description: Create or improve deterministic Riela scenario tests that cover package creation, validation, packing, CLI/package workflow use, RielaApp import/readiness/enablement behavior, workflow execution monitoring, and adversarial Riela-based assessment.
metadata:
  short-description: Create Riela package/App scenario tests
---

# Riela Scenario Test Creator

Use this skill when adding scenario tests for Riela package and RielaApp flows. Keep the test evidence deterministic by default, and use live LLM calls only when the user explicitly asks for them.

## Required Scenario Contract

Cover these surfaces in one acceptance scenario unless the request narrows scope:

- Create a package source from a workflow and run `riela package init`.
- Validate the package source, pack it into `.rielapkg`, validate the archive, and install it into project scope.
- Use the installed package through `riela workflow validate` and at least one workflow run command.
- Import or install the same package through RielaApp support code, then discover the App candidate.
- Check required environment variable metadata without printing secret values.
- Verify missing and present environment readiness with `RielaAppEnvironmentFileStore`.
- Verify disabled and enabled workflow preferences with `RielaAppImportPreferencePolicy`.
- Execute the workflow with `--mock-scenario`, inspect the run result, then monitor it with `riela session progress` or `session status`.

## Determinism And Model Budget

- Prefer `--mock-scenario` and `scenario-mock` for CI and local tests.
- For live `codex-agent` checks in this project, use only models verified for the local ChatGPT-backed Codex account. Currently verified: `gpt-5.5`.
- Do not use `gpt-5-mini` for `codex-agent`; it is unsupported for this account and fails before the adversarial assessment can run.
- If a lower-cost live model is desired later, verify it first with `printf 'Return exactly: OK\n' | codex exec --json --model <model> -- -` before adding it to workflow or test metadata. For deterministic tests, prefer mocks over cheaper live fallback models.
- Do not require `OPENAI_API_KEY` for deterministic tests. Model credentials should appear only as required env metadata such as `RIELA_SCENARIO_OPENAI_API_KEY`.
- Assert stable fields: package name, source kind, workflow id, validation validity, app candidate id/scope, env variable names, preference booleans, run status, node execution count, transition count, root output keys, and session progress status.
- Treat session ids, timestamps, archive extraction roots, and temporary paths as unstable unless directly controlled by the test.

## Implementation Pattern

1. Put Swift scenario tests near the exercised surface. For cross CLI/App package flows, use `Tests/RielaCLITests` with `RielaAppSupport` as a test dependency.
2. Build the package fixture under a test temp directory. Do not write scratch files outside `tmp/` for manual verification; XCTest temporary directories are acceptable and must be cleaned up.
3. Create the workflow fixture with a real `workflow.json`, file-backed node, `mock-scenario.json`, and package manifest.
4. Drive CLI flows through `RielaCLIApplication().run([... "--output", "json"])` rather than directly calling helper functions.
5. Drive RielaApp package behavior through `RielaAppManagedPackageInstaller`, `RielaAppDaemonWorkflowDiscovery`, `RielaAppEnvironmentFileStore`, and `RielaAppImportPreferencePolicy`.
6. Decode JSON command outputs and assert typed DTOs instead of string matching except for user-facing error text.

## Riela Adversarial Assessment

Before final handoff for substantial scenario-test work:

1. Write a short scenario spec and evidence summary under `tmp/<task-name>/`.
2. Run the project Riela review workflow when available:

```bash
riela workflow validate riela-command-app-ideal-spec-review --scope project --output json
riela workflow run riela-command-app-ideal-spec-review \
  --scope project \
  --variables '{"workflowInput":{"requestedWork":"Adversarially assess the new Riela package/App scenario test specification and evidence.","featureName":"Riela package/App scenario tests","sourceDocumentPaths":["tmp/<task-name>/scenario-spec.md","tmp/<task-name>/test-evidence.md"],"constraints":["Prefer deterministic tests.","Do not require live OpenAI credentials.","Do not expose secret values."]}}' \
  --output json
```

3. Feed actionable findings back into the test or skill. If the Riela review workflow is unavailable, run the closest deterministic workflow review available and record the limitation.

## Verification

Run the narrow relevant test first, then lint:

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter WorkflowCommandTests/testPackageAppEnvironmentEnablementRunAndMonitoringScenario
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint
git diff --check
```

Broaden to package/App support tests when shared behavior changes.
