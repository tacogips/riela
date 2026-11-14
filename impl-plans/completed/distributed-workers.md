# Distributed controller and workers — completed source implementation

Verified 2026-09-10. This record covers source changes, not a packaged release or
an update to the user's installed application. Design:
[distributed controller and workers](../../design-docs/specs/design-distributed-workers.md).
Operator instructions: [controller and worker setup](../../docs/distributed-workers.md).

## Requirements and evidence

- [x] Reference the tacogips/kestra fork. Inspected commit
  `0046dc48c4095c121c834038b13812299f65a82e`, its worker connection/job-stream
  protocols and group resolver. Adopted worker-initiated capacity-based dispatch,
  worker/group routing, results, events and cancellation; used bounded HTTP(S)
  polling with Riela's existing server instead of introducing gRPC.
- [x] Run controller and workers on separate OS instances. Actual macOS-to-Linux
  and Linux-to-macOS network execution succeeded; workers reported Darwin/Linux
  from shell execution. Linux was an ARM64 VM, not a second physical computer.
- [x] Run multiple workers and select an exact worker or group. Both were active
  in the network tests. ID and group are conjunctive when both specified; an
  unavailable explicit placement never falls back to local execution.
- [x] Embed the same controller in RielaApp and `riela serve`. The app network
  test launched RielaApp directly, without a serve subprocess or web assets.
  The reverse network test used a Linux `riela serve` controller and both workers.
- [x] Configure worker startup and connection details through files. Verified
  `worker --config`, URL/capacity/workspace settings, file-token and environment
  authentication, relative token paths and LF/CRLF endings. Workspace environment
  allowlists retain provider credentials while excluding the transport token.
- [x] Execute real node runtimes and return results/files. The final app-hosted
  network test passed six jobs: two shell commands, two production sleep-adapter
  invocations and two real `riela/kv-set` add-ons across Darwin/Linux. Returned
  files matched their bytes and SHA-256 digests in controller storage. The final
  Linux-hosted test passed two additional OS-reporting jobs with ID/group routing.
  External LLM credentials/provider connectivity were not part of this test.
- [x] Preserve durable queue, capacity, worker/lease fencing, cancellation,
  idempotence, retries, logs and artifact bounds. Regression tests cover concurrent
  clients, regenerated-timeout reattachment, stale caller cancellation, process
  tree cancellation, result acknowledgement loss, Unicode event truncation,
  snapshot failures, compaction/replay and archived artifact restoration.
- [x] Supply controller settings/status and workflow placement UI. Native settings
  and Worker Status screenshots were inspected from an isolated current debug
  executable during UI implementation. Final source comparison proved the settings
  view and status-rendering method unchanged since those images. The final binary
  created both windows with expected geometry; a final screenshot refresh was
  unavailable because macOS was screen-locked. Four current real-app tests cover
  settings layout, profile isolation, lifecycle interleavings and queue-safe saves.
  Web placement controls passed the checks below, including save/reload behavior.
- [x] Complete independent review and fix verified findings. See review details.
- [x] Document setup, authentication, workspace/environment mappings, routing,
  output transfer, failure behavior and retention/capacity limits.

## Final automated checks

macOS used Xcode's explicit Swift executable:

```sh
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'Distributed|RielaHTTPConnectionLimitTests|RielaLocalHTTPServerTests|WorkflowSessionPolicyTests'
```

Result: **60 tests passed**. Linux ran the same filter with Swift 6.2.4 on ARM64
in `swift:6.2-noble`: **56 tests passed** (four AppKit tests are macOS-only).
Linux used a separate source mirror and build directory. Both builds produced
working controller/worker executables used in the final network checks.

SwiftLint ran on all 70 changed Swift files using Xcode's `xcrun` and SDK:
exit 0. Two existing warnings remain in unrelated portions of touched CLI tests
(long type name and line length); feature code is clean. No changed Swift file
exceeds 1000 lines. `git diff --check` passed.

Web checks passed: ten targeted Bun placement/graph tests, TypeScript, ESLint and
source audit, Vite build, nine Workflow Studio Playwright tests, and a targeted
placement screenshot run. The final web source hashes exactly matched the
previously verified source snapshot. Three earlier Swift editor round-trip tests verified
that authoring read/save preserves placement and hidden environment configuration.
The authoring placement/hidden-field round-trip test was rerun after the final
validation change and passed.

## Independent review and fixes

The packaged source-security workflow completed seven parallel source reviews,
triage and adversarial verification. Its deterministic scanner initially failed
to apply the requested include/exclude parameters; those broad results were not
accepted as scoped coverage. A correctly scoped supplemental scan examined the
47 selected files: zero secret findings, zero gitleaks findings, and one HTTP URL
formatting heuristic that was not a TLS bypass. Network dependency audits were
intentionally disabled.

Verified findings and resulting fixes:

| Finding | Implemented fix and regression |
| --- | --- |
| FA-001-DOS-001 | Connection quota and absolute read deadline on Network/POSIX; idle/excess/trickling clients close and normal requests recover. |
| FA-003-01 | UTF-8 byte-bounded event truncation with final encoded-size validation; Unicode/NUL events remain deliverable. |
| FA-007-001 | One asynchronous queue serializes startup, stop, save, profile switching and shutdown; suspended-transition real-app test. |
| FA-007-002 | Persisted queue inspected even while stopped; idle check/config write share store lock; stale configurations are fenced. |
| FA-004-ENV-001 | Workspace environment allowlist, unconditional transport-token exclusion, scoped subprocess runner and controller-only workflow-creation add-on. |
| FA-002-02 | Durable attachment tokens restrict automatic cancellation to the current caller; old caller cannot cancel a reattached execution. |
| FA-002-01 | Terminal records move to digest-verified history, with admission/storage bounds and replay-safe references. |
| FA-006-LOW-001/002 | Programmatic placement validation and pre-execution rejection of remotely placed output projection. |

The review's fix-handoff node unexpectedly started a nested implementation
workflow despite the report-only constraint. The parent stopped that owned
process tree to prevent concurrent changes. Thus the overall packaged run is
**not represented as a passing security scan**. Its completed review outputs
identified the issues; the final source and targeted regressions provide the
post-fix evidence above.

## Operational boundaries

Workers need a reachable controller over HTTPS or a configured LAN/VPN. Plain
non-loopback HTTP requires explicit opt-in. Workspace mapping/environment
filtering are not an OS sandbox; code has the worker account's permissions.
Controller-local filesystem adversaries and arbitrary clock jumps are outside
the tested isolation model. Lost leases are not automatically replayed.

Each store admits 32 unfinished jobs and 10,000 total IDs; history reservation is
1 GiB and snapshot reads are capped at 512 MiB. New submissions fail clearly at
capacity while accepted work can finish. No history is silently deleted. Keep
snapshot/history/artifacts together when backing up or rotating an idle store.

## Cleanup

Stopped the owned app/review processes, unregistered the scratch app bundle, and
deleted both task-owned Linux VMs. Restored the Container service to its original
stopped state. Removed all `tmp/distributed-workers/` scratch, including runtime
logs, source mirrors and screenshots, as required by repository instructions.
Normal tool/image build caches remain. Source changes remain uncommitted for review.
