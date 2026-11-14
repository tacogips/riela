# Inspecting execution traces

Open **Run logs**, choose an instance, and open a run. **Trace timeline** displays
recorded attempts in start order on a shared time axis. Overlapping bars indicate
overlapping executions; repeated attempts remain separate rows. Equal timestamps
retain the persisted execution order. Running attempts show elapsed time, while
missing terminal timing is marked unavailable.
New SQLite execution snapshots retain millisecond timestamps. Older snapshots
remain readable, but fractional timing discarded by older versions cannot be recovered.

Expand the workflow row to show its attempts, then expand an attempt to inspect
its backend events. Select an attempt row to open its recorded **Input** and
**Output** in the side pane. Selection survives refreshes and switching views.
On narrow windows the details pane appears below the timeline.

**Graph** shows persisted step routing and provides attempt selection for the same
details pane. Routes identify destination steps, not destination execution IDs;
the display does not infer parent spans or destination attempts from timestamps.
This is an execution graph, so unexecuted definition nodes without routing evidence
are not included. The workflow definition graph remains available in Workflows.

Truncated evidence is labeled. Missing input/output records and failed value
requests appear explicitly in the pane; **Retry values** reloads a failed request.
The existing 512 KiB recorded-values API limit still applies.

## Verification

Validated with `bun run typecheck`, `bun run lint`,
`bun test src/views/traceLayout.test.ts src/views/RunDetailView.test.ts`, and
`bunx playwright test e2e/workflow-management.spec.ts --grep 'trace drilldown|opens real run detail|renders run-detail'`
from `web/`. `bun run desktop:build:debug` built the shared UI and desktop helper.

Using Xcode's Swift toolchain, `swift build --product RielaApp` and
`swift test --filter 'RielaCoreTests|RielaAppWebAPIRouteTests|WorkflowViewerTests|ServeWebEditorTests'`
passed (643 tests). SwiftLint passed for the changed Swift sources and tests.
An earlier full-core run had one fanout cancellation failure; its isolated rerun
and the final full selection both passed.

Desktop verification launched `.build/arm64-apple-macosx/debug/RielaApp` with
isolated roots and a newly copied debug Tauri helper in a temporary QA bundle.
The old `.build/debug/RielaApp.app` bundle was not used. The 13-attempt arithmetic
fixture verified preserved execution order and actual stored input/output.
The inspected temporary screenshots were `desktop-trace.png` and
`desktop-values-final.png`; test roots and captures were removed after verification.
