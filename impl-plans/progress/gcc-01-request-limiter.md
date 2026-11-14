# gcc-01-request-limiter progress

## Scope and changes

- Added `GmailCollectionRequestLimiter`, an internal actor that reserves shared
  request start slots, refuses slots at or beyond the deadline, supports the
  coordinator's prefetched profile grant, and waits only for positive
  `slot - now` intervals.
- Added ten deterministic tests for first and subsequent slots, injected wait
  clocks, concurrent reservations, zero interval, deadline refusal,
  prefetched grants, and cancellation.
- Left all gcc-02 files untouched. The accepted design is
  `design-docs/specs/design-native-source-collection.md`, subsection “Full
  listing, concurrent thread reads and early-stop reasons” (shared limiter
  decision D4). Plan `gcc-01-request-limiter` has no dependencies; the
  dispatch reports no issue URL, number, or repository. The workflow input is
  the source of truth for the ART mailbox delay problem; plan acceptance is
  workflow `opus-luna-design-and-implement-review-loop-session-541`,
  communication `comm-010177`.

## File hashes

Pre-edit hashes were captured before adding each owned source file. Current
source hashes are after implementation and verification. The progress file
was absent before this edit; its final hash is in the plan-local
`tmp/gmail-collect-concurrency/gcc-01/post.sha256` because embedding a file's
own digest would be self-referential.

| Owned file | Pre-edit SHA-256 | Post-edit SHA-256 |
| --- | --- | --- |
| `Sources/RielaCLI/GmailCollectionRequestLimiter.swift` | absent | `f3ac8d1df38786a0d40470f006e988a676d8f110d439525591d421c118dc3e67` |
| `Tests/RielaCLITests/GmailCollectionRequestLimiterTests.swift` | absent | `e472a635263bdeeaf292ad0838e7fe80f1696d0ec8780468583bf12bbd16874c` |
| `impl-plans/progress/gcc-01-request-limiter.md` | absent | see `tmp/gmail-collect-concurrency/gcc-01/post.sha256` |

## Completion criteria

- The refusal error and limiter actor expose the plan-pinned internal names;
  `acquire()` checks cancellation first, reserves before awaiting, and leaves
  state unchanged when the deadline refuses a slot.
- `recordPrefetchedGrant()` occupies one slot; grants are reservation counts,
  including a reservation whose wait is later cancelled.
- The ten planned limiter test situations pass.
- Build, focused tests, strict lint and the gcc-02 untouched-file check pass.
- The limiter source has no `unchecked` occurrence.

## Verification

| Command | exitStatus | testsRun | failureCount | Complete log |
| --- | ---: | ---: | ---: | --- |
| `arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift build > tmp/gmail-collect-concurrency/gcc-01/build.log 2>&1'` | 0 | 0 | 0 | `tmp/gmail-collect-concurrency/gcc-01/build.log` |
| `arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift test --filter GmailCollectionRequestLimiterTests > tmp/gmail-collect-concurrency/gcc-01/test.log 2>&1'` | 0 | 10 | 0 | `tmp/gmail-collect-concurrency/gcc-01/test.log` |
| `arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && if [ -s tmp/gmail-collect-concurrency/gcc-01/changed-swift-files.nul ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/gmail-collect-concurrency/gcc-01/changed-swift-files.nul; else printf "%s\n" "No Swift files changed; selected-file SwiftLint not run."; fi > tmp/gmail-collect-concurrency/gcc-01/swiftlint.log 2>&1'` | 0 | 0 | 0 | `tmp/gmail-collect-concurrency/gcc-01/swiftlint.log` (empty) |
| `arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swiftlint lint --strict --quiet --no-cache Sources/RielaCLI/GmailCollectionRequestLimiter.swift Tests/RielaCLITests/GmailCollectionRequestLimiterTests.swift > tmp/gmail-collect-concurrency/gcc-01/swiftlint-plan.log 2>&1'` | 0 | 0 | 0 | `tmp/gmail-collect-concurrency/gcc-01/swiftlint-plan.log` (empty) |
| `git diff --quiet -- Sources/RielaCLI/GmailCollection.swift Sources/RielaCLI/GmailCollectionCoordinator.swift Sources/RielaCLI/ProductionNodeAdapter+GmailCollect.swift Tests/RielaCLITests/GmailCollectionTests.swift > tmp/gmail-collect-concurrency/gcc-01/scope-check.log 2>&1` | 0 | 0 | 0 | `tmp/gmail-collect-concurrency/gcc-01/scope-check.log` (empty) |

The build log contains existing warnings elsewhere in the package; it contains
no warning or error naming `GmailCollectionRequestLimiter.swift`. No source
diagnostic was reported for the new production file. Formal integration review
and later workflow finalization remain downstream steps.
