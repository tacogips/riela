# Issue 117 implementation progress

- Workflow mode: `issue-resolution`; plan ID: `issue-117-installed-addon-metadata`.
- Issue: <https://github.com/tacogips/riela/issues/117>.
- Branch: `fix/example-contract-migration`; checkpoint: `9f53b94630e5ff591ee7a14a2e0698321022b39f`.
- Codex-agent references: `/root/review_test_paths` (read-only regression guidance; no edits). Branch test-integrity and adversarial rereview accepted in `comm-000017`; combined-tree integration review remains pending.
- Dependency admission: `dependsOn: []`, `acceptedPlanIds: []`.
- Write owner: Step 6 implementation; no other worker edited these files.

## Task status

| Task | Status | Evidence |
| --- | --- | --- |
| TASK-117-01 | completed | Real filesystem baseline `tmp/issue-117/implementation/baseline-test-2.log`: 1 selected test, 1 expected failure; scoped package ID resolved, workflow name returned `notFound("youtube-flow")`. |
| TASK-117-02 | completed | Resolver preserves verified owning manifest and package directory for installed workflow ID and direct directory. `WorkflowInstalledAddonRequirements.swift` requires unique lock and installed package/lockfile identity, version, digest, kind, scope and checksum. Native inspect uses the same match; Core guard remains. |
| TASK-117-03 | completed | After adversarial repair: 9/9 focused tests, 22/22 host tests, strict changed-file lint, build, and 87/87 CLI commands including 75/75 examples. |
| TASK-117-04 | completed | Addressed both mid findings from `comm-000013`, re-read changed files and per-edit intent snapshots, and reran final-source gates. README is accurate without edit. |
| TASK-117-05 | downstream pending | Branch test-integrity/adversarial rereview accepted in `comm-000017`; Step 8 documentation refreshed and implementation plan archived; combined-tree integration review, exact-file staging, commit, non-force push, and remote-head verification remain. |

The exact changed subset is `Sources/RielaCLI/WorkflowResolution.swift`,
`Sources/RielaCLI/WorkflowValidateInspectCommands.swift`,
`Sources/RielaCLI/WorkflowInstalledAddonRequirements.swift`,
`Tests/RielaCLITests/WorkflowInstalledAddonMetadataTests.swift`,
`Tests/RielaCLITests/WorkflowHostCapabilityTests.swift`,
`Tests/RielaCLITests/WorkflowHostCapabilityTests+AddonRequirements.swift`,
`impl-plans/completed/issue-117-installed-addon-metadata.md`, and this progress
file. `Sources/RielaWorkflowRegistry/WorkflowRegistryBundleLoader.swift`,
`Sources/RielaCore/WorkflowRequirements.swift`, `README.md`, and the design
addendum were read but need no Step 6 edit. Every edit's pre/post SHA-256,
contextual diff, and intended behavior are preserved in the numbered
`tmp/issue-117/implementation/intents/` directories; no older attempt was
overwritten.

## Verification and exit status

All commands ran in the foreground. Logs are complete and numeric `.exit`
files accompany them. The baseline is an expected reproduction failure, never
a passing current-source gate.

| Command | Exit | Count and complete log |
| --- | ---: | --- |
| `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter WorkflowInstalledAddonMetadataTests` (pre-fix baseline) | 1 | 1 test, 1 failure; `tmp/issue-117/implementation/baseline-test-2.log` |
| `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter WorkflowInstalledAddonMetadataTests` (initial implementation pass) | 0 | 8 tests, 0 failures; `tmp/issue-117/implementation/focused-test-final.log`; superseded by the 9-test final-source run below. |
| `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter WorkflowHostCapabilityTests` | 0 | 22 tests, 0 failures; `tmp/issue-117/implementation/host-test-final.log` |
| `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build` | 0 | `tmp/issue-117/implementation/build-final.log` |
| `xargs -0 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < tmp/issue-117/implementation/changed-swift.nul` with Xcode toolchain environment | 0 | Exact six changed Swift files; `tmp/issue-117/implementation/swiftlint-selected-final-2.log` |
| `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint` | 0 | 24 warnings, 0 serious across 976 files; all warnings outside changed Swift set and identical to earlier inventory; `tmp/issue-117/implementation/swiftlint-repository-final-2.log`, `tmp/issue-117/implementation/swiftlint-comparison-final.json` |
| `python3 tmp/issue-117/implementation/verify.py` | 0 | 87/87 commands, 12/12 installed native/container selections, 75/75 examples; `tmp/issue-117/implementation/driver-final-4.log`, per-command stdout/stderr/status and `tmp/issue-117/implementation/verification/attempt-4/summary.json` |

The driver uses `.build/debug/riela` from this checkout, project cwd
`tmp/issue-117/implementation/project`, and child-only HOME
`tmp/issue-117/implementation/home`. Both native and container fixtures carry
computed artifact SHA-256 and package MD5 checksums. It asserts owning package
identity, native locked content and closure digests/bundle identity, container qualified reference,
JSON parse, exit success, and no false `unresolvedAddonExecutable`.

Focused negatives assert validate and inspect failure diagnostics for copied
direct workflows; missing or unknown dependencies; ambiguous unqualified
references; wrong package identity, lockfile package version, add-on version,
digest, execution kind, and package integrity; and lower-priority user
dependency non-substitution. Positive tests cover scoped IDs, omitted node
version, direct and name selection, unique unqualified and exact qualified
references, project/user workflow collision, package/node required environment,
and callee-specific metadata. Existing host tests retain built-in,
declarative, and local-command behavior. The runner independently reports
cross-workflow transitions unsupported; the callee test verifies that the
installed callee does not add `unresolvedAddonExecutable`, while a copied
callee does.

## Self-check and downstream notes

No material issue or implementation verification gap remains. Step 8 refreshed
`README.md` and `impl-plans/README.md`; the mandatory review of
`.codex/skills/riela-impl-workflow/SKILL.md` found no directly affected
instruction. The accepted implementation plan is archived; TASK-117-05 still requires the
combined-tree review, exact-file commit, non-force push, and remote-head check. The final
changed-file strict lint is clean. Repository-wide SwiftLint's 24 warnings
are identical between the two source-adjacent inventories and none references
a changed Swift file. The design addendum records branch rereview acceptance
and pending combined-tree acceptance. No provider/model/network
call, native/container execution, package repository edit, release, merge,
Git index operation, commit, or push occurred in Step 6.

## Adversarial review repair: comm-000013

Step 7 rejected the first implementation for two mid findings. Both are repaired
within the accepted plan's write paths. `WorkflowResolution.swift` now represents
multiple verified workflow-ID matches in a scope as a deferred ambiguity candidate:
earlier candidate precedence remains available, but resolution cannot fall through
from ambiguous project packages to a user package. The focused test installs two
project packages and one user package, confirms auto validate/inspect fail with
an ambiguity diagnostic, and confirms explicit user selection still resolves.
`WorkflowInstalledAddonRequirements.swift` now requires a declared dependency
registry to equal the installed registry; the existing adjacent guard requires
the lock registry to equal the installed registry. The negative matrix confirms
both validate and inspect retain `unresolvedAddonExecutable` for a mismatch.

Final-source evidence (all numeric exits in matching `.exit` files):

| Command | Exit | Complete log and result |
| --- | ---: | --- |
| `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter WorkflowInstalledAddonMetadataTests` | 0 | `tmp/issue-117/implementation/revision-01/focused-final-2.log`; 9 tests, 0 failures. |
| `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter WorkflowHostCapabilityTests` | 0 | `tmp/issue-117/implementation/revision-01/host-final.log`; 22 tests, 0 failures. |
| `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build` | 0 | `tmp/issue-117/implementation/revision-01/build-final.log`. |
| `xargs -0 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < tmp/issue-117/implementation/revision-01/changed-swift.nul` with Xcode toolchain environment | 0 | `tmp/issue-117/implementation/revision-01/swiftlint-selected-final.log`; six selected Swift files. |
| `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint` | 0 | `tmp/issue-117/implementation/revision-01/swiftlint-repository.log`; 24 unchanged warnings, 0 serious, 976 files; diagnostic comparison `revision-01/swiftlint-comparison.json`. |
| `python3 tmp/issue-117/implementation/verify.py` | 0 | `tmp/issue-117/implementation/revision-01/driver.log`; 87/87 commands including 75 examples; `verification/attempt-5/summary.json`. |
| `git diff --check` | 0 | `tmp/issue-117/implementation/revision-01/diff-check-final-2.log`; numeric `diff-check-final-2.exit`. |

Source, lint configuration, and built CLI hashes are recorded in
`tmp/issue-117/implementation/revision-01/source-identity-final-2.json`.

The initial strict lint and compile attempts during repair failed and are retained
at `revision-01/swiftlint-selected.log` (exit 1) and
`revision-01/focused-final.log` (exit 1). The corrected final source reruns above
resolve them. Branch test-integrity and adversarial rereview in `comm-000017`
accepted the repaired implementation with no findings; the separate test-integrity
decision cites read-only Codex agent `/root/review_test_paths`. Cross-workflow
transitions remain unsupported by the runner, so focused tests cover callee-specific
requirement resolution. Combined-tree integration review and TASK-117-05 remain
downstream.
