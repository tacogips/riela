# NRE-03: Native remote execution

```json
{
  "planId": "NRE-03",
  "planPath": "impl-plans/active/native-remote-03-provider-host-integration.md",
  "dependsOn": [
    "NRE-01",
    "NRE-02"
  ],
  "writePaths": [
    "Sources/RielaCLI/WorkflowExecutionProvider.swift",
    "Sources/RielaCLI/ServeHTTPCommand.swift",
    "Sources/RielaCLI/ServeWebHost.swift",
    "Sources/RielaApp/RielaAppWebGraphQL.swift",
    "Sources/RielaServer/ServerContracts.swift",
    "Tests/RielaCLITests/WorkflowExecutionProviderTests.swift",
    "Tests/RielaCLITests/ServeHTTPCommandTests.swift",
    "Tests/RielaCLITests/ServeWebHostTests.swift",
    "Tests/RielaServerTests/ServerContractsTests.swift",
    "Tests/RielaAppSupportTests/RielaAppWebRegistryProviderTests.swift",
    "Sources/RielaCore/SurfaceCatalog+Rows.swift",
    "Tests/RielaGraphQLTests/SurfaceParityExecutorCoverageTests.swift",
    "Tests/RielaGraphQLTests/SurfaceParityDTOSchemaTests.swift",
    "Tests/RielaGraphQLTests/GraphQLContractsTests.swift",
    "impl-plans/active/native-remote-nre-03-progress.md",
    "design-docs/specs/design-native-remote-workflow-execution.md"
  ],
  "sharedPaths": [
    "Sources/RielaCore/SurfaceCatalog+Rows.swift",
    "Tests/RielaGraphQLTests/SurfaceParityExecutorCoverageTests.swift",
    "Tests/RielaGraphQLTests/SurfaceParityDTOSchemaTests.swift",
    "Tests/RielaGraphQLTests/GraphQLContractsTests.swift"
  ],
  "progressLogPath": "impl-plans/active/native-remote-nre-03-progress.md"
}
```

## Intent, authority and boundaries

Implement the smallest Riela-owned receiving path for the existing remote CLI,
using the accepted design at `design-docs/specs/design-native-remote-workflow-execution.md`.
Mode: `planning-only` (`executionMode: design-plan-only`). Step 3 accepted the
amended design in current `comm-000004`, source execution
`step3-design-review-attempt-1-exec-4`, with no findings. Issue reference: local
request on `feat/native-remote-workflow-execution`; no GitHub issue supplied.
Issue title: Amend NRE-03 paused-result contract and aggregate verification ownership.
Codex-agent reference: `/root` — Step 6 NRE-03 integration review `comm-000039`.
Cursor CLI mapping is not applicable: this is a review reference, not a reference
repository requirement. Integration review retained NRE-01/NRE-02 acceptance;
NRE-03 remains pending. Preserve checkpoint
`72a9dae65c6ca99cd06746d2100dcf3465fc3e8f`, prior planning history and every existing
dirty/untracked implementation file.

The existing writePaths/sharedPaths and runtime change-tracking scope remain
unchanged; no additional trackedPaths or Core ownership is introduced.

This amendment authorizes planning artifacts only; no source/test edits or test
execution that mutates implementation, reset, stash, force push, or unrelated
cleanup. The implementation tasks below apply only in the later issue-resolution
run. The current workflow ends with reviewed planning publication, not fanout.
No workflow/package provenance rediscovery is required.

Non-goals: another server, runner, queue, polling protocol, credential framework,
new library facade, legacy auto-improve compatibility, client timeout forwarding,
cleanup of historical references, deployment or branch integration. Preserve
ordinary local CLI runs, existing registry/session-control contracts and browser
security. P1 A2/A3 remains open until receiving tests pass on integrated source.
No external service is a dependency or publication target.

## Same-directory execution and evidence protocol

Step 5 must accept this amended plan and dispatch manifest before the serial
workflow owner commits and non-force pushes exactly these planning artifacts:

- `design-docs/specs/design-native-remote-workflow-execution.md`
- `impl-plans/active/native-remote-03-provider-host-integration.md`
- `impl-plans/active/native-remote-receiver-20260925-dispatch.json`

Preserve checkpoint `72a9dae`, all implementation bytes and the existing untracked
progress files; never stage them with the planning commit. This node does not
commit or push. Verify the planning commit's exact file list and unchanged
implementation hashes before publication. Current publication must not dispatch
implementation; a subsequent authorized issue-resolution run may resume only
NRE-03 after verifying the published checkpoint and retained predecessor evidence.
Record commit/live remote hashes and full logs/statuses. Stop publication on any
failure or mismatch; no force push or history rewrite.

After the checkpoint commit, run these commands serially in the foreground:

```sh
git rev-parse HEAD
git push origin HEAD:refs/heads/feat/native-remote-workflow-execution
git ls-remote --exit-code origin refs/heads/feat/native-remote-workflow-execution
```

Require each command to exit 0; compare the single returned remote ref hash to
the recorded accepted checkpoint hash and confirm local HEAD still matches.
A successful push alone is insufficient evidence. Stop on any failure; never
force-push or dispatch workers while publication remains unverified.
In the later issue-resolution run, reviewed code/docs are committed and non-force
pushed by serial workflow finalization after integration and review. No worktrees, private branches,
concurrent Git operations or worker commits. NRE-01/NRE-02 are already accepted; do not redispatch them.
The remaining implementation wave contains only NRE-03, dependent on their
accepted interfaces and preserved evidence. One integration
owner runs all serial reconciliation and finalization.

Before each edit, freshly read the target and dependency interfaces, record
SHA-256 before/after (ABSENT for a new file), and save an immutable intent snapshot
under `tmp/native-remote-implementation/<planId>/<attempt>/` containing accepted
requirements, intended patch, baseline HEAD and file hashes. Do not overwrite
snapshots. Recheck the current hash immediately before applying an edit. If it
changed, reread/reconcile rather than restoring an old full-file copy. Report
drift and affected paths. After join, NRE-03 compares each worker's post-hashes
and required behaviors against the actual tree, repairs lost edits serially,
and reruns affected tests. Hash equality alone is not behavioral verification.

Each worker writes only its own progress log (path in metadata), with task ID,
state pending/in_progress/complete/blocked, changed paths, intent snapshot path,
pre/post hashes, command, log path, terminal exit status, test counts and remaining
findings. Do not mark a task complete from a partial log or skipped test. Scratch
fixtures and command logs belong under repository `tmp/`; never stage them.
The workflow is ongoing until evidence handoff; remove disposable scratch only
after its evidence is consumed. Preserve complete logs until handoff.

Run foreground commands, redirect complete stdout/stderr to a per-command log
under the attempt directory, capture the real command exit status separately
and record it with the command. Do not mask failures with pipelines. Retain and
poll any yielded session through exit. Use sequential SwiftPM commands on this
shared checkout even when source work is independent: the integration owner
serializes build/test access to `.build`. Do not start a detached test/server.
Tests own and stop their listener and await all tasks before returning.

Reserve surface catalog/index edits, lockfiles, broad formatting, global plan
archiving and final Git operations for NRE-03 serial reconciliation. No dependency
or lockfile change is expected. Keep formatting limited to changed Swift files;
follow applicable Swift skill instructions during implementation. If a required
check is blocked, report its actual error and leave completion open.

## Context and deliverables

Depends on accepted NRE-01 interfaces and NRE-02 strict reads. This plan is the
serial integration owner. The existing RielaLibrary.executeWorkflow delegates
to WorkflowRunCommand.run but forwards fewer fields than the wire contract;
call that same command directly instead of expanding the facade. The machine
serve fallback currently installs only the registry executor; browser hosts
already gate local trust. Deliver a narrow provider, host wiring, authenticated
real-HTTP evidence and combined-tree verification.

## Tasks in order

1. **I1 — Join and drift reconciliation.** Fresh-read joined contracts, strict
   store method and both worker intent/hash records. Compare every post-hash
   with the current tree; inspect differences and restore lost required behavior
   serially, never wholesale snapshots. If repair requires a NRE-01/NRE-02-owned
   file, stop for a narrowly reviewed ownership amendment; this plan grants
   no transfer of predecessor writePaths. Rerun affected targeted tests after
   an independently authorized repair. Do not edit another worker's progress log. No overlapping live writes.
2. **I2 — Provider.** Add WorkflowExecutionProvider.swift conforming to NRE-01's
   protocol. Capture immutable host resolution, working directory, environment
   and resolved store root in provider construction. Map workflowName to target
   and resolution.workflowName; instanceIdentity to instance; objects to inline
   JSON strings for variables/nodePatch; forward the four integer limits and
   disableDefaultLoopGuard. Set endpoint nil, autoImprove false, supervisorMode
   false, output .json; do not forward timeoutMs or file/mock/auth/root fields.
   Await WorkflowRunCommand.run directly using its existing resolver, instance,
   activation, patch and durable-run semantics. Decode its JSON WorkflowRunResult
   without a shell, stderr parsing or guessed session IDs. If a command returns a
   failure envelope with a session ID, strict-load that persisted result before
   mapping status/exit code; pre-session failures are GraphQL errors. Missing,
   incompatible output or failed persistence must never fabricate a payload.
   For both result and failure-envelope branches, strict-read the CLI record and
   canonical snapshot and require session/workflow identity and status agreement
   with command evidence before returning a payload. If the failure envelope lacks
   workflow identity, establish it from the two strict records; never invent it.
   Reject contradictions as WORKFLOW_EXECUTION_FAILED with bounded diagnostics.
   Preserve actual command exit code, including nonzero failure; exit code is not
   a new persisted field. Ordinary execution has no paused status: budget exhaustion
   is failed/maxStepsExceeded, cancellation is failed/cancelled. No RuntimeSession,
   runner, storage schema, status consumers or migration changes are authorized.
3. **I3 — Strict summary.** Use the NRE-02 strict CLI record read on the captured
   store; only its notFound returns nil. Load the same ID with canonical
   SQLiteWorkflowRuntimePersistenceStore.loadStrictReadOnly; after a CLI record
   exists, missing/corrupt runtime snapshots are WORKFLOW_EXECUTION_FAILED.
   Verify requested/session/workflow identities agree. Read workflowName from
   the CLI record, execution IDs from snapshot.session.executions, messages for
   this session sorted by createdOrder and nullable transitionCondition as when.
   Return actual arrays, including root-output messages; never manufacture
   counts. The remote count is the array length, not the local transient
   publishedTransitions counter (cross-workflow/fanout increments can differ).
   Use the same strict lookup before mutation returns IDs. No fallback store
   search, migration, repair or new cache. Map bounded errors without credentials,
   raw record contents, user variables, host paths or raw command stderr.
4. **I4 — Host composition.** In ServeHTTPCommand.swift compose the execution
   provider and NRE-01 wrapper around the existing composite at the CLI layer.
   Capture expected RIELA_MANAGER_AUTH_TOKEN from startup environment; absent
   configuration fails closed. Keep the original registry executor and all
   non-GraphQL routing. Do not add a RielaServer-to-RielaCLI dependency or change
   WorkflowServingController's generic lifecycle. Resolve machine working dir
   from parsed.workingDirectory/currentDirectory and store once from parsed
   sessionStore/environment via existing CLIWorkflowSessionStore resolution;
   pass that exact explicit root to both command and reader. Capture the
   resulting environment through existing CLIRuntimeEnvironment task-local
   overrides, never from request variables. The verifier owns the credential;
   do not copy the incoming bearer into run options or node environment.
   In ServeWebHost.swift add the executor after the existing browser access and
   profile gate; use its captured sessionStoreRoot and host resolution context.
   In RielaAppWebGraphQL.swift add it after RielaAppWebRouter's current security
   gate, using daemonSessionStoreRoot for the captured profile and existing app
   workflow-resolution context. Preserve the existing registry/session/console/
   configuration/routine fallback chains. Profile changes cannot redirect an
   active run's writes. Desktop remains browser-only; no machine bearer bypass.
   ServerContracts.swift normally stays unchanged: edit only if a demonstrated
   envelope regression requires a minimal fix. Authorization must precede any
   workflow/session access; execution-only bearer must never set isLocallyTrusted.
5. **I5 — Provider tests.** WorkflowExecutionProviderTests.swift uses the real
   command with deterministic test-owned workflow fixtures, without live model
   credentials. Use existing command injection/resolver seams if needed; a
   test-only initializer hook for the existing command is allowed, no new public
   runtime abstraction or remote mock option. Test every supported field and
   ordinary defaults, invalid patch, mismatched saved instance, missing/deactivated
   workflow, completed/0, persisted failure/nonzero and pre-session failure.
   Add a real two-step workflow with maxSteps=1; assert failed/maxStepsExceeded,
   nonzero exit, both persisted records and immediate summary. Pre-session failure
   must return an error without invented IDs. Controlled contradictory-result
   tests cover both decode branches and fail closed; label injected mismatch
   tests separately from real-run fixtures. Do not fabricate paused JSON or
   introduce stop-after/stop-before inputs. Retain existing resume/rerun semantics.
   Read summaries using a fresh provider over the same store. Cover real ordered
   arrays, empty arrays and cross-workflow/fanout count distinction. Corrupt a
   CLI record with valid-but-undecodable JSON while retaining its runtime snapshot:
   strict read yields sqliteFailed and GraphQL yields WORKFLOW_EXECUTION_FAILED;
   a distinct absent ID in the same database yields null without errors. Also
   cover malformed JSON, query/write failure, missing runtime snapshot and ID
   mismatches; no storage error may masquerade as absence.
6. **I6 — HTTP and security/lifecycle tests.** Extend ServeHTTPCommandTests.swift
   to start the same production composition with RielaLocalHTTPServer on an
   ephemeral loopback port and test-owned roots. If necessary extract a private/
   internal composition helper in ServeHTTPCommand.swift used by production and
   tests, rather than duplicating the executor stack. Use the actual
   URLSessionWorkflowGraphQLRunTransport with a deterministic fixture that
   produces nonzero execution/message arrays. A fast deterministic built-in or
   command fixture must pass through WorkflowRunCommand and real persistence;
   mocked mutation responses are insufficient. Assert both round trips, IDs,
   status/exit code, workflowName/ID and arrays against persisted evidence.
   Repeat requests without/wrong bearer or with absent configured token and
   spoofed manager-session/client-ID metadata; prove zero starts/reads. Through
   the same HTTP boundary test each forbidden key with false/null/true/object,
   malformed input/unknown keys, malformed envelope and request size handling.
   ServerContractsTests.swift preserves 400/413 and GraphQL error envelopes.
   Keep the full syntactic input matrix in NRE-01; HTTP tests prove actual routing.
   ServeWebHostTests.swift checks Host/Origin/CSRF/profile/passkey boundaries,
   ordinary gated execution, profile capture during a barrier-controlled run
   and independent registry/session-control access. Extend
   RielaAppWebRegistryProviderTests.swift with desktop composition/security
   source-policy assertions where direct app hosting is unavailable; label that
   limitation, do not count source assertions as real HTTP execution evidence.
   Use a barrier-controlled slow fixture to prove mutation remains pending,
   disconnect does not orphan the listener-owned route, and server.stop cancels
   and drains execution with persisted failed status and failureKind cancelled
   verified through strict reads. Do not demand an HTTP response after disconnect.
   Profile-switch barriers must prove active writes stay in the original store
   and a summary in the new profile cannot discover the old session.
   Await start/cancel/persistence/exit
   signals, not guessed sleeps. A bounded XCTest timeout fails rather than
   disguises a stuck task. No polling job, new cancellation registry or detached
   shell lifecycle. If cancellation fails, report the concrete defect for repair
   within the existing path; do not claim lifecycle acceptance.
7. **I7 — Serial catalog and combined verification.** Add executeWorkflow binding
   to the workflow.run catalog row, replacing its obsolete GraphQL exclusion.
   Add a specific summary operation binding for workflowExecution with explicit
   non-applicable surface exclusions; do not conflate it with workflowSession.
   Register the new executor fields in SurfaceParityExecutorCoverageTests without
   increasing the gap allowlist. Update only affected DTO/schema expectations in
   SurfaceParityDTOSchemaTests/GraphQLContractsTests as tests require. Run all
   commands below after drift repair; inspect every failure. Fix only material
   regressions in scope. Execute I7a below before attributing the 11 App assertions
   to baseline; no test suppression or speculative App source/test changes. Re-run affected checks after repairs and final combined gates when
   necessary. No dependency updates or broad formatting.
8. **I8 — Review/documentation handoff.** Record exact changed files, accepted
   design mapping, remaining risks, all logs/statuses and test counts in this
   plan's progress log. Independent test-integrity, adversarial and integration
   reviews of the combined tree are mandatory after implementation. Reviewers
   must inspect assertions and production composition, confirm negative cases
   have zero side effects and positive cases use the real runner and persisted
   records, and trace complete logs to the reviewed source hashes. Record each
   decision and resolve every high/mid finding, rerunning affected checks after
   repairs. Any required behavior change returns to design/plan review; it is
   not hidden in code. Refresh the native-remote design's status, receiving
   usage (serve token configuration and existing CLI endpoint/auth options),
   verified behavior and limitations from actual evidence. Keep credentials out
   of examples. Serial documentation finalization records plan outcomes; each
   worker still owns its progress log. Review README for directly affected
   claims; historical-reference cleanup remains separate, and this plan adds
   no broad README rewrite. No implementation commit/publication or A2/A3 completion claim
   before corresponding review and integrated evidence. Global archiving and
   final Git actions belong to serial workflow finalization, never workers.

## Invariants and acceptance

No unauthenticated execution or summary read; operator bearer authorizes only
execution in the fixed host store. No local-trust/registry privilege escalation.
No paused result, status enum addition, schema migration or fabricated fixture.
Command/CLI-record/runtime-snapshot status and identity must agree.
Both forbidden keys reject by presence, while ordinary requests work and local
CLI/resume/rerun remain compatible. A successful mutation returns only persisted
IDs/result; summary corruption is an error, not nil. Existing browser profile
and passkey rules remain intact. Incoming credentials never reach nodes.

Long-running semantics remain synchronous: no 202 or fabricated completion.
URLSession/proxy timeout is not a workflow timeout; a retry can create another
run. Keep those accepted limitations explicit. Server owns and drains route
work. Integration proof must use a real authenticated Riela server, not merely
executor mocks, and include unauthorized/malformed-input rejection.

## I7a — Source-matched App attribution (NRE-03 serial owner)

The complete log `tmp/native-remote-implementation/NRE-03/attempt-2/app-failures-rerun.log`
records 11 XCTest tests and 11 assertion failures (1 unexpected); review
`comm-000039` records exit 1. They span RielaAppSettingsEditorNavigationTests,
RielaAppUXOnboardingControllerTests and RielaAppWindowContentInsetTests. The trailing
Swift Testing zero-test success does not supersede XCTest failure. No source-matched
baseline result has been established.

NRE-03's serial integration owner must perform the following bounded comparison
in the next implementation run, retaining full logs and actual terminal statuses:

1. Record HEAD, dirty diff, untracked file hashes, source/test hashes, Package.resolved,
   Swift/Xcode/SDK/architecture and test environment. Freeze source during comparison.
   Export the preserved pre-implementation checkpoint `72a9dae65c6ca99cd06746d2100dcf3465fc3e8f`
   using `git archive` into repository `tmp/native-remote-baseline/source/`; verify
   exported relevant source/test hashes against the commit. Use an archive, not a
   worktree, reset, stash or edits to the current checkout. Confirm the checkpoint
   contains no NRE implementation before treating it as the baseline.
2. Build baseline and current source into distinct fresh scratch directories using
   the same toolchain, dependency versions, architecture and environment; never use
   `--skip-build` or a pre-existing App executable. Run each side once with:

   ```sh
   /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --disable-automatic-resolution --scratch-path <side-specific-build-path> --filter 'RielaAppSettingsEditorNavigationTests|RielaAppUXOnboardingControllerTests|RielaAppWindowContentInsetTests'
   ```

   Execute from the respective source root; log that root and exact expanded command.
   No lockfile/dependency changes are allowed to make the comparison pass. If fresh
   builds cannot resolve identical dependencies, report attribution blocked.
3. Compare named test/assertion signatures and counts, not just exit 1. Permit one
   additional run per side only for differing/flaky signatures. Bound each command
   to 15 minutes under a foreground owner that terminates and waits for timed-out
   work; retain timeout status, never a passing partial log. No endless reruns.
4. Identical source-matched baseline failures may be proposed to independent review
   for a named, explicit baseline disposition; they are not automatically excluded.
   New/different failures remain regressions or unresolved. If an out-of-scope fix
   is necessary, return its evidence for narrow ownership review; do not suppress
   assertions, widen writePaths or edit those three App test files speculatively.
5. Run the full aggregate command listed above on the final combined source, plus
   the NRE-03 focused/build/lint gates. No filters or skips may hide these failures.
   Record the full aggregate's real nonzero status if failures persist; acceptance
   requires either a clean gate or independent approval of individually proven
   baseline failures with all remaining tests passing. Unfinished, mismatched or
   timed-out evidence leaves the aggregate gate and NRE-03 pending.

Exact initial export commands, from the repository root (require a new empty
scratch destination; do not overwrite prior evidence):

```sh
mkdir -p tmp/native-remote-baseline/source
git archive --format=tar --output=tmp/native-remote-baseline/checkpoint.tar 72a9dae65c6ca99cd06746d2100dcf3465fc3e8f
tar -xf tmp/native-remote-baseline/checkpoint.tar -C tmp/native-remote-baseline/source
git rev-parse HEAD
git diff --binary 72a9dae65c6ca99cd06746d2100dcf3465fc3e8f
git ls-files --others --exclude-standard
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift --version
xcodebuild -version
xcrun --show-sdk-path
uname -m
```

Record SHA-256 of all compiled source/test inputs, Package.swift and
Package.resolved for both sides and verify exported bytes against `git show
72a9dae:<path>`. Inspect the checkpoint diff and absent receiver source files to
confirm a pre-implementation baseline. Record only relevant test environment
settings, never credential values. Run these exact commands serially under the
15-minute foreground deadline described above, capturing each complete log and
exit status. Baseline command cwd is `tmp/native-remote-baseline/source`:

```sh
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --disable-automatic-resolution --scratch-path ../baseline-build --filter 'RielaAppSettingsEditorNavigationTests|RielaAppUXOnboardingControllerTests|RielaAppWindowContentInsetTests'
```

Current command cwd is the repository root:

```sh
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --disable-automatic-resolution --scratch-path tmp/native-remote-baseline/current-build --filter 'RielaAppSettingsEditorNavigationTests|RielaAppUXOnboardingControllerTests|RielaAppWindowContentInsetTests'
```

If one permitted repeat is needed, use separate baseline-build-repeat/current-build-repeat
scratch paths and logs. Record test/assertion signatures and counts in the NRE-03
progress log; preserve complete output and timeout status. The final full aggregate
command in the verification section still runs without exclusions. A baseline
comparison is not a replacement for build, lint, focused tests or the full aggregate.

## Verification commands and required evidence

Run focused gates after the respective edits, then the aggregate gate after
serial join/repair. Each command gets a distinct complete log and exit status.

```sh
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'WorkflowExecutionProviderTests|CLIWorkflowSessionStoreResilienceTests'
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'WorkflowExecutionGraphQLTests|ServeHTTPCommandTests|ServeWebHostTests|ServerContractsTests|RielaAppWebRegistryProviderTests|SurfaceParity'
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'RielaGraphQLTests|RielaServerTests|RielaCLITests|RielaAppSupportTests'
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint --quiet --no-cache
git diff --check
```

Additionally run this exact changed-file strict lint gate from the repository
root after all workers stop. It includes new untracked Swift files and records
the selected paths; the command's complete log and exit status are required.
The baseline is the preserved planning commit, so the documentation checkpoint
cannot hide implementation changes. The repository-wide lint command above
retains baseline diagnostics; it does not replace this strict gate.

```sh
python3 - <<'PY'
import os
import subprocess
import sys
changed = subprocess.check_output([
    'git', 'diff', '--name-only', '--diff-filter=ACMRT', '-z', '9b1c935',
    '--', '*.swift'
])
untracked = subprocess.check_output([
    'git', 'ls-files', '--others', '--exclude-standard', '-z', '--', '*.swift'
])
paths = sorted({os.fsdecode(p) for p in (changed + untracked).split(b'\0')
                if p and os.path.isfile(os.fsdecode(p))})
if not paths:
    sys.exit('FAIL: no changed Swift files selected')
env = dict(os.environ)
env.update(DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',
           SDKROOT='/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk',
           TOOLCHAINS='com.apple.dt.toolchain.XcodeDefault')
env['PATH'] = '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:' + env.get('PATH', '')
env['SCRIPT_INPUT_FILE_COUNT'] = str(len(paths))
for index, path in enumerate(paths):
    print(path, flush=True)
    env[f'SCRIPT_INPUT_FILE_{index}'] = os.path.abspath(path)
sys.exit(subprocess.run([
    '/usr/bin/xcrun', 'swiftlint', 'lint', '--strict', '--quiet', '--no-cache',
    '--use-script-input-files'
], env=env).returncode)
PY
```

`swift build` is the Swift typecheck/compile gate including host composition;
no web code changes, so no unrelated frontend build/typecheck is required.
Tests must be discovered and executed, not just compile: capture counts and
named positive HTTP, corrupt-versus-absent, forbidden-presence and cancellation
cases. Record baseline lint diagnostics separately, never report a timed-out
lint log as passing. If macOS-only source-policy checks are the desktop evidence,
name that limit in final verification. Logs are local test evidence, not live
deployment evidence.

I1–I7 are complete only with source-matched integrated evidence and no unresolved
high/mid defect. Aggregate acceptance requires a clean run or independently
approved, individually proven baseline failures with all other tests passing;
a nonzero result stays recorded as nonzero. I8 prepares downstream reviews and
cannot self-approve them. NRE-03 remains pending until all implementation and
aggregate gates receive acceptance. This planning workflow completes only after
Step 5 acceptance and reviewed planning-only commit/non-force push. Existing
implementation remains dirty for the next issue-resolution run. P1 A2/A3 remains
open. No implementation acceptance, commit or publication is claimed here.
