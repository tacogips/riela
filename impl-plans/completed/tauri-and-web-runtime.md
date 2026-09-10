# Shared Tauri and browser runtime

User objective: the existing Riela web UI must work both in Tauri and in a
browser. A menu-bar RielaApp opens the Tauri window without starting a web
service; `riela serve` exposes the browser UI. Use the sibling
`/Users/taco/gits/tacogips/chilla` Tauri implementation/configuration as a reference.

## Current completion audit (2026-09-10)

- Shared Solid UI and transport are implemented. Browser uses fetch; Tauri uses
  inherited stdin/stdout IPC through RielaDesktopController. No TCP listener is
  required for the desktop window. Menu lifecycle, close/reopen and parent exit
  behavior were exercised; latest parent/child lsof and exit checks passed.
- Tauri uses chilla's startup work-area fitting, native window decorations and
  local CSP/capabilities. Current clean debug bundle rebuild passes. After macOS was unlocked,
  Computer Use verified the current instance list, Workflows navigation, graph
  node selection and Settings through native IPC. Current screenshots reviewed:
  final-native-graph.png and final-native-settings.png under the task evidence root.
- Serve hosts shared API projections, registry/configuration GraphQL, editor,
  generation, workflow runs and run evidence. Real macOS browser flows verified
  definition/copy/edit/activation/run/output and settings persistence. Public
  browser access uses explicit operator token/origin; login and mutations tested.
- Server instance controls, persisted enablement, lifecycle on profile changes,
  configuration restart and shutdown are implemented/tested. Native and server
  instance runs now receive the same session roots as their respective viewers.
- CLI archives include share/riela resources; symlink-aware installed asset and
  model catalog lookup verified from an extracted archive outside the repo.
  Debug/Cask app staging embeds Tauri, Web and Swift resources. Nested-first
  ad-hoc signing verified. Developer ID signing/notarization and publication are
  not part of the verification performed; no release was published.
- Latest targeted regressions: Swift host/desktop/editor/serve 9 passed; browser
  workflow management/authentication/instance controls 16 passed; prior focused
  instance/root tests 22 passed, Web units 87 passed, Rust placement tests 6 passed.
  SwiftLint has 34 existing warnings and no errors; frontend checks pass.
- Linux ARM64 debug build and actual authenticated browser workflow execution
  have now passed (see Linux runtime evidence below).
- Completion: every requested execution mode and discovered-definition GUI flow
  is implemented and verified. No required implementation or verification remains.

The sections below record implementation history. Later dated sections supersede
older remaining-work notes; they are evidence, not a second independent task list.

## Additional user requests completed in this work

- Workflows button failure: fixed the GraphQL validator/schema mismatch;
  actual native list and detail display verified. GraphQL registry tests: 31 pass.
- Selecting a discovered workflow must open another screen showing a node
  network, not textual Steps/Nodes lists: implemented WorkflowDefinitionView,
  definitionGraph and an encoded source-ID hash route. Lists disappear on
  navigation; Back, browser history and deep-link reload are covered by E2E.
  Graph supports node selection, directed edges/labels, zoom, pan, loops,
  external-workflow boundaries and unused nodes. Source API now includes
  toWorkflowId so cross-workflow edges are not mistaken for local edges.
- Browser workflow-management E2E: 14 pass; latest graph-specific rerun: 3 pass.
  Web unit tests: 86 pass. Swift routing + actual registry registration/read/
  revision-checked save/conflict + GraphQL/API tests: 22 pass. Rust startup
  placement tests adapted from chilla: 6 pass.
- OpsScene supports an interactive group role for accessible graph nodes.
  Definition header wraps on narrow windows. Tauri startup now fits the
  native monitor work area with chilla's tested implementation.
- Final rebuilt Tauri smoke completed: graph nodes are accessible toggle
  buttons, selecting answer-message shows node/entry/outgoing details, and
  Back to workflows restores the list. Screenshot:
  tmp/tauri-dual-runtime/graph-network.png. Minimum window size now matches
  chilla (320x240), allowing the user's tiled 628-point window to fit on-screen.
  Zoom controls are positioned at the graph's right edge, not over the nodes.
  Current app is left open on the Workflows list for the user.
- SwiftLint after all Swift edits: 34 pre-existing warnings, zero errors.

## Earlier implementation sequence (historical)

1. Nested debug bundle smoke completed: Computer Use could address
   com.tacogips.riela.desktop; Settings rendered via GraphQL, creating/switching
   an isolated profile worked. The user reported the Workflows button did
   nothing; reproduction found GraphQL validation rejected definitionRevision,
   definition and current mutation fields despite their presence in the public
   schema. Fixed WorkflowRegistryGraphQLValidation and added regression tests:
   31 GraphQL tests pass. Rebuilt/relaunched nested bundle and verified Workflows
   lists four discovered sources plus existing mutable registry entries; opening
   a discovered source renders Steps/Nodes. Current test window is intentionally
   left open for the user. A live UI registry save was not attempted because
   --home-root does not currently override CLIRuntimeEnvironment.homeDirectory
   (a separate isolation issue); a TaskLocal-isolated real registry integration
   test verifies native request registration/read/save/conflict instead.
2. Extract reusable web host/API logic from AppKit-only RielaApp into shared
   portable runtime code; reuse domain rules and authorization rather than
   duplicating handlers or returning placeholder instances. RielaAppSupport
   is mostly Foundation-based but currently has macOS guards. Workflow editor
   launch code depends on RielaCLI, which must be considered to avoid a target
   dependency cycle.
3. Wire `riela serve` to the shared web backend and default asset discovery.
   Preserve explicit web-root overrides, server lifetime/signal handling and
   security boundaries (Host/Origin/CSRF; no locally trusted GraphQL bypass
   for arbitrary remote requests).
4. Verify actual server browser UI with real isolated workflow data, including
   navigation, registry edits and run inspection. Do not treat a 200 index.html
   or fallback menu as success. Prefer macOS and Linux support unless the user
   narrows server platform scope (an optional clarification was asked).
5. Update CLI/archive asset packaging, Cask nested helper packaging/signing,
   documentation, meaningful tests and final requirement-by-requirement audit.
   Do not publish, tag or commit without a relevant request.

Existing unrelated dirty changes include workflow studio, agent authoring,
workflow snapshots and monja example work. Preserve them.

## Shared server host progress (2026-09-10)

- Moved read-only REST projections from RielaAppWebAPI to the Foundation-based
  RielaAppSupport.RielaWebAPIProjection. App now injects profile/state/runtime
  snapshots/environment; existing desktop route behavior is retained.
- Removed macOS guards from the Foundation-only model/discovery/runtime dependency
  closure (10 files). CLI depends on AppSupport; AppSupport now depends on Viewer.
  macOS compilation is verified; a Linux build remains unverified.
- ServeWebHost now reads actual profile state and discovers workflow directories
  and packages, serving bootstrap, instances, source definitions, ops and session
  projections. ServeHTTPCommand defaults to asset discovery and routes these APIs.
- Shared RielaWebRequestSecurity now protects App and loopback serve browser APIs.
  JSON media type matching is exact, and all non-GET/HEAD methods require provenance.
  Non-browser GraphQL continues through the original authenticated adapter;
  non-loopback listeners never receive local trusted browser registry authority.
- Focused Swift tests (ServeWebHost, ServeHTTPCommand, App API, native desktop):
  25 passed. Tests exercise real isolated source discovery/graph definition,
  registry query, CSRF/profile checks and unauthenticated public/CLI rejection.
- Actual `.build/debug/riela serve --host 127.0.0.1 --port 18987` browser smoke:
  real sources -> valid source graph -> node selection -> reload -> Back all passed.
  No mocked routes. Evidence in tmp/tauri-dual-runtime/serve-browser-evidence.json,
  screenshot serve-graph.png. First existing source was invalid; smoke selected a
  source with a successfully validated definition. No live registry writes performed.
- SwiftLint: 34 existing warnings, 0 errors; diff whitespace check passes.

Remaining work is substantive; do not mark complete:
1. Serve configuration provider/profile/source mutations and dynamic state refresh.
   Current host snapshots sources/state at launch, uses revision 1, and advertises
   shared bootstrap capabilities inherited from App; finish those advertised APIs.
2. Share editor/read/copy/generation/launch/run evidence handlers and connect real
   runtime control in serve, preserving revision/environment/retained-value rules.
3. Finish public-listener browser authentication without promoting remote requests
   to implicit local trust. Current nonloopback frontend API is not connected.
4. Verify session-store selection against CLI runs and add real browser mutable
   registration/save/conflict and run-inspection coverage under isolated HOME.
5. Default installed asset locations + CLI/archive and nested Cask helper packaging,
   signing assembly, docs and Linux validation. Current default web asset discovery
   covers repository/App bundles only, not installed CLI share directories.

## Server configuration progress (2026-09-10)

- ServeWebHost now implements RielaConfigurationGraphQLProviding and uses a
  composite registry/config executor. Query plus mutations for assistant,
  appearance, profiles, workflow directories, instance settings, event registration
  and configured HTTP port are connected. This supersedes the previous entry's
  snapshot-at-launch/revision-1 limitations.
- Common settings rules (assistant/model projection and updates, instance environment
  updates, revision/profile checks) moved to RielaWebConfigurationSupport; App uses
  those rules too. Appearance persistence moved to AppSupport, keeping NSAppearance
  conversion/application in the AppKit target. Event registration moved to the
  shared RielaWorkflowEventRegistration service and both hosts call it.
- Server refreshes profile/state/sources and tracks appearance/profile-list changes
  for revision checks. Configuration model-list awaits recheck revision/profile to
  avoid mixing old assistant settings with a new profile.
- Serve configured port persists separately in .riela/serve-web.json. No --port
  flag uses the saved port (or 8787). Explicit --port wins. Setting a different port
  reports restartRequired and does not disrupt the current response. Disabling the
  CLI listener via the non-UI isEnabled API returns an instruction to stop the
  process with SIGINT/SIGTERM; the Settings UI only edits configured port.
- Bootstrap hostKind differentiates `cli-serve` from `riela-app`. Settings shows correct server restart instructions.
- Fixed an older native navigation test still looking for Configure in Web Config
  after the earlier intentional Configure in Riela label change.
- Swift focused tests: 30 passed (ServeWebHost, ServeHTTPCommand, AppWebAPIRoute,
  AppSettingsEditorNavigation, Desktop). Includes isolated persistence, stale
  revision/profile rejection, source rediscovery, secret masking, event files and
  composite config/registry query. Web tests: 86 passed. Typecheck, lint, production
  build and SwiftLint (34 existing warnings, 0 errors) passed.
- Real browser test, isolated child process HOME under tmp only: profile create and
  switch, source add, source graph, native appearance preference save, configured
  port save/reload, persisted file assertions. No route mocking. Evidence:
  tmp/tauri-dual-runtime/serve-settings-evidence.json and serve-settings.png.
  Test server PID 90367 is terminated after verification; menu-bar app untouched.

Next: share/connect editor definition/copy/node settings/generation/launch/run APIs;
then public-listener browser auth, CLI session-store semantics, packaging and Linux
validation. Configuration-side updates to a running instance will also need its
runtime restart once serve instance execution is connected. Overall goal remains
active and incomplete.

## Shared editor runtime progress (2026-09-10)

- Introduced RielaWebWorkflowContext, RielaWebWorkflowRuntime and request handler
  extensions in RielaCLI. Definition/copy, node settings, generation, launch and
  recorded run evidence handlers are now shared by App and serve. Immutable
  per-request context carries profile, principal, sources, roots and environment.
  Existing App helper methods forward to the shared handlers for callers/tests.
- Shared assistant vendor/backend resolution in RielaWebAssistantProvider; the
  main App assistant also uses it. AgentGateway receives the request environment.
- Runtime retains launch task handles and generation store. Serve/App shutdown
  cancel launches and generations; launch tasks are awaited. Generation cancelAll
  leaves completed generations intact. A focused regression covers all-profile
  cancellation without changing completed results.
- Main request dispatcher scopes registry work and launched tasks to the host's
  environment. App GraphQL now also binds HOME to appHomeDirectory, fixing the
  earlier --home-root/native registry isolation discrepancy. Direct legacy App
  test helpers still execute in their caller TaskLocal scope; normal HTTP/IPC
  calls go through the shared response dispatcher.
- Added ServeWebEditorTests: real isolated copy -> activate via GraphQL -> editor
  definition -> stale launch rejection -> successful saved workflow launch ->
  actual recorded input/output -> wrong-profile evidence rejection. Initial test
  failure was a missing fixture HOME directory, not a registry/host defect.
  Fixed the fixture; removed temporary diagnostic instrumentation.
- Existing desktop editor tests pass after extraction. Focused Swift suite:
  35 passed (shared-editor-tests-final.log). Live actual Codex generation test:
  1 passed in 29.2s, intermediate one-step graph then two-step graph, validated
  registry save/reload; opt-in command recorded in shared-editor-live-agent.log.
- Real isolated server browser test (no mocks): source copied through API, opened
  in studio, description edited/saved, activated, run via UI, completed session
  shown with actual input/output and definition file verified. Evidence:
  serve-editor-evidence.json, serve-editor-run.png, serve-editor-reopened.png
  under tmp/tauri-dual-runtime. The scratch server PID 93595 is stopped afterward.
- Visual verification found Entry step select showing Choose entry for a saved
  entry. Selected option binding and explicit accessible label fix it; real
  browser reopen asserts wait and loads the completed session again. Studio E2E:
  8 passed, including the new entry-selection assertion. Frontend typecheck, lint,
  production build and SwiftLint (34 existing warnings, zero errors) passed.

Next substantive requirements: authenticated public-listener browser hosting;
installed CLI Web asset discovery/archive staging; Cask nested Tauri helper build
and signing order; Linux build verification; final real native no-listener smoke
with rebuilt bundle; complete objective audit. Check CLI default session-store
semantics and configured-instance runtime behavior against actual UI requirements.
The goal remains active; do not equate the completed local browser editor path
with completion of the remaining deployment modes and packaging.

## Installed asset packaging verification (2026-09-10)

- Shared packaging helpers build/stage Web assets, Tauri helper bundles and
  SwiftPM resource bundles. CLI archives install share/riela; formula rendering
  installs that directory. Cask stages sibling Web assets for its symlinked CLI
  and signs the nested helper before the parent app. Release compilation now
  propagates failures instead of masking them in command substitution.
- Asset discovery resolves executable symlinks and supports installed prefix,
  Cask and app layouts. Model catalog discovery supports installed resource
  bundles before the development Bundle.module fallback.
- Focused asset, serve and catalog tests: 15 passed. SwiftLint: zero errors,
  34 existing warnings. Shell syntax and diff whitespace checks passed.
- Rebuilt actual debug app with nested Tauri helper; ad-hoc nested-first signing
  and deep strict verification passed. This is not Developer ID/notarization
  verification.
- Exercised production CLI archive staging using an explicitly identified shim
  that supplies existing debug binaries. Extracted archive and launched its CLI
  via symlink from an unrelated working directory with isolated HOME. Browser
  Settings rendered with installed Web root and bundled model catalog. Evidence:
  tmp/tauri-dual-runtime/packaging/browser-evidence.json. Stopped owned test server
  PID 98052 afterward. This does not validate release optimization or cross-builds.
- README now documents manual share installation, asset lookup and Rust targets.

Remaining: public-listener browser authentication, Linux verification, final
rebuilt native no-listener smoke, and overall session-store/instance behavior
 audit. Goal remains active.

## Authenticated public browser hosting (2026-09-10)

- Public browser APIs now require explicit RIELA_WEB_TOKEN and RIELA_WEB_ORIGIN.
  ServeWebAccess validates configuration, bearer credential and configured public
  Host/Origin before granting operator access to shared browser handlers. Missing
  or invalid configuration fails closed. Loopback defaults remain local unless
  token/origin are configured. Manager/non-browser GraphQL retains its scoped
  credential adapter; browser credentials are a separate operator credential.
- Extended shared request security with an explicit origin for HTTPS proxies;
  CSRF, JSON and profile/revision validation remain enforced. Serve API responses
  use Cache-Control: no-store. Public deployments preserve Host through the proxy.
- Browser login stores the token only in page memory. Shared transport attaches it
  only to same-origin API/GraphQL calls and rejects authenticated redirects. Wrong
  token shows a visible error; reloading requires login again. Server endpoint
  labels now use the browser host instead of a hard-coded loopback address.
- Swift public-auth/host/editor suite: 7 passed; final host-only rerun after
  no-store wrapper: 6 passed. SwiftLint: 34 existing warnings, zero errors.
  Web unit suite: 87 passed; typecheck, lint, build passed. New auth E2E: 1 passed.
  Initial E2E failure was an incorrect expected Instances heading; actual page
  correctly rendered Workflow instances, and the selector was fixed.
- Actual 0.0.0.0 listener in isolated HOME: login, bad-token rejection, Settings,
  appearance mutation and persisted value after reload all verified in Chromium.
  Screenshot/evidence under tmp/tauri-dual-runtime/public-auth/. Initial scratch
  assertion expected generic Saved text instead of the real specific status;
  corrected selector and verified a dark-to-light change. Owned server PID 965
  stopped after verification. HTTPS proxy path is unit-tested for origin checking,
  not deployed or exercised end-to-end through a real proxy.
- Linux tool availability checked: Docker daemon absent; Podman default machine
  stopped, swift-s3-completion-vm lists starting but socket refuses connections
  and no hypervisor process exists. No new machine was started or reset.

Remaining: Linux build/runtime verification; final rebuilt native no-listener
smoke; session-store and configured-instance runtime audit. Goal remains active.

## Native and instance audit (2026-09-10)

- Rebuilt current debug App bundle using shared production staging helpers.
  Bundle executable timestamp (09:22) is newer than SwiftPM executable (09:21).
  Started isolated parent PID 2046 / Tauri PID 2063; later diagnostic rebuild
  started parent 2834 / child 2841. No listening TCP sockets on either process.
  SIGTERM of each parent stopped its child; final ps confirms both absent.
- Computer Use repeatedly returned cgWindowNotFound for the exact nested bundle
  and identifier. Finder capture still works. Native startup diagnostic reported
  visibility=true, position=(0,1972), outer size=2560x1540, consistent with a
  secondary monitor. Sample showed main event loop waiting normally, not a
  startup deadlock. Do not count this as a current screenshot verification.
  Temporary position/visibility logging removed; retained error reporting for
  failed show/focus instead of silently ignoring errors. Cargo fmt check and
  six startup placement tests passed. Final source differs from diagnostic
  bundle only by removal of that temporary log; next build refreshes it.
- Concrete server gap: InstancesView offers no start/stop/restart controls and
  directs users to the native menu. ServeWebHost owns an idle daemon runtime,
  never starts configured instances, and configuration changes cannot restart
  any server-owned instance. Need shared browser instance actions, actual serve
  lifecycle ownership, readiness checks, and revision/profile conflict handling.
- Runtime session-store gap: RielaAppDaemonWorkflowRuntime.startController uses
  global defaultSessionStoreRoot(), whereas shared browser projections and
  editor runs use profile session roots (or explicit serve override). Instance
  execution must receive the same root explicitly so run history is visible.
- Linux attempt: existing default Podman machine start failed terminally with
  krunkit exit 2; machine inspect confirms stopped. Docker daemon absent and no
  Swift cross SDK installed. Created isolated Podman config/data/cache under
  tmp/tauri-dual-runtime/linux-vm and started an applehv image initialization
  named riela-web-verify. Exec session 99411 owns initialization; inspect its
  current handle/log before any retry. Existing machines were not reset.

Next: finish isolated Linux VM/build verification, implement and verify instance
runtime controls/session roots, and resolve native visual capture or obtain
current equivalent UI evidence. Overall goal remains active.

Linux follow-up in the same audit turn:
- VM init session 99411 completed. First start 4876 reported success, but its
  background hypervisor died when the command context ended (subsequent inspect:
  stopped). Retried with a live holder session 16392; hypervisor PID 3634 and
  gvproxy 3633 were confirmed live, but guest entered emergency mode. Serial
  log reports ignition useradd could not lock /etc/group. Initial interrupted
  first boot may have left a lock; this is a hypothesis, not established cause.
- Stop session 98426 waited without stopping the emergency guest. Sent TERM only
  to the verified owned hypervisor, proxy and holder (3634,3633,3631). Inspect
  current machine state before retrying; prefer a fresh task-owned image and
  a persistent command context through the entire first boot.
- Linux release CI lacked Bun after the new shared Web staging requirement.
  Added Bun 1.4.2 download/install inside the Swift build container, with SHA256
  pinned to the actual downloaded official release archive. Actionlint passed.
  This checks CI syntax and artifact availability, not a Linux Swift build.

## Server instance controls and session roots (2026-09-10)

- Added authenticated POST /api/v1/instances/<encoded-id>/actions for start,
  stop, restart, enableAtLaunch and disableAtLaunch. Requests validate expected
  profile/revision; concurrent lifecycle/configuration instance operations are
  rejected. Start/stop persist active preferences and return runtime failures.
- Server-hosted Instances now exposes these controls. Native-hosted Instances
  retains existing menu-bar lifecycle management. Controls wrap on narrow views;
  empty-state guidance now points to the shared Workflows directory flow.
- Serve starts saved active+enabled instances, stops previous instances on profile
  changes, restarts running instances after configuration/event-source saves and
  stops all owned runtime work on shutdown. External profile changes are checked
  before browser dispatch; a profile/source change during start stops that start.
- RielaAppDaemonWorkflowRuntime accepts a sessionStoreRoot, retains it through
  event-source restart, and passes it into the serving request. Native start,
  restart, rename and import paths pass the selected instance profile root.
  Shared App projections/editor now use the same root helper. Serve passes its
  profile root or explicit session-store override.
- Swift tests: 22 passed, including action conflicts, real controller start/stop,
  restart, enablement/autostart, profile switch shutdown, and root preservation
  through automatic event-source restart. Initial new start fixture omitted
  required workflow.defaults; corrected the fixture after runtime diagnostics.
- Browser instance-controls E2E: 1 passed. Web unit tests: 87 passed. Typecheck,
  lint and build passed. SwiftLint: 34 existing warnings, zero errors. Changed
  Swift files remain below 1000 lines.
- Actual isolated serve/browser test: discovered a file-backed sleep workflow,
  started/restarted its instance, saved workflow variables while running and
  stopped it. Checked persisted variables and active=false after stop. Evidence:
  tmp/tauri-dual-runtime/instance-controls/browser-evidence.json and running.png.
  This is real listener/controller lifecycle evidence; this no-event fixture does
  not itself execute a workflow step. Actual step execution/output evidence is
  in the earlier shared-editor browser test. Owned server PID 6820 is stopped.

Remaining: Linux build/runtime verification, current native visual verification
(the last build's window was visible on a secondary monitor but Computer Use
could not capture it), and final objective audit across the current worktree.
Goal remains active.

## Linux ARM64 runtime verification (2026-09-10)

- Recreated only the task-owned riela-web-verify VM from a fresh applehv image.
  Kept init/start's execution context live through first boot (holder session
  48815). Linux ARM64 Podman connection succeeded. Isolated Docker credential
  config avoided an unrelated broken docker-credential-gcloud host shim.
- Built current source with official swift:6.3.3 Linux ARM64 image, libsqlite3-dev,
  and separate scratch path tmp/tauri-dual-runtime/linux-build. `swift build
  --product riela -j 4` passed in 141 seconds; CLI version is 0.1.38.
- Started that actual Linux binary in a container, bound its public listener and
  forwarded localhost port 18995. Explicit browser token/origin were configured.
  Chromium test (no mocks) covered login, instance start/stop, discovered workflow
  graph/node inspection, editable copy, graph description edit/save, activation,
  actual sleep-step execution, recorded input/output and persisted definition.
  Evidence: linux-runtime/browser-evidence.json, definition.png and run.png;
  recorded session linux-example-session-1. Screenshot reviewed.
- Stopped owned riela-linux-web container and VM cleanly after the test. No Linux
  x64 binary or release optimization was exercised by this ARM64 debug test.
- Current host regression tests: 9 passed. Browser management/auth/instance E2E:
  16 passed. Native bundle rebuilt with current instance/root changes; still no
  TCP listeners for the isolated Swift parent/Tauri child. Native screenshot
  capture remains unresolved and is being diagnosed separately.


## Final native display blocker identified (2026-09-10)

- Native diagnostics showed visible=true, activeSpace=true, miniaturized=false,
  occlusionState=visible and application hidden=false. So the earlier secondary
  monitor hypothesis did not explain the capture failure. Temporary native
  diagnostics were removed; no visibility behavior was changed to force capture.
- Both Computer Use and the UI-verification skill's window-ID screenshot method
  failed. Read-only CGSession/display inspection then confirmed
  CGSSessionScreenIsLocked=1 and zero active displays. This is the authoritative
  external blocker for current visual verification; unlocking must be done by
  the user. Do not attempt to bypass the lock or infer a successful current image.
- Latest clean bundle rebuild is being prepared/opened on isolated roots with
  --no-autostart-daemons, ready for the user to unlock. Native app was not
  published or installed into /Applications. Linux VM/server are stopped.
- Review found no additional implementation requirement beyond the pending native
  view check. Existing screenshots and native IPC tests support earlier behavior,
  but are not substituted for the blocked final current-window verification.
- Clean final bundle rebuild completed (awaiting-unlock-build.log). Current owned
  parent PID 12836 / Tauri child PID 13113, exec session 41935, use isolated
  final-native roots and one discovered test workflow. Current lsof output is
  empty (awaiting-unlock-listeners.txt). This pair is intentionally left open
  for verification after unlock. Linux holder session 48815 has been closed.


## Completion verification (2026-09-10)

macOS was unlocked and two active displays became available. The exact clean
bundle already running as parent 12836 / child 13113 was then verified through
Computer Use: Instances loaded, Workflows navigated to a dedicated discovered
Definition graph, selecting wait revealed node/entry/outgoing details, and
Settings loaded the persisted profile and assistant catalog. Settings explicitly
showed the optional Web Config server STOPPED and Bound endpoint Not running.
Final lsof confirmed zero listening TCP sockets on either process.

Reviewed screenshots: tmp/tauri-dual-runtime/final-native-graph.png and
final-native-settings.png. Latest no-listener evidence:
final-native-verified-listeners.txt (empty, expected lsof exit 1). The clean
bundle is from awaiting-unlock-build.log; no temporary native diagnostics remain.
The isolated verification window is intentionally left open for the user.
Task-owned Linux VM was removed after its successful build/runtime tests;
existing user VMs were not removed or reset.

Completion audit: Swift-owned Tauri window without a UI HTTP service; shared
browser UI through actual macOS and Linux serve; chilla-derived Tauri startup
configuration; working Workflows button; discovered selection -> GUI definition
network; editor execution/evidence; settings, authentication, instance lifecycle,
asset packaging and session-root consistency all have the evidence recorded
above. No publishing, notarization, release tagging or commits were requested
or performed. Historical unfinished notes above are superseded by this result.
