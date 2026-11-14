---
name: riela-usability-improvement-loop
description: Improve Riela and RielaApp usability through realistic user workflows. Use when Codex is asked to improve, redesign, harden, or review Riela/RielaApp features, specs, package flows, profile switching, workflow/package import, CLI help, onboarding, or any behavior where user friction should be found by operating the product rather than only reading code.
---

# Riela Usability Improvement Loop

Use this skill to turn a vague improvement request into concrete, verified product changes. Optimize for what a new or returning Riela user actually experiences in the CLI and RielaApp.

## Ground Rules

- Work from the repo root and current worktree. Do not assume prior notes are authoritative.
- Keep scratch artifacts under `tmp/<task-name>/`; remove them when finished unless they are useful evidence the user asked to keep.
- For requests to think through, review, or improve a user-facing ideal specification for Riela/RielaApp, run the project workflow `riela-command-app-ideal-spec-review` first and use its output as the review baseline.
- If touching Swift, also read and follow the repo's Swift coding skill before editing.
- If editing GitHub Actions, use the secure GitHub Actions skill.
- Do not preserve legacy behavior by default. Preserve compatibility only when the user requests it or the product contract requires it.
- Touch the sibling `riela-packages` checkout only when the improvement affects packaged workflows, registry metadata, package docs, or external package fixtures.

## Ideal Spec Workflow

Use `.riela/workflows/riela-command-app-ideal-spec-review` when the task is about user-facing ideal behavior, product review, or spec improvement across the `riela` command and RielaApp. This includes package flows, workflow import/list/run UX, disabled/enabled state, update readiness, required environment metadata, onboarding, and recovery behavior.

Validate or run it from project scope:

```bash
riela workflow validate riela-command-app-ideal-spec-review --scope project --output json
riela workflow run riela-command-app-ideal-spec-review \
  --scope project \
  --variables '{"workflowInput":{"requestedWork":"<requested user-facing review>","featureName":"<feature or package flow>","sourceDocumentPaths":["<repo-relative-doc-or-source>"],"outputDocumentPath":"<optional-repo-relative-markdown>","constraints":["Preserve unrelated dirty worktree changes.","Do not commit or push."]}}' \
  --output json
```

If project-scope lookup is unavailable, use `--workflow-definition-dir .riela/workflows` with the same workflow id. After it finishes, continue from the workflow output: apply only the accepted improvements, update the relevant docs/help/UI/code, and verify the exact CLI and App journeys named by the workflow.

## Workflow

1. Define the user journey.
   - Rewrite the request as a concrete user action: create a package, import it into RielaApp, switch profiles, run a workflow, install from an archive, recover from an error, or follow help text.
   - When the request is about the ideal product specification, use the `riela-command-app-ideal-spec-review` workflow output to define the journey before editing docs or code.
   - Identify the exact entry points: CLI command, RielaApp launch flag, menu/button, profile state file, package manifest, README, or example workflow.
   - List expected success signals before changing code.

2. Reproduce with real operations.
   - Build or run the product path, not just unit tests.
   - Prefer isolated roots so the operation is repeatable:

```bash
rm -rf tmp/<task-name>
mkdir -p tmp/<task-name>
swift build --product RielaApp
./.build/debug/riela package init tmp/<task-name>/<package-or-workflow> --package-name <name> --overwrite
./.build/debug/riela package pack tmp/<task-name>/<package> --overwrite
./.build/debug/riela package validate tmp/<task-name>/<archive>.rielapkg
./.build/debug/RielaApp \
  --app-root tmp/<task-name>/app-root \
  --home-root tmp/<task-name>/home-root \
  --profile <profile> \
  --import-workflow-or-package tmp/<task-name>/<source> \
  --open-workflows \
  --no-autostart-daemons
```

   - For profile work, relaunch without `--profile` to verify saved active profile behavior.
   - For import work, test package directory, `.rielapkg`, `.zip`, invalid source, re-import, and mixed success/failure when relevant.

3. Capture friction as product defects.
   - Treat confusing success messages, missing next steps, relative path surprises, hidden profile state, checksum errors without repair guidance, bad defaults, and stale UI labels as defects.
   - Check both CLI and RielaApp surfaces when they share a concept. A package UX fix is incomplete if CLI help, app import, profile state, and README disagree.
   - Prefer canonical vocabulary. If a UI identifier or data field should be `source`, remove competing `sources` behavior unless compatibility is explicitly required.

4. Implement narrowly but end-to-end.
   - Keep domain rules in testable support modules when possible; keep AppKit/controller code thin.
   - Preserve profile-specific preferences across re-imports. Do not reset user choices such as enabled/disabled or auto-start unless that is the requested behavior.
   - Make error messages actionable. Include the failing path and the next command or UI action when a user can repair the issue.
   - Update help text and README whenever a workflow becomes the recommended path.
   - Add regression tests for the product contract, not merely the helper function.

5. Verify with evidence that matches the user journey.
   - Run focused tests for changed behavior.
   - Run `swift build --product RielaApp` when app launch/import behavior changed.
   - Run SwiftLint after Swift edits.
   - Run at least one realistic CLI/App operation for UX changes. Inspect generated profile state, logs, archive validation output, or UI-visible status text.
   - Check `git diff --check`.
   - Check Swift file sizes; split meaningful responsibilities before leaving a non-generated Swift file over 1000 lines.

## Usability Checklist

Use this checklist before handing off:

- A user can find the next action from help text or UI labels.
- A user can distinguish imported, updated, failed, enabled, disabled, active, and auto-start-off states.
- Profile switching does not silently lose or leak state across profiles.
- Re-importing a workflow or package preserves profile preferences unless intentionally changed.
- Relative paths resolve from the user's working directory, not an implementation accident.
- Package checksum failures tell the user how to regenerate the manifest.
- RielaApp import supports the same source forms the CLI advertises.
- Mixed success/failure operations report all outcomes in one readable status.
- Tests cover the edge case that made the UX confusing.
- Temporary files are under `tmp/` and removed when no longer needed.

## Typical Validation Commands

Choose the narrowest useful set, then broaden when shared behavior changed:

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter <RelevantTests>
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --product RielaApp
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk \
TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault \
PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH \
/usr/bin/xcrun swiftlint
git diff --check
rg --files -g '*.swift' | xargs wc -l | sort -nr | head -25
```

## Handoff

Report the user journey tested, the friction found, the files changed, and the exact validation commands. If a broad improvement goal remains active, state what concrete progress was made without claiming the entire product goal is complete.
