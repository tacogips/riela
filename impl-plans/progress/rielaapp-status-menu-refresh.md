# RielaApp status menu refresh implementation progress

Status: `implementation-complete; downstream review and commit pending`
planId: `rielaapp-status-menu-refresh`
workflowMode: `issue-resolution`
issueReference: local:workflowInput.issueTitle — "RielaApp menu bar is extremely slow: periodic menu rebuild blocks the main thread on SMAppService.status"
plan: `impl-plans/active/rielaapp-status-menu-refresh.md`

## Tasks

- [x] T1 controller cache, refresh generation, live-guard `setEnabled`
- [x] T2 menu open-state guard, deferred rebuild, `.default` timer, toggle and launch wiring
- [x] T3 `RielaLaunchAtLoginControllerTests` (5 tests)
- [x] T4 verification V1–V3 (V4 optional; run and passed)
- [ ] T5 local commit (no push; downstream workflow step)

## File hashes (pre → post)

| File | Pre-edit hash | Post-edit hash |
| --- | --- | --- |
| `Sources/RielaApp/RielaLaunchAtLoginController.swift` | `cf5fb3ce1489d3b398b45d85a3f6adce56d8d0ec` | `a613025ccdef885b4662948b1f6e252f8f1ec358` |
| `Sources/RielaApp/EntryPoint.swift` | `8a1b76141ce6a213f1188cd3a802bdfe57844b03` | `ee7b5fa888f24e8af31508ec6a08e0c6da7501f9` |
| `Sources/RielaApp/EntryPoint+Menu.swift` | `c09a2fe03c8edd88b37fe062410c039bf1151ead` | `298c14d6b4da684140057050cb4648fc8cb6ec28` |
| `Tests/RielaAppSupportTests/RielaLaunchAtLoginControllerTests.swift` | new file | `91eb74cd5d6d2049e45da9a71447f63436789356` |
| `impl-plans/progress/rielaapp-status-menu-refresh.md` | `0c3b53ff933552d76050f90f85b3d3b2d80eb9ea` | self-hash omitted; see Step 6 result |

## Reference patch usage

Not used. Implemented directly from the accepted design and plan.

## Verification evidence

All logs are complete and stored under `tmp/menubar-impl/`.

| ID | Command | exitStatus | testsRun | failureCount | logPath | Outcome |
| --- | --- | ---: | ---: | ---: | --- | --- |
| V1 | `arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela/tmp/menubar-fix-worktree && swift build --skip-update --build-tests && swift test --skip-update --skip-build --filter "RielaLaunchAtLoginControllerTests|RielaAppUXOnboardingTests|RielaAppAPIKeyTests"'` | 0 | 8 | 0 | `tmp/menubar-impl/v1-build-test.log` | Build passed; controller (5) and API key (3) passed. The plan filter selected no onboarding tests because the XCTest class is named `RielaAppUXOnboardingControllerTests`. |
| V1b | `arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela/tmp/menubar-fix-worktree && swift test --skip-update --skip-build --filter "RielaLaunchAtLoginControllerTests|RielaAppUXOnboardingControllerTests|RielaAppAPIKeyTests"'` | 0 | 14 | 0 | `tmp/menubar-impl/v1b-corrected-focused-test.log` | Passed: controller (5), onboarding (6), API key (3). |
| V2 | `changed_swift_manifest=tmp/rielaapp-status-menu-refresh-20261020-session-459/changed-swift-files.nul; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf '%s\\n' 'No Swift files changed; selected-file SwiftLint not run.'; fi` | 0 | 0 | 0 | `tmp/menubar-impl/v2-lint.log` | Changed-file SwiftLint passed with no diagnostics. |
| V3 | `grep -rn "SMAppService" Sources/RielaApp > tmp/menubar-impl/v3-grep.log; grep -n "forMode" Sources/RielaApp/EntryPoint.swift >> tmp/menubar-impl/v3-grep.log` | 0 | 0 | 0 | `tmp/menubar-impl/v3-grep.log` | All `SMAppService` references are in `RielaLaunchAtLoginController.swift`; timer uses `.default`. |
| V4 | `arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela/tmp/menubar-fix-worktree && swift test --skip-update --skip-build --filter RielaAppBehaviorRegressionTests/testStatusMenuUsesCompactSummaryItemsAtRuntime'` | 0 | 1 | 0 | `tmp/menubar-impl/v4-menu-regression.log` | Existing status-menu summary regression passed. |

The first V1 attempt failed during compilation on missing `return` statements in the supplementary-description switch (exit 1, 0 tests, 0 test failures); corrected before the passing V1/V1b records. Its log path was reused by the successful V1 rerun, so the original failure log is not retained. The current-source rerun is complete at `tmp/menubar-impl/v1-build-test.log`.

Completion criteria for the implementation phase are satisfied: V1, V1b, V2, V3 and V4 pass, cache/menu invariants hold, and the changed source/test set is limited to the assigned files. The accepted workflow assigns formal review, exact-file staging and the local commit to downstream steps; no commit or push was made here.

## Notes

- `EntryPoint.swift` in the repository defines `RielaAppUXOnboardingControllerTests`; the original plan filter used the non-matching `RielaAppUXOnboardingTests` substring. V1b records the corrected coverage.
- Launch-item changes while the menu is open update the checked item in place and defer any list rebuild until the asynchronous close callback follow-up.
- No GUI launch, accessibility automation, external write, or push was performed.
