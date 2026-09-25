# NRE-03 implementation progress

- Workflow mode: issue-resolution.
- Issue: local request on `feat/native-remote-workflow-execution`; no GitHub issue URL or number supplied.
- Plan: `impl-plans/completed/native-remote-03-provider-host-integration.md`.
- Codex agents: `/root` integrated source; prior `/root/provider_explore`, `/root/host_explore`, `/root/test_explore` and this run's `/root/code_audit`, `/root/test_audit` performed read-only investigation.
- Accepted predecessor decisions: NRE-01 and NRE-02 are accepted external prerequisites in the focused dispatch; NRE-03 `dependsOn` is empty. No predecessor repair was required.
- Preimplementation baseline HEAD: `72a9dae65c6ca99cd06746d2100dcf3465fc3e8f`; implementation HEAD during attempt 3: `acbeab0de927afd3c816bbb8238aede19bdcfc8c`.
- Current state: in progress after attempt 3. Generated parity, provider/host focus, build and strict changed-file lint pass. The complete aggregate exits 1 with 11 assertions reproduced exactly at the preimplementation checkpoint. Remaining assigned test cases are listed below; formal baseline disposition belongs to independent review.

## Changed paths and intent

- `Sources/RielaCLI/WorkflowExecutionProvider.swift`: map the ordinary typed input to `WorkflowRunCommand.run`, decode ISO 8601 CLI result dates, require strict persisted reads, and project ordered canonical summary arrays.
- `Sources/RielaCLI/ServeHTTPCommand.swift`: compose the execution-specific bearer wrapper outside the registry composite and expose the production adapter composition to HTTP tests.
- `Sources/RielaCLI/ServeWebHost.swift` and `Sources/RielaApp/RielaAppWebGraphQL.swift`: add execution to existing gated browser fallback chains with request-captured store context.
- `Sources/RielaCore/SurfaceCatalog+Rows.swift` and `Tests/RielaGraphQLTests/SurfaceParityExecutorCoverageTests.swift`: declare both roots and their executor coverage.
- `Tests/RielaCLITests/WorkflowExecutionProviderTests.swift`: strict valid, absent, missing-runtime, mismatched-workflow, and corrupt-record reads.
- `Tests/RielaCLITests/ServeHTTPCommandTests.swift`: real ephemeral `RielaLocalHTTPServer`, existing `URLSessionWorkflowGraphQLRunTransport`, ordinary persisted run with all supported input fields and nonzero execution/transition arrays, bearer and forbidden-key rejection before effects, and corrupt-versus-absent HTTP summary responses.
- Per-edit baseline hashes and exact hunk intentions: `tmp/native-remote-implementation/NRE-03/attempt-1/edit-001-intent.json` through `edit-026-intent.json`. NRE-01/NRE-02 changes were preserved.

## Verification on the moving combined tree

All commands ran in the foreground with complete logs and terminal exit files under `tmp/native-remote-implementation/NRE-03/attempt-1/`. Earlier failures remain in `test-2` through `test-11` and `lint-1`; the ISO 8601 decoder and test-fixture/schema fixes resolved those specific failures.

| Command | Log | Exit | Result |
| --- | --- | ---: | --- |
| `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build` | `build-2.log` | 0 | Source build passed during host edits. |
| `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'SurfaceParityExecutorCoverageTests\|WorkflowExecutionGraphQLTests'` | `test-1.log` | 0 | 16 passed, 0 failed. |
| `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter ServeHTTPCommandTests/testMachineHTTPExecutesAndReadsPersistedWorkflowWithBearer` | `test-13.log` | 0 | 1 passed, 0 failed; final URLSession input-field version. |
| `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'WorkflowExecutionProviderTests\|CLIWorkflowSessionStoreResilienceTests'` | `test-15.log` | 0 | 6 passed, 0 failed. |
| `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH xargs -0 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < tmp/native-remote-implementation/NRE-03/attempt-1/changed-swift.nul` | `lint-2.log` | 0 | Strict selected-file lint passed for 17 changed Swift files. |
| `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'WorkflowExecutionGraphQLTests\|ServeHTTPCommandTests\|ServeWebHostTests\|ServerContractsTests\|RielaAppWebRegistryProviderTests\|SurfaceParity'` | `test-16.log` | 1 | 93 run, 1 skipped, 3 parity failures. |

## Blocking ownership gap

`test-16.log` reports that `Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift` is stale: it lacks `Mutation.executeWorkflow` and `Query.workflowExecution`. The generator preview is `tmp/surface-parity/GraphQLContractProjector+Schema.swift.generated`. This generated source is not in NRE-03 `writePaths` or either predecessor's listed write paths. The Step 6 rule forbids editing an unapproved path and requires a terminal blocked handoff. Resume when the serial workflow owner allocates that exact generated file to an implementation plan, then regenerate it, rerun the parity suite and remaining source-matched gates.

Pending implementation-phase work after allocation includes the full provider failure/paused matrix, browser/profile and cancellation lifecycle tests, final source build, aggregate tests, and required documentation. Independent integrity/adversarial/integration reviews, review-dependent documentation finalization, exact-file commit and non-force push belong to later workflow steps and are not represented as completed here. Parent P1 A2/A3 remains open.

## Redispatch attempt 2: aggregate gate triage and ownership handoff

The current combined tree remains incomplete. The prior aggregate log at
`tmp/native-remote-receiver-20260925/reconcile-wave-2/aggregate-tests.log`
ended during `RielaExampleParityTests` without a completed suite summary; its
recorded exit status is 1. A focused foreground rerun of the recorded App
failures used
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'RielaAppSettingsEditorNavigationTests|RielaAppUXOnboardingControllerTests|RielaAppWindowContentInsetTests'`.
It exited 1, executing 11 tests with 11 assertion failures. Complete log and
terminal status are `tmp/native-remote-implementation/NRE-03/attempt-2/app-failures-rerun.log`
and `.exit`. The three failing test files and their AppKit UI sources are
unchanged against planning commit `9b1c935`; only
`Sources/RielaApp/RielaAppWebGraphQL.swift` changed in the App target. These
failures have not been proven baseline by a source-matched baseline test run,
so the required aggregate gate remains failed. Repair or baseline acceptance
requires the serial owner's disposition because the failing tests and UI
sources are outside NRE-03 `writePaths`; no tests were suppressed.

Read-only I5 investigation found that `WorkflowSessionStatus` in
`Sources/RielaCore/RuntimeSession.swift` has `created`, `running`, `completed`
and `failed`, with no `paused` case or ordinary runner pause result. I5's
paused-result acceptance therefore needs a plan/design disposition or an
approved owner for that source path. A fabricated persisted row would not
verify the required ordinary execution behavior. Provider failed/pre-session,
browser/profile and disconnect/server-stop cancellation tests remain pending.
The production provider's failure-envelope branch also still needs to derive
status/exit evidence from the strict persisted result. No source change was
made in attempt 2. The previous generated-schema ownership repair is present
in the current shared tree, but it is outside NRE-03's write list and needs
serial reconciliation.

Attempt-2 intent snapshot: `tmp/native-remote-implementation/NRE-03/attempt-2/edit-001-intent.json`.
Implementation remains blocked on aggregate failure disposition and the
paused-status contract mismatch. Resume I5-I8 after those owners settle the
required gate and scope, retaining all existing changes and logs.

## Redispatch attempt 3: corrected contract and source-matched evidence

The accepted design and plan amendment resolved attempt 2's paused-status
contract and allocated the generated schema path. These are historical
attempt-2 blockers, not current dependencies. The current parity test proves
the checked-in generated source is byte-identical to its generator; no new
regeneration or predecessor edit was needed.

The owner made small contextual edits with pre-hash and hunk intent records
`tmp/native-remote-implementation/NRE-03/attempt-3/edit-001-intent.json`
through `edit-020-intent.json`. Current NRE-03 edits are in
`Sources/RielaCLI/WorkflowExecutionProvider.swift`,
`Tests/RielaCLITests/WorkflowExecutionProviderTests.swift`,
`Tests/RielaCLITests/ServeHTTPCommandTests.swift`,
`Tests/RielaCLITests/ServeWebHostTests.swift`, and
`Tests/RielaAppSupportTests/RielaAppWebRegistryProviderTests.swift`.
The provider now requires result/failure-envelope exit and status agreement
with strict CLI and runtime records, including workflow/session identity,
and masks the startup operator bearer from node environment. Real runner
tests cover completed/0, failed/maxStepsExceeded/nonzero, pre-session
failure and immediate persisted summaries; injected contradictions are
separately labeled. The real HTTP host test covers both URLSession round trips,
bearer/forbidden/unknown/malformed input rejection, persisted failure and
server-stop cancellation after client disconnect. Browser tests cover gated
execution and a held run across profile switch, with writes confined to the
captured original store. Desktop source-policy assertions are explicitly
labeled; they do not substitute for real HTTP evidence.

The bounded App comparison exported `72a9dae` into
`tmp/native-remote-baseline/source/`, verified relevant exported bytes against
`git show`, and confirmed that checkpoint has no provider source. Its
`Package.swift` and `Package.resolved` hashes match the current tree. Both
baseline and final current source ran the same exact 11-test filter with fresh,
distinct scratch builds and Xcode 26.6 / Swift 6.3.3 arm64. Baseline
`baseline-app.log` exited 1 with 11 assertions in six named failed cases;
final current `current-app-final.log` also exited 1 with identical test and
assertion signatures. `comparison-final.json` records the match. The first
current attempt stopped before tests with disk full and retained its exit-1
log; only disposable comparison build directories were removed, then the
current side was retried and finally rebuilt against the final source.
The source hashes are in `source-manifest-final.json`. The full final-source
aggregate at `attempt-3/aggregate-source-final.log` exited 1 after 1,465 tests,
two skipped and exactly the same 11 App assertions; the other errors list is
empty in `tmp/native-remote-baseline/aggregate-comparison-final.json`.
This is a proven baseline attribution, not an accepted waiver or a passing
aggregate. Independent reviewers must decide the explicit disposition.

| Final-source command | Complete log and exit file | Exit | Outcome |
| --- | --- | ---: | --- |
| `env -u RIELA_WRITE_GENERATED_SDL /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter SurfaceParityGraphQLTests` | `attempt-3/parity-final.log`, `.exit` | 0 | 6 tests, 1 skipped, 0 failures; byte parity passed. |
| `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'WorkflowExecutionProviderTests\|CLIWorkflowSessionStoreResilienceTests\|WorkflowExecutionGraphQLTests\|ServeHTTPCommandTests\|ServeWebHostTests\|ServerContractsTests\|RielaAppWebRegistryProviderTests\|SurfaceParity'` | `attempt-3/focused-source-final.log`, `.exit` | 0 | 105 tests, 1 skipped, 0 failures. |
| `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build` | `attempt-3/build-final.log`, `.exit` | 0 | Source build passed. |
| `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'RielaGraphQLTests\|RielaServerTests\|RielaCLITests\|RielaAppSupportTests'` | `attempt-3/aggregate-source-final.log`, `.exit` | 1 | 1,465 tests, 2 skipped, 11 checkpoint-matched assertions (1 unexpected). |
| `xargs -0 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < attempt-3/changed-swift.nul` with explicit Xcode environment | `attempt-3/lint-final-2.log`, `.exit`; manifest lists 20 Swift paths | 0 | Strict changed-file lint passed. |
| `git diff --check` | `attempt-3/diff-check.log`, `.exit` | 0 | No whitespace errors. |

Earlier attempt-3 failures remain in `focused-1.log`, `cancel-1.log`,
`browser-1.log`, `lint-final.log` and the disk-full
`tmp/native-remote-baseline/current-app.log`, each with its actual status.
Subsequent targeted reruns fixed the first four; the disk-full attempt was
superseded by a fresh final current build. No nonzero exit was relabeled pass.

Remaining implementation-phase acceptance: direct provider invalid patch,
saved-instance mismatch and deactivation fixtures; explicit malformed JSON,
query/write failure and ordered transition/cross-workflow summary cases;
real HTTP malformed-envelope/size limits and any required additional
zero-effect assertions. Existing browser passkey tests remain intact, but this
plan's full I5/I6 matrix has not yet been completed. Keep NRE-03 in progress
until those tests and renewed final-source gates are complete. Formal
test-integrity, adversarial and Astra integration review, accepted App
baseline disposition, review-dependent design documentation, exact-file
commit and non-force push are downstream workflow steps. P1 A2/A3 remains open.

## Continuation attempt 4: I5/I6 implementation complete, formal review pending

Workflow mode remains `issue-resolution`; issue reference is local request
`comm-000002`, Draft PR #110 on `feat/native-remote-workflow-execution`.
Codex-agent `/root` owns these edits. Read-only agents `/root/test_gaps`,
`/root/source_gaps` and `/root/baseline_evidence` supplied bounded findings;
they changed no files and ran no SwiftPM commands. NRE-01/NRE-02 remain fixed
accepted prerequisites. HEAD during this attempt is `905947f947ee439abf331120e9a40727bdd70cf5`.
The source identity before this progress-only edit is in
`tmp/native-remote-receiver-20260925/NRE-03/attempt-4/source-manifest-pre-progress.json`:
tracked diff SHA-256 against `9b1c935` is
`cce8a2f5a39808472c37033767045f71ba05c2edf86d944afb1cd28388a10382`;
that manifest also hashes the untracked implementation and test files.

Only `Tests/RielaCLITests/WorkflowExecutionProviderTests.swift` and
`Tests/RielaCLITests/ServeHTTPCommandTests.swift` changed as source in this
attempt. Edit intentions and pre-edit hashes are `edit-001-intent.json` through
`edit-009-intent.json` in the attempt-4 evidence directory. The provider tests
now prove real pre-session invalid-patch, mismatched saved-instance and
deactivated-workflow rejection with no node marker or session store; strict
malformed stored JSON and query failures; post-node record-write failure with
node marker and no successful IDs; ordered session-filtered messages and node
IDs; and a real cross-workflow command fixture read by a fresh provider. The
HTTP test now exercises malformed/empty/non-object envelopes and the 2 MiB
request boundary through the production listener, asserting 400/413 and no
node or durable-store effects before the authenticated positive run. Existing
browser/profile and persisted stop-cancellation tests were retained and rerun.

Complete terminal logs and `.exit` files are under
`tmp/native-remote-receiver-20260925/NRE-03/attempt-4/`:

| Command | Log | Exit | Observed result |
| --- | --- | ---: | --- |
| `env -u RIELA_WRITE_GENERATED_SDL /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter SurfaceParityGraphQLTests` | `parity-final.log` | 0 | 6 tests, 1 skipped, 0 failures; generated source parity. |
| `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'WorkflowExecutionProviderTests\|CLIWorkflowSessionStoreResilienceTests'` | `provider-storage-final.log` | 0 | 13 tests, 0 failures. |
| `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'WorkflowExecutionGraphQLTests\|ServeHTTPCommandTests\|ServeWebHostTests\|ServerContractsTests\|RielaAppWebRegistryProviderTests\|SurfaceParity'` | `host-final.log` | 0 | 96 tests, 1 skipped, 0 failures. |
| `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build` | `build-final.log` | 0 | Source build passed. |
| `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'RielaGraphQLTests\|RielaServerTests\|RielaCLITests\|RielaAppSupportTests'` | `aggregate-final.log` | 1 | 1,469 tests, 2 skipped, 11 App assertions (1 unexpected); no new failing signatures. This is a failed aggregate, not a green gate. |
| `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH xargs -0 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < tmp/native-remote-receiver-20260925/NRE-03/attempt-4/changed-swift.nul` | `lint-final.log` | 0 | Strict selected-file lint passed for 20 Swift paths. |
| `git diff --check` | `diff-check.log` | 0 | No whitespace errors. |

The exact 11 aggregate error signatures match the preserved checkpoint
`tmp/native-remote-baseline/baseline-app.log` in
`attempt-4/aggregate-baseline-comparison.json`. This preserves the earlier
source-matched comparison and does not approve an aggregate waiver. Earlier
attempt-4 `focused-1.log` exited 1 because URLSession timed out sending the
oversized body; `http-2.log` then passed after the test sent an oversized
Content-Length through curl. `provider-2.log` and `provider-3.log` exited 1
while attempting to insert malformed JSON into a canonical SQLite table whose
generated columns reject it; `provider-4.log` passed using an isolated minimal
malformed-record fixture. `write-1.log` and `cross-1.log` passed. All earlier
nonzero exits and complete logs remain intact.

I5/I6 source, direct tests, and required behavioral verification are complete
for Step 6. Independent test-integrity, adversarial and Astra integration
reviews must decide baseline attribution and accept the combined tree with no
high/mid findings. Review-dependent receiving documentation, exact-file commit
and non-force push to the existing Draft PR #110 are downstream workflow steps.
No review or publication is claimed here; P1 A2/A3 remains separate.

## Step 8 receiving documentation and review disposition

Workflow mode remains `issue-resolution`; issue reference is `comm-000002`,
Draft PR `tacogips/riela#110` targeting `main`. The Step 6 test-integrity
gate preceded the Step 7 adversarial acceptance (`comm-000013`), and the
combined-tree Astra integration review accepted NRE-03 with no high or mid
findings. Independent review accepted the exact preimplementation baseline
attribution for the aggregate's 11 App assertions; its exit remains 1.
`step7b-e2e-evidence` (`comm-000019`) attempted
`cd web && CI=1 bun run test:e2e`, which exited 1 before tests launched:
Playwright could not write its transform cache (`EPERM`). Browser E2E remains
unavailable and was deemed non-blocking by integration review.

Step 8 refreshed `README.md`,
`design-docs/specs/design-native-remote-workflow-execution.md`, and the
directly affected packaged skills
`Resources/skills/riela-workflow-run/SKILL.md` and
`Resources/skills/riela-workflow-reference/SKILL.md`. The mandatory
`.codex/skills/riela-impl-workflow/SKILL.md` was reviewed, but this environment
denies writes to `.codex`; its NRE-03 note remains outstanding. No root
`riela-package.json` exists, so no repository-root package digest was changed.
The Step 8 `SurfaceParitySkillTests` run passed 7 tests using `swift test
--disable-sandbox --filter SurfaceParitySkillTests`; its complete log is
`tmp/native-remote-receiver-20260925/step8-docs/skill-parity-no-sandbox.log`.
`git diff --check` passed with its complete log at
`tmp/native-remote-receiver-20260925/step8-docs/diff-check.log`. Publication
to the Draft PR remains downstream; no commit or push is claimed here.

The subsequent Step 9 completion-state gate (`comm-000021`) required the three
completed NRE plans to leave `impl-plans/active/`. Step 8 moved NRE-01, NRE-02,
and NRE-03 to `impl-plans/completed/`, updated `impl-plans/README.md`, and
reconciled live links in the design and progress records. The accepted dispatch
manifest retains its original active paths as historical execution input.
The mandatory `.codex/skills/riela-impl-workflow/SKILL.md` NRE-03 update remains
open because sandbox policy rejects writes to `.codex`.
