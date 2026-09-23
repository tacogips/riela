# Workflow Graph Studio acceptance audit

Date: 2026-09-10
Status: VERIFIED — required journeys and gates passed
Scope: the existing web workflow graph gains GUI authoring and live agent
authoring; definition/layout storage remains separate; the same screen launches
workflows and inspects actual execution input/output and logs.

## Requirement-by-requirement evidence

| Requirement | Authoritative evidence |
| --- | --- |
| Existing graph entry, create/edit/save/reopen | `WorkflowStudio` is entered from Command deck; `workflow-studio.spec.ts` creates two agent steps, connects them, saves twice through metadata-only mutation responses, and reopens. |
| Node settings and graph operations | Inline prompt/model controls and the file-backed settings dialog; real `WorkflowEditorDefinitionTests` edit prompts and verify the production bundle loader reads the edited payload. `graph.test.ts` covers connections, unknown fields, shared nodes, manager/fanout/resume/session guards, malformed input, and preserved explicit `stepFile` metadata. |
| Preserve existing bundles and protected values | Real editable-copy API test byte-compares original workflow/node/prompt files, checks deactivated state and duplicate rejection. Registry tests preserve retained node/step/transition fields through deletion, reject cross-node rebound/forgery/principal replay, and save a fresh revision again. |
| Separate layout data | `layout.ts` writes only browser-local, profile/origin-scoped records. Browser drag/reopen test asserts no registry write during layout changes and no positions/camera data in saved workflow JSON. Corrupt/denied storage has unit coverage. |
| Live AI graph changes, not just chat text | Strengthened `WorkflowEditorLiveAgentTests` requires a real one-step graph while generation is running, then two completed steps, actual registry registration and reopen. A first run failed this stronger check; bounded real provider rounds and event-transcript collection fixed it. The successful live rerun took 27.247 seconds. |
| Chat context, stop, Undo and recovery | Browser test checks intermediate graph while running, disabled semantic save, stop, one-boundary Undo, and prior user/assistant messages in a follow-up request. Store tests cover fragmented events, buffered-round output before the next round completes, ignored thinking, profile isolation and cancellation/late output. |
| Revision-safe save/recovery | Browser fixtures mirror the real metadata-only mutation contract. Explicit canonical refresh replaces old retain handles. Browser tests preserve drafts on conflicts, confirm discard/reload, and recover after accepted-save/read failure without duplicate registration. File-node tests reject external asset changes and stale definition replay. |
| Execute from this screen | Browser test requires saving, sends exact revision/cwd/input, opens the returned session automatically, and displays graph status. `WorkflowEditorLaunchTests` runs a real saved workflow through `WorkflowRunCommand`, rejects stale revisions before launch, and checks actual persisted results. |
| Actual I/O and logs per attempt | `WorkflowInvocationSnapshotTests` checks rendered inputs, accepted outputs, failures/retries and legacy records; real SQLite evidence API tests check exact values and profile rejection. Browser tests switch failed/successful attempts, clear stale values, retain the graph, and avoid applying another workflow's run status to it. |
| Visual usability | Inspected desktop and 390px-width screenshots plus the file-node settings dialog from Playwright. Narrow I/O stacks vertically, controls stay within the page, Fit view frames nodes, and the dialog preserves accessible labeled controls. |

The browser uses controlled API fixtures; it is not claimed to be a live native
HTTP/provider test. The separate Swift application-route, registry, runtime and
live-provider tests provide those backend contracts, including the real save
response shape and persisted assets. No provider-generated graph is treated as
valid merely because it contains two steps: the live test registers and reopens
the actual generated document.

## Gate commands

```sh
cd web
bun run typecheck
bun run lint
bun run test
bun run build
bun run test:e2e
```

From repository root:

```sh
RIELA_TEST_LIVE_EDITOR_AGENT=1 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'WorkflowEditorDefinitionTests|RielaAppWebRegistryProviderTests|WorkflowEditorLaunchTests|WorkflowEditorGenerationTests|WorkflowEditorRunEvidenceTests|RielaAppWebAPIRouteTests|WorkflowInvocationSnapshotTests|WorkflowEditorLiveAgentTests'
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --product RielaApp
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swiftlint --quiet --no-cache
git diff --check
```

Latest completed web gate: 79 unit tests and 28 browser tests; typecheck, lint
and production build passed. Repository-wide SwiftLint exited zero with
pre-existing warnings; focused lint for the changed authoring files is clean.
All changed non-generated Swift files remain below 1,000 lines. Unrelated app
menu/icon and Monja changes were preserved. Commit/push was not requested.

Final Swift gate: 38 tests passed, including the live provider test in 33.523
seconds. This repeated the prior successful strengthened live check and used
the current event-transcript fallback implementation. The final explicit
`swift build --product RielaApp` passed in 3.25 seconds. `git diff --check`
passed. No required journey remains unverified within the stated design.

## Deliberate boundaries

- Layout persistence is browser-local, not cross-device synchronization.
- One generation is bounded to 12 actual provider rounds, 600 seconds and
  1 MiB of protocol output; each round publishes a genuine intermediate result.
- The chat sends at most 12 prior user/assistant messages as context.
- Logs show the latest 500 attempts and explicitly reject per-attempt values
  above 512 KiB. Legacy missing input is marked absent, never reconstructed.
- Protected settings remain opaque unless replaced; advanced workflow/node
  JSON remains available for configuration without a specialized form.
- File-node editing creates a derived resource and retains originals; it does
  not garbage-collect prior node/prompt versions.
- `stepFile` metadata is preserved on explicit step definitions; the current
  runtime model still requires `nodeId`. The editor does not invent a different
  execution schema or a nonexistent transition `when` field.
