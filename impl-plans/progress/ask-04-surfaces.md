# ask-04-surfaces progress

## Implemented

- Checkpoint `e208d257f1b3ef77cd4a95b70960130dc9c1bb70`. The dispatch lists
  ask-03-turn-engine as an accepted dependency and the current plan has no
  pending predecessors.
- Registered the Ask CLI and GraphQL surfaces. CLI text streams the turn and
  JSON emits the final payload. Explicit and active paired remotes own their
  turns and expose verified origin. GraphQL enforces pairing scope and records
  the pairing grant ID and client name on confirmed or dismissed actions.
- Chained Ask beside Bots in CLI document execution, the library executor,
  machine and browser serve, and RielaApp. Ask uses the canonical runtime
  database and the existing activity waiter pool.
- Added the mock walkthrough in `examples/ask-run-status/EXPECTED_RESULTS.md`
  and deterministic CLI, GraphQL and remote regression tests.

## Per-edit hashes

`tmp/ask-riela/ask-04-surfaces/edit-intentions.md` records the hunks and pre/post
hashes. `author-audit.log` reconciles the edits against the native pre-node
snapshot and manifest write scope. `source-manifest.sha256` identifies the
verified sources and tests. No unowned drift was observed.

## Verification

Logs are under `tmp/ask-riela/ask-04-surfaces/`.

| Gate | Exit | Evidence |
| --- | ---: | --- |
| `mkdir -p tmp/ask-riela/ask-04-surfaces` | 0 | `setup.log` |
| `scripts/surface-parity/generate-sdl.sh` twice | 0, 0 | `sdl.log`, `sdl-repeat.log`. One generator test passed per invocation. |
| `cmp Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift tmp/ask-riela/ask-04-surfaces/sdl-pre-final-repeat.swift` | 0 | `sdl-cmp.log`, `sdl-hashes.log` |
| `arch -arm64 /bin/zsh -lc 'swift build'` | 0 | `build.log` |
| Committed Swift test filter below | 0 | `test.log`. XCTest reported 143 selected with one generator-only skip. Swift Testing passed 39. Total 181 passed, zero failures. |
| `xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/ask-riela/ask-04-surfaces/changed-swift.nul` from an arm64 shell | 0 | `swiftlint.log`, 38 selected Swift files |
| `grep -n "api/v1" Sources/RielaCLI/Ask -r` | 1, expected no matches | `grep-rest.log`, empty |
| `git diff --stat Sources/RielaAppSupport/RielaWebAPIRouteTable.swift` | 0 | `rest-route-diff.log`, empty |
| `git diff --check` | 0 | `diff-check.log` |

```bash
arch -arm64 /bin/zsh -lc 'swift test --filter "AskGraphQLTests|AskCommandTests|AskRemoteTests|AskExampleWalkthroughTests|AskTurnEngineTests|AskActionTests|SurfaceCatalogTests|SurfaceParityCLITests|SurfaceParityGraphQLTests|SurfaceParityExecutorCoverageTests|SurfaceParityDTOSchemaTests|SurfaceParityWebAPITests|SurfaceParityConsoleReadTests|SurfaceParityLibraryTests|SurfaceParitySkillTests|RielaExampleParityTests|SubcommandHelpTests|SubcommandHelpApplicationTests|CommandParsingTests|BotCommandTests|BotsGraphQLTests|RemoteForwardingTests|PairingScopeEnforcementTests|ServeWebHostTests|ServeHTTPCommandTests"'
```

The aggregate used an isolated HOME, XDG roots and credential directory. The
workflow-home override was cleared so pre-existing example fixtures could
select their own roots. The generator-only test ran in both SDL commands.

SDL SHA-256 before and after the second generation was
`45a39a4130f6cb54a2782ed5233f0b5d1058ceb912add896ccd2b1207993653d`.
The verification source manifest SHA-256 was
`bee9e3df48e3536a5e2e4019e7bfe5ea99cc23179457693043b9a2ace776fb5b`.

The earlier aggregate in `test-with-inventory-and-env-failures.log` exited 1
with three XCTest assertions. The CLI inventory now includes Ask. Clearing the
outer workflow-home override resolved the two existing enterprise example
assertions on the current source. Earlier compile and lint attempts remain in
`build-initial.log`, `build-compile.log`, `sdl-attempt-1.log`,
`sdl-attempt-2.log`, `swiftlint-first.log` and
`swiftlint-generated-length.log`. The final gates above supersede them.

## Deviations

- The 2026-11-25 round 2 amendment (comm-000344) resolves
  `ASK-04-LOCAL-NO-FOLLOW-LIFECYCLE`. A local target rejects `--no-follow`
  before adapter selection or writes. Both explicit and active paired remotes
  return a running snapshot and complete the turn server-side.
- The generator compacts short Swift literals within the configured line
  width. The canonical SDL keeps its exact line structure. The OpenRouter
  endpoint constant lives with the provider catalog and retains its URL.

## Open items

Implementation criteria are verified. Independent review and integration
acceptance are pending in the later workflow steps.
