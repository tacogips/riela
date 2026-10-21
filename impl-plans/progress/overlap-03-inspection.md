# overlap-03-inspection progress

## Checklist

- [x] Append binding-level overlap policy records to successful `events validate` output for enabled cron bindings.
- [x] Append non-empty receipt reason and optional binding id to `events list` records, preserving the prefix.
- [x] Carry workflow `triggerDefaults` through inspect JSON and text.
- [x] Add focused inspection regression tests using a temporary workflow bundle and event fixtures.
- [x] V1-V3 final-source verification passed; V2 ran 38 tests with 0 failures.

## Source hashes

| File | Before | Final source |
|---|---|---|
| `Sources/RielaCLI/ScopedParityCommands.swift` | `fa2cbc0616b2953754f81464bc8e6c3efc9db270` | `139a1d0d2099afe35b7bfaaad0ceab41963e4c25` |
| `Sources/RielaCLI/WorkflowValidateInspectCommands.swift` | `6ed4770f3b1c0dfab78d9a302288dac26b63deca` | `2e78f46cb6909d0cb6d9f82c53ab1643b86e38be` |
| `Tests/RielaCLITests/OverlapPolicyInspectionTests.swift` | new file | `4ac6c1c5caa810dd6fe0c3dcf963d797cd1eccff` |

## Verification

| Gate | Command | Exit | Tests | Evidence |
|---|---|---:|---:|---|
| V1 final | `arch -arm64 /bin/zsh -lc 'swift build --build-tests'` | 0 | 0 | `tmp/schedule-overlap-policy-20261021-session-471/overlap-03-inspection/v1-build-final-exact.log` |
| V2 final | `arch -arm64 /bin/zsh -lc 'swift test --skip-build --filter "OverlapPolicyInspectionTests|EventReadOnlyPolicyTests|WorkflowHostCapabilityTests|WorkflowInstalledAddonMetadataTests"'` | 0 | 38, 0 failures | `tmp/schedule-overlap-policy-20261021-session-471/overlap-03-inspection/v2-tests-final-exact.log` |
| V3 final | `xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/schedule-overlap-policy-20261021-session-471/overlap-03-inspection/changed-swift-files.nul` | 0 | 0 | `tmp/schedule-overlap-policy-20261021-session-471/overlap-03-inspection/v3-lint-final-exact.log` |

## Prior verification attempts

- Early V1 attempts failed while sibling overlap-02/04 files were changing or incomplete; the complete logs remain in `v1-build.log`, `v1-build-rerun.log`, `v1-build-final.log`, and `v1-build-retry.log`. The later exact final-source V1 succeeded.
- An early V2 `--skip-build` run passed 35 pre-existing tests but did not include the new suite; it is retained in `v2-tests.log` and is not counted as final-source evidence.
- A later V2 run found the webhook fixture missing its required route path; this was fixed by adding `path: /hook`. That run is retained as `v2-tests-final-source.log`; final V2 then passed all 38 tests.
- Initial V3 reported function body length in `eventResult`; record formatting was extracted into private helpers. Final selected-file SwiftLint passed.

## Notes

Event validation now emits policy display values only for enabled cron bindings and only on success. Workflow inspection tests load a temporary copy of an example bundle through `--workflow-definition-dir`; fixture directories stay under this plan's evidence directory.
