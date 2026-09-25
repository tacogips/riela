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
Mode: `issue-resolution`. Current Step 3 design acceptance is `comm-000004`,
source execution `step3-design-review-attempt-1-exec-4`, decision `accepted`,
with no findings. Issue reference: local request on
`feat/native-remote-workflow-execution`; no GitHub issue URL or number supplied.
Issue title: Implement native Riela remote workflow execution receiver.
Codex-agent references: none; Cursor/reference divergence: not applicable.
Preserve planning commit `9b1c935bc7e9fe4d586142e4ead035f84ef18ee7` and its
accepted strict-decoding correction. The earlier design's `comm-000004`
revision and `comm-000006` acceptance belong to the historical planning phase;
they are not the current Step 3 review decision.

This node revises plans only. Later implementation executes the source/test tasks
below under the effective issue-resolution input. Do not edit the separate P1
checkout or remove historical references. The runner-resolved workflow provenance
is authoritative; registry rediscovery/repair is not work.

Non-goals: another server, runner, queue, polling protocol, credential framework,
new library facade, legacy auto-improve compatibility, client timeout forwarding,
cleanup of historical references, deployment or branch integration. Preserve
ordinary local CLI runs, existing registry/session-control contracts and browser
security. P1 A2/A3 remains open until receiving tests pass on integrated source.
No external service is a dependency or publication target.

## Same-directory execution and evidence protocol

Before native Riela implementation/review fanout, Step 5 must accept this revised
plan set, and the serial workflow owner must commit the accepted design update
and all revised plans on `feat/native-remote-workflow-execution`, preserving
`9b1c935`. Before dispatch, the serial owner must non-force push this checkpoint
and verify that the live remote branch hash equals the accepted checkpoint hash.
Stop dispatch if the push fails, remote verification fails, or the hashes differ;
do not start implementation/review fanout with an unpublished checkpoint. Record
the checkpoint hash, verified remote hash, commands, complete log paths and
terminal exit statuses in the implementation handoff. This keeps the checkpoint
published before the final implementation commit, satisfying the final git-push
gate's limit of one unpublished commit. Do not rewrite the earlier planning
commit. This authoring node does not commit or push.

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
Final reviewed code/docs are committed and non-force pushed by serial workflow
finalization after integration and review. No worktrees, private branches,
concurrent Git operations or worker commits. Wave 1 comprises NRE-01 and NRE-02;
wave 2 comprises NRE-03 after both pass their assigned gates. One integration
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
   file, record that repair path and responsibility transfer in this progress
   log; workers have stopped editing. Rerun that plan's targeted tests after a
   repair. Do not edit another worker's progress log. No overlapping live writes.
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
   Preserve real nonzero run exit codes and paused/failed status.
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
   workflow, successful/failed/paused persisted result and pre-session failure.
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
   and drains execution with persisted cancellation. Await start/cancel/exit
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
   regressions in scope, documenting baseline failures rather than suppressing
   tests. Re-run affected checks after repairs and final combined gates when
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
Both forbidden keys reject by presence, while ordinary requests work and local
CLI/resume/rerun remain compatible. A successful mutation returns only persisted
IDs/result; summary corruption is an error, not nil. Existing browser profile
and passkey rules remain intact. Incoming credentials never reach nodes.

Long-running semantics remain synchronous: no 202 or fabricated completion.
URLSession/proxy timeout is not a workflow timeout; a retry can create another
run. Keep those accepted limitations explicit. Server owns and drains route
work. Integration proof must use a real authenticated Riela server, not merely
executor mocks, and include unauthorized/malformed-input rejection.

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

I1–I7 are complete only with successful integrated checks and no unresolved
high/mid defect. I8 prepares evidence for downstream independent review and
documentation finalization; it cannot self-approve those review gates. The work
package completes only after required reviews accept the source-matched evidence,
reviewed code/docs are committed and non-force pushed, and the final handoff
records hashes and exact paths. Parent P1 remains open for separate merge and
cleanup. This plan-authoring node completes with all three revised plans and
its self-check; Step 5 review and the pre-fanout checkpoint remain downstream.
