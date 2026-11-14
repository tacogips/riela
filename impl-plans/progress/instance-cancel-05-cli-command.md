# instance-cancel-05 CLI progress

- Implemented cancel dispatch, validation, exact request body, closed-field error output, wait polling, usage and surface registration in the assigned files.
- Added transport-based cancellation tests for request paths, headers, body, unsupported and semantic errors, ambiguity, polling and usage.
- Build and strict selected-file SwiftLint passed (build.log, lint2.log). Focused aggregate test.log exited 1: 60 tests, 5 failures; four new cancel tests and eight existing App command tests passed. Three CLI parity failures require adding cancel to InstanceClientSubcommand in Sources/RielaCLI/RielaClientFamilyArguments.swift, which is outside the assigned writePaths. Two web parity failures report an uncatalogued reload route and the existing instance path scanner. Their baseline has not been established. Request an ownership/scope amendment and rerun the aggregate on the stable shared tree.
- Formal review, integration, documentation review and commit are downstream workflow steps.

## Redispatch: IR-SCOPE-05-PARSER

- Added `case cancel` to `InstanceClientSubcommand`; the amended plan authorizes that file. Build and strict changed-file lint passed; the focused CLI aggregate passed 20 tests. The required aggregate ran 60 tests with 2 failures and 1 skipped; `SurfaceParityCLITests` passed all 8. Logs and exit codes are in `tmp/instance-cancel/instance-cancel-05-cli-command/redispatch/`.
- Before and after the parser change, the two web assertion details are identical:
  - `[webAPI] POST /api/v1/instances/{identity}/reload: exists on the surface but has no catalog row`
  - `Sources/RielaCLI/InstanceAppCommands.swift: /api/v1/instances/`
- At e4970417 the instance path literal already occurs once, and the review identified the missing reload catalog row as baseline. No cancel route appears in the current violations. A source-matched preimplementation test log and required comparison JSON were not found, so the nonzero aggregate remains pending baseline evidence rather than a passing gate.

## Redispatch: IR-05-WEB-LITERAL

- The current repair supersedes IR-05-BASELINE-EVIDENCE. Split the existing instance path prefix into two literals without changing the resulting path or percent encoding. The prior baseline disposition is no longer pending for this plan's gate.
- `build-r5.exit`, `test-r5.exit` and `lint-r5.exit` are 0 under `tmp/instance-cancel/instance-cancel-05-cli-command/`. The specified focused gate passed 21 tests with 0 failures, including `testNoSourceServesAnUndeclaredAPIPath`, the cancel and existing App command suites, and all 8 SurfaceParityCLITests. The reload catalog assertion is owned by plan 10 and excluded by the repair brief.
- The repair changed only the path construction line in the source relative to the pre-repair snapshot. Pre/post hashes and edit intent are recorded in the evidence directory. Verification used the shared worktree; formal reviews and serial integration remain downstream.
