# bots-07-jobs-core progress

## Implemented

- Added a pure due check using the injected clock and calendar. Nightly keys
  use local dates, weekly keys use the ISO week-year, and catch-up returns
  the newest closed period plus up to 30 older missing keys in chronological
  order. Catch-up starts after the period of the last successful run.
- Added atomic ledger claims and skips over the existing bot store. Finishing
  a run only updates a running claim, and the latest success uses completion
  time.
- Added bounded suggestion parsing, provenance, conditional accept/dismiss,
  and the accepted-to-started transition. Optional actions with invalid
  workflow names or non-object inputs are discarded.
- Added the look-around policy check for a single-step agent workflow and
  rejection of add-ons, command/container payloads and nested workflows.
- Added the four committed-plan test suites with isolated store fixtures.

## Per-edit hashes

The table records additions and corrections. Contextual replacements and
exact initial proposals are in
`tmp/bots-overview/bots-07-jobs-core/edit-intentions.md`.

| Path | Pre-edit SHA-256 | Post-edit SHA-256 |
| --- | --- | --- |
| `Sources/RielaCore/BotJobs/BotJobSchedule+Due.swift` | `absent` | `8af153832df7cea9f69e9e5d4bc0932fad876142afa4ec8a462b6f6d8cc5cb35` |
| `Sources/RielaCore/BotJobs/BotJobLedger.swift` | `absent` | `babadedd903778d53992615ad126d2f242d16d79a914d3b3a754142e64aa11ed` |
| `Sources/RielaCore/BotJobs/BotSuggestion.swift` | `absent` | `c552cd8e6dfb1eee0837e16385509fd6c028d245b77484520d69eac1741a40fd` |
| `Sources/RielaCore/BotJobs/LookAroundPolicy.swift` | `absent` | `4c6318dfff90863b1128e21a84e1b45dc61f12b8b043e05d1181dfb173a8c3e2` |
| `Tests/RielaCoreTests/BotJobs/BotJobDueTests.swift` | `absent` | `8ece0c9dd308066febd9eda49b02cc8d124af08f5104f1c35bee97a36e8190f7` |
| `Tests/RielaCoreTests/BotJobs/BotJobLedgerTests.swift` | `absent` | `ad1404d93b48a81900bd3acd263bf6cbe2b2080c976240ab0f2e238db8733c66` |
| `Tests/RielaCoreTests/BotJobs/BotSuggestionStoreTests.swift` | `absent` | `188738d21a3110521823b98d8adf05ab91884aa69dd20c39c384ca3853238f1d` |
| `Tests/RielaCoreTests/BotJobs/LookAroundPolicyTests.swift` | `absent` | `eda5eed1c3277f153700837b2060dd8cc2c820b03fc51b65a2cfe80144aa8ad3` |
| `Tests/RielaCoreTests/BotJobs/LookAroundPolicyTests.swift` | `eda5eed1c3277f153700837b2060dd8cc2c820b03fc51b65a2cfe80144aa8ad3` | `b8c35c53077937006c6dad860b0b14bc8d1ab8b39a267eeb773383b8129ef6e5` |
| `Tests/RielaCoreTests/BotJobs/BotJobDueTests.swift` | `8ece0c9dd308066febd9eda49b02cc8d124af08f5104f1c35bee97a36e8190f7` | `ba9b549b4c8c5ed00137151ab3187cdbd859e6ae15bed160a9fdfc1314f48faf` |
| `Sources/RielaCore/BotJobs/BotJobLedger.swift` | `babadedd903778d53992615ad126d2f242d16d79a914d3b3a754142e64aa11ed` | `ecdac746667401d6b52be97734ad09ffa765e4f0797109065003a46e755d4631` |
| `Sources/RielaCore/BotJobs/BotJobLedger.swift` | `ecdac746667401d6b52be97734ad09ffa765e4f0797109065003a46e755d4631` | `0d791b695f0bdc0566e20a1f151773890f6e94d797d68f7b96cff95c530314a9` |
| `Sources/RielaCore/BotJobs/BotJobSchedule+Due.swift` | `8af153832df7cea9f69e9e5d4bc0932fad876142afa4ec8a462b6f6d8cc5cb35` | `1ccd15897769cc54b04ce9fd7149cb029df0bebdffde96579955b6195a960457` |
| `Sources/RielaCore/BotJobs/BotJobSchedule+Due.swift` | `1ccd15897769cc54b04ce9fd7149cb029df0bebdffde96579955b6195a960457` | `24f1d0df74a2fd296d00bdbb73c28f618a7dce4154b202c27b95c7c4827dcea0` |
| `Sources/RielaCore/BotJobs/BotJobSchedule+Due.swift` | `24f1d0df74a2fd296d00bdbb73c28f618a7dce4154b202c27b95c7c4827dcea0` | `49b4e5e623cdc9a2080fd271e5d7daeed9acd9a88e09c11d4a55b99b64d99658` |
| `Sources/RielaCore/BotJobs/BotSuggestion.swift` | `c552cd8e6dfb1eee0837e16385509fd6c028d245b77484520d69eac1741a40fd` | `2db393ed9d1277110a1379c4dc5e111f48e728c75e9a1e98c54659d04f73655a` |
| `Sources/RielaCore/BotJobs/BotSuggestion.swift` | `2db393ed9d1277110a1379c4dc5e111f48e728c75e9a1e98c54659d04f73655a` | `1b8bee0bdd8709d624855ec0fb41a133b74cb588695caf0a79fc83b9217da6e5` |
| `Sources/RielaCore/BotJobs/BotSuggestion.swift` | `1b8bee0bdd8709d624855ec0fb41a133b74cb588695caf0a79fc83b9217da6e5` | `f744b69cbebda5e2c1ef89ee851912d84a1b949871e1f7b4f3c9e4b7f24509e4` |
| `Sources/RielaCore/BotJobs/BotSuggestion.swift` | `f744b69cbebda5e2c1ef89ee851912d84a1b949871e1f7b4f3c9e4b7f24509e4` | `31436d6dd79f63e09f40cd29fc58311ed99c513b250b93b08e8d4b2c9c738573` |
| `Sources/RielaCore/BotJobs/BotSuggestion.swift` | `31436d6dd79f63e09f40cd29fc58311ed99c513b250b93b08e8d4b2c9c738573` | `8d63111aa6dfb2210650c45d4a54c6ea9310caf7d7e5d61a9326ac6e248f1d09` |

## Verification

- `mkdir -p tmp/bots-overview/bots-07-jobs-core` exited 0.
  Log: `tmp/bots-overview/bots-07-jobs-core/evidence-directory.log`.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "BotJobDueTests|BotJobLedgerTests|BotSuggestionStoreTests|LookAroundPolicyTests"'`
  exited 0. `Executed 21 tests, with 0 failures (0 unexpected)`.
  All four suites passed. Log: `tmp/bots-overview/bots-07-jobs-core/test.log`.
- `arch -arm64 /bin/zsh -lc 'changed_swift_manifest=tmp/bots-overview/bots-07-jobs-core/changed-swift.nul; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\n" "No Swift files changed; selected-file SwiftLint not run."; fi'`
  exited 0 for all eight changed Swift files.
  Log: `tmp/bots-overview/bots-07-jobs-core/swiftlint.log`.
- `grep -rn "Calendar.current\|Date()" Sources/RielaCore/BotJobs/BotJobSchedule+Due.swift`
  exited 1 with zero matches as required.
  Log: `tmp/bots-overview/bots-07-jobs-core/due-clock.log`.
- Plan-local source hashes matched before and after verification.
  Logs: `tmp/bots-overview/bots-07-jobs-core/source-before.sha256`,
  `tmp/bots-overview/bots-07-jobs-core/source-after.sha256`, and
  `tmp/bots-overview/bots-07-jobs-core/source-drift.log`.

Earlier test attempts exited 1 before running tests. Attempt 1 encountered
sibling compiler errors in the activity and memory slices. Attempt 2 also
caught missing `try` at two suggestion encoder calls, corrected in this plan.
Attempts 3 through 5 exposed sibling build failures in the activity and
adapter slices. The final shared-tree run passed after those sources changed.
Earlier complete logs are retained as `test-attempt-1.log` through
`test-attempt-5.log` in the plan evidence directory. Earlier lint diagnostics
are retained in `swiftlint-attempt-1.log`; the final lint was clean.

## Completion criteria

- [x] Deterministic job and suggestion core implemented within the assigned scope.
- [x] No ambient clock or calendar references in the due check.
- [x] Four focused suites passed with zero failures and progress recorded.

## Deviations

None. The working tree was shared during compilation. The active plan
matches the committed baseline.

## Open items

Formal test-integrity, adversarial and serial integration review follow this
step. The serial wave gate owns cumulative verification on the reconciled
tree.
