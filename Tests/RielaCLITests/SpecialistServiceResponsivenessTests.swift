import Crypto
import Darwin
import Foundation
import XCTest
import RielaCore
import RielaWorkflowRegistry
@testable import RielaCLI

final class SpecialistServiceResponsivenessTests: XCTestCase {
  private struct LaunchWindowFixture {
    let root: URL
    let work: URL
    let dispatchId: String
    let effect: URL
  }

  func testSupervisedMonitorFailsClosedBeforeChildNodeEffectOnCanonicalSQLiteFailure() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/specialist-supervisor/monitor-fail-closed/\(UUID().uuidString)")
    let workflow = root.appendingPathComponent("dispatch")
    let effect = root.appendingPathComponent("effect")
    try FileManager.default.createDirectory(at: workflow.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"{"workflowId":"dispatch","defaults":{"nodeTimeoutMs":1000,"maxLoopIterations":1},"entryStepId":"work","nodes":[{"id":"work","nodeFile":"nodes/work.json"}],"steps":[{"id":"work","nodeId":"work"}]}"#.utf8)
      .write(to: workflow.appendingPathComponent("workflow.json"))
    try Data(#"{"id":"work","nodeType":"command","modelFreeze":false,"command":{"executable":"/bin/sh","arguments":["-c","echo effect > \"$1\"","effect","\#(effect.path)"]}}"#.utf8)
      .write(to: workflow.appendingPathComponent("nodes/work.json"))

    let principal = SpecialistPrincipal(accountId: "account", actorId: "actor", roomId: "room")
    let store = SpecialistSupervisorStore(rootDirectory: root.path)
    let request = SpecialistRequest(requestId: "request", sourceEventId: "event", principal: principal, route: .work, body: "work")
    let task = try XCTUnwrap(try store.createTaskIfWorkRequest(request, taskId: "task"))
    let claimed = try store.claim(taskId: task.taskId, ownerId: "owner", capacity: 1, expectedVersion: task.version)
    _ = try store.reserveDispatch(taskId: claimed.taskId, dispatchId: "dispatch", childSessionId: "child", expectedVersion: claimed.version, workflowId: "dispatch", entryStepId: "work")
    _ = try store.beginDispatch(dispatchId: "dispatch")
    let control = SpecialistMonitorControl(stateRoot: root.path, dispatchId: "dispatch", childSessionId: "child")
    try control.preparePrivateStore()
    _ = try store.recordChildMonitor(dispatchId: "dispatch", processId: getpid(), receiptPath: root.appendingPathComponent("receipt").path, controlToken: control.nonce)
    let now = Date()
    try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path)).save(
      WorkflowRuntimePersistenceSnapshot(session: WorkflowSession(
        workflowId: "dispatch", sessionId: "child", status: .created, entryStepId: "work", currentStepId: "work",
        createdAt: now, updatedAt: now, rootSessionId: "child"
      ))
    )

    setenv("RIELA_ENABLE_TEST_FAILPOINTS", "1", 1)
    setenv("RIELA_TEST_FAIL_CLOSED_SQLITE_WRITE", "1", 1)
    defer {
      unsetenv("RIELA_ENABLE_TEST_FAILPOINTS")
      unsetenv("RIELA_TEST_FAIL_CLOSED_SQLITE_WRITE")
    }
    var command = WorkflowRunCommand()
    command.specialistMonitorControl = control
    let result = await command.run(WorkflowRunOptions(
      target: "dispatch",
      resolution: WorkflowResolutionOptions(workflowName: "dispatch", scope: .direct, workflowDefinitionDir: workflow.path, workingDirectory: root.path),
      sessionStore: root.path,
      workingDirectory: root.path,
      explicitWorkingDirectory: true,
      resumeSessionId: "child"
    ))
    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertFalse(FileManager.default.fileExists(atPath: effect.path), "Monitor launch must not enter a child node after canonical persistence failure")
  }

  func testFailClosedSQLitePersistenceFailurePreventsRunnerNodeEffect() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/specialist-supervisor/fail-closed/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let injector = FailClosedPersistenceFault(failAtWrite: 2)
    let runtimeStore = InMemoryWorkflowRuntimeStore()
    let durableStore = FailClosedSQLiteWorkflowRuntimeStore(
      backing: runtimeStore,
      rootDirectory: root.path,
      persistenceWriter: { snapshot in try injector.save(snapshot) }
    )
    let adapter = FailClosedEffectAdapter()
    let workflow = WorkflowDefinition(
      workflowId: "fail-closed-effect",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      entryStepId: "work",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "work-node", nodeFile: "nodes/work.json")],
      steps: [WorkflowStepRef(id: "work", nodeId: "work-node")],
      nodes: [WorkflowNodeRef(id: "work-node", nodeFile: "nodes/work.json")]
    )

    do {
      _ = try await DeterministicWorkflowRunner(store: durableStore, adapter: adapter).run(
        DeterministicWorkflowRunRequest(
          workflow: workflow,
          nodePayloads: ["work-node": AgentNodePayload(
            id: "work-node", executionBackend: .officialOpenAISDK, model: "fixture"
          )]
        )
      )
      XCTFail("The injected canonical SQLite failure must fail closed")
    } catch {
      XCTAssertTrue(String(describing: error).contains("injected SQLite persistence failure"))
    }
    let invocationCount = await adapter.invocationCount()
    XCTAssertEqual(invocationCount, 0,
                   "A failed durable running checkpoint must prevent the subsequent node effect")
    XCTAssertGreaterThanOrEqual(injector.currentWriteCount(), 2)
  }

  func testChatStatusIsDeliveredWhileActualChildCommandIsStillRunning() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/specialist-supervisor/responsiveness/\(UUID().uuidString)")
    let work = root.appendingPathComponent("work")
    let workflow = work.appendingPathComponent(".riela/workflows/held-child")
    try FileManager.default.createDirectory(at: workflow.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    defer { try? cleanup(root) }
    let barrier = root.appendingPathComponent("child-release")
    XCTAssertEqual(mkfifo(barrier.path, 0o600), 0, "Create a deterministic child-execution barrier")
    let definition = #"""
    {"workflowId":"held-child","defaults":{"nodeTimeoutMs":30000,"maxLoopIterations":1},"entryStepId":"work",
    "nodes":[{"id":"work","nodeFile":"nodes/work.json"}],"steps":[{"id":"work","nodeId":"work","role":"worker"}]}
    """#
    try Data(definition.utf8).write(to: workflow.appendingPathComponent("workflow.json"))
    let node = #"""
    {"id":"work","nodeType":"command","modelFreeze":false,
    "command":{"executable":"/bin/sh","arguments":["-c","read _ < \"$1\"","barrier","\#(barrier.path)"]}}
    """#
    try Data(node.utf8).write(to: workflow.appendingPathComponent("nodes/work.json"))
    _ = try WorkflowCompactCatalog().refresh(workingDirectory: work.path)
    let classifierOrigin = try XCTUnwrap(
      WorkflowCompactCatalog().list(workingDirectory: work.path).first { $0.workflowId == "held-child" }
    ).originId
    let classifier = """
    {"specialists":[{"id":"engineering","capacity":1,"domain":"software","allowedOriginIds":["\(classifierOrigin)"]}],
    "classifier":{"node":{"id":"planner","executionBackend":"official/openai-sdk","model":"fixture"}}}
    """
    try Data(classifier.utf8).write(to: work.appendingPathComponent("classifier.json"))
    let scenario = work.appendingPathComponent("scenario.json")
    try Data("{}".utf8).write(to: scenario)
    let transportConfig = #"""
    {"matrix":{"homeserver":"https://matrix.invalid","fixtureAccessToken":"fixture","roomId":"!room",
    "accountId":"account","localUserId":"@bot"}}
    """#
    try Data(transportConfig.utf8).write(to: work.appendingPathComponent("transport.json"))
    let registered = try WorkflowRegistryService().fetch(target: .init(workflowId: "held-child", scope: .project), workingDirectory: work.path)
    XCTAssertTrue(registered.valid, String(describing: registered))
    guard registered.valid else { return }
    let store = SpecialistSupervisorStore(rootDirectory: root.path)
    let transport = HeldChildTransport(store: store)
    let runner = SpecialistCommandRunner(classifierAdapter: HeldClassifier(), httpTransport: transport)
    let options = CLICommandOptions(scope: "specialist", command: "serve", target: nil, arguments: [
      "--state-root", root.path, "--working-dir", work.path, "--workflow", "held-child", "--variables", "{}",
      "--specialist-config", work.appendingPathComponent("classifier.json").path,
      "--transport-config", work.appendingPathComponent("transport.json").path,
      "--mock-scenario", scenario.path
    ], output: .json)
    let service = Task { await runner.run(SpecialistCommand(kind: .serve, options: options)) }
    do {
      try await transport.waitForRunningReply()
      try writeBarrier(barrier)
      try await transport.waitForTerminalReply()
    } catch {
      service.cancel()
      _ = await service.value
      throw error
    }
    let diagnostics = await transport.diagnostics()
    service.cancel()
    let result = await service.value
    XCTAssertEqual(result.exitCode, .success, "Service must remain cancellable after barrier release: \(diagnostics); \(result.stderr)")
  }

  func testIndependentPersistentWorkerConnectionsFenceTakeoverAndDoNotRelaunchLiveChild() throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/specialist-supervisor/worker-lifecycle/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let firstProcessStore = SpecialistSupervisorStore(rootDirectory: root.path)
    let restartedProcessStore = SpecialistSupervisorStore(rootDirectory: root.path)
    let started = Date(timeIntervalSince1970: 1_700_000_000)
    let firstLease = try firstProcessStore.acquireServiceLease(workerId: "worker-a", now: started, staleAfter: 30)
    XCTAssertThrowsError(try restartedProcessStore.acquireServiceLease(workerId: "worker-b", now: started.addingTimeInterval(29), staleAfter: 30))
    let replacement = try restartedProcessStore.acquireServiceLease(workerId: "worker-b", now: started.addingTimeInterval(30), staleAfter: 30)
    XCTAssertEqual(replacement.generation, firstLease.generation + 1)
    XCTAssertThrowsError(try firstProcessStore.renewServiceLease(firstLease, now: started.addingTimeInterval(31)))
    XCTAssertThrowsError(try firstProcessStore.releaseServiceLease(firstLease))

    let principal = SpecialistPrincipal(accountId: "account", actorId: "actor", roomId: "room")
    let request = SpecialistRequest(requestId: "live-request", sourceEventId: "live-event", principal: principal, route: .work, body: "work")
    let task = try XCTUnwrap(try firstProcessStore.createTaskIfWorkRequest(request, taskId: "live-task"))
    let claimed = try firstProcessStore.claim(taskId: task.taskId, ownerId: "owner", capacity: 1, expectedVersion: task.version)
    _ = try firstProcessStore.reserveDispatch(taskId: claimed.taskId, dispatchId: "live-dispatch", childSessionId: "live-child", expectedVersion: claimed.version)
    XCTAssertEqual(try firstProcessStore.beginDispatch(dispatchId: "live-dispatch").state, .running)
    XCTAssertEqual(try restartedProcessStore.recoverableDispatches().map(\.childSessionId), ["live-child"])
    XCTAssertThrowsError(try restartedProcessStore.beginDispatch(dispatchId: "live-dispatch"), "A replacement worker must attach/reconcile the live child rather than relaunch it")
  }

  func testRestartReconcilesCanonicalTerminalChildIntoTaskAndOutbox() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/specialist-supervisor/terminal-reconciliation/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = SpecialistSupervisorStore(rootDirectory: root.path)
    let principal = SpecialistPrincipal(accountId: "account", actorId: "actor", roomId: "room")
    let request = SpecialistRequest(requestId: "terminal-request", sourceEventId: "terminal-event", principal: principal, route: .work, body: "work")
    let task = try XCTUnwrap(try store.createTaskIfWorkRequest(request, taskId: "terminal-task"))
    let claimed = try store.claim(taskId: task.taskId, ownerId: "owner", capacity: 1, expectedVersion: task.version)
    let reservedTask = try store.reserveDispatch(
      taskId: claimed.taskId, dispatchId: "terminal-dispatch", childSessionId: "terminal-child",
      expectedVersion: claimed.version
    )
    let dispatch = try XCTUnwrap(try store.dispatch(dispatchId: try XCTUnwrap(reservedTask.dispatchId)))
    XCTAssertEqual(try store.beginDispatch(dispatchId: dispatch.dispatchId).state, .running)
    let completedChild = WorkflowSession(
      workflowId: "child", sessionId: dispatch.childSessionId, status: .completed,
      entryStepId: "entry", currentStepId: nil, createdAt: Date(), updatedAt: Date()
    )
    try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path)
    ).save(WorkflowRuntimePersistenceSnapshot(session: completedChild))

    let runner = SpecialistCommandRunner(classifierAdapter: HeldClassifier())
    let result = await runner.run(SpecialistCommand(kind: .serve, options: CLICommandOptions(
      scope: "specialist", command: "serve", target: nil,
      arguments: ["--state-root", root.path, "--once"], output: .json
    )))
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    XCTAssertEqual(try store.dispatch(dispatchId: dispatch.dispatchId)?.state, .terminal)
    XCTAssertEqual(try store.task(taskId: task.taskId, principal: principal)?.state, .succeeded)
    XCTAssertEqual(try store.outboxEvents(taskId: task.taskId).map(\.operation).suffix(2), ["child_terminal", "child_terminal"])
  }

  func testSubprocessServiceExclusionAndRestartUseTheDurableFence() throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/specialist-supervisor/subprocess-service/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SpecialistSupervisorStore(rootDirectory: root.path)
    let lease = try store.acquireServiceLease(workerId: "barrier-owner", staleAfter: 60)

    let blocked = try runSpecialistServiceProcess(repository: repository, stateRoot: root)
    XCTAssertNotEqual(blocked.status, 0, "A second OS process must not enter while the fenced service owner is live")

    try store.releaseServiceLease(lease)
    let restarted = try runSpecialistServiceProcess(repository: repository, stateRoot: root)
    XCTAssertEqual(restarted.status, 0, restarted.stderr)
  }

  func testBarrierHeldServiceChildSurvivesExclusionKillAndRestartWithoutRelaunch() throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/specialist-supervisor/subprocess-held-child/\(UUID().uuidString)")
    let work = root.appendingPathComponent("work")
    let workflow = work.appendingPathComponent(".riela/workflows/held-service-child")
    let ready = root.appendingPathComponent("ready")
    let release = root.appendingPathComponent("release")
    let finished = root.appendingPathComponent("finished")
    let effects = root.appendingPathComponent("effects.log")
    try FileManager.default.createDirectory(at: workflow.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    defer { try? cleanup(root) }
    XCTAssertEqual(mkfifo(ready.path, 0o666), 0)
    XCTAssertEqual(mkfifo(release.path, 0o666), 0)
    XCTAssertEqual(mkfifo(finished.path, 0o666), 0)
    let definition = #"""
    {"workflowId":"held-service-child","defaults":{"nodeTimeoutMs":30000,"maxLoopIterations":1},"entryStepId":"work",
    "nodes":[{"id":"work","nodeFile":"nodes/work.json"}],"steps":[{"id":"work","nodeId":"work","role":"worker"}]}
    """#
    try Data(definition.utf8)
      .write(to: workflow.appendingPathComponent("workflow.json"))
    let childCommand = "echo effect >> \\\"$3\\\"; echo ready > \\\"$1\\\"; " +
      "read _ < \\\"$2\\\"; echo finished > \\\"$4\\\""
    let node = """
    {"id":"work","nodeType":"command","modelFreeze":false,
    "command":{"executable":"/bin/sh","arguments":["-c","\(childCommand)","barrier",
    "\(ready.path)","\(release.path)","\(effects.path)","\(finished.path)"]}}
    """
    try Data(node.utf8).write(to: workflow.appendingPathComponent("nodes/work.json"))
    let card = try WorkflowCompactCatalog().refresh(workingDirectory: work.path).first { $0.workflowId == "held-service-child" }
    let selected = try XCTUnwrap(card)

    let store = SpecialistSupervisorStore(rootDirectory: root.path)
    let principal = SpecialistPrincipal(accountId: "account", actorId: "actor", roomId: "room")
    let request = SpecialistRequest(requestId: "held-request", sourceEventId: "held-event", principal: principal, route: .work, body: "work")
    let task = try XCTUnwrap(try store.createTaskIfWorkRequest(request, taskId: "held-task"))
    let claimed = try store.claim(taskId: task.taskId, ownerId: "owner", capacity: 1, expectedVersion: task.version)
    let dispatchId = "held-dispatch"
    let snapshot = root.appendingPathComponent("workflow-snapshots/\(dispatchId)")
    try FileManager.default.createDirectory(at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: workflow, to: snapshot)
    XCTAssertEqual(try WorkflowCompactCatalog().closureRevision(workflowDirectory: snapshot), selected.revision)
    _ = try store.reserveDispatch(
      taskId: claimed.taskId,
      dispatchId: dispatchId,
      childSessionId: "held-child-session",
      expectedVersion: claimed.version,
      workflowId: selected.workflowId,
      workflowOriginId: selected.originId,
      workflowRevision: selected.revision,
      entryStepId: "work",
      inputJSON: "{}"
    )

    let service = try startSpecialistServiceProcess(repository: repository, stateRoot: root, workingDirectory: work)
    defer { stopOwnedProcess(service, store: store, dispatchId: dispatchId) }
    // The FIFO payload is the synchronization point. The reader also has a
    // deadline and observes service exit, so fixture failures cannot hang.
    let readyData = try readBarrier(ready, service: service)
    XCTAssertEqual(String(data: readyData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), "ready")
    XCTAssertEqual(try store.dispatch(dispatchId: dispatchId)?.state, .running)

    let excluded = try runSpecialistServiceProcess(repository: repository, stateRoot: root, workingDirectory: work)
    XCTAssertNotEqual(excluded.status, 0, "A second service process must be fenced while the held child is live")

    XCTAssertEqual(kill(service.processIdentifier, SIGKILL), 0, "Kill the serving process while its child is held")
    try waitForExit(service)
    let takeover = try store.acquireServiceLease(workerId: "recovery-worker", now: Date().addingTimeInterval(121), staleAfter: 120)
    try store.releaseServiceLease(takeover)

    let restarted = try runSpecialistServiceProcess(repository: repository, stateRoot: root, workingDirectory: work)
    XCTAssertEqual(restarted.status, 0, restarted.stderr)
    let attached = try XCTUnwrap(try store.dispatch(dispatchId: dispatchId))
    XCTAssertEqual(attached.state, .running, "A restart must attach/reconcile a live child instead of relaunching it")
    XCTAssertEqual(attached.attachmentGeneration, 1, "The restarted service must durably attach its monitor lane to the held child")
    XCTAssertNotNil(attached.lastAttachedAt)
    let effectLines = try String(contentsOf: effects, encoding: .utf8).split(whereSeparator: \.isNewline)
    XCTAssertEqual(effectLines, ["effect"], "A held child must never be relaunched during worker restart")

    // The independent workflow-run monitor remains the original shell's
    // parent after the serving process dies. Releasing this barrier therefore
    // makes that monitor reap the shell and persist its terminal SQLite
    // receipt; no test code waits for or reaps the shell directly.
    try writeBarrier(release)
    let finishedData = try readBarrier(finished)
    XCTAssertEqual(String(data: finishedData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), "finished")
    try waitForCanonicalTerminalChild(stateRoot: root, sessionId: "held-child-session")
    let reconciled = try runSpecialistServiceProcess(repository: repository, stateRoot: root, workingDirectory: work)
    XCTAssertEqual(reconciled.status, 0, reconciled.stderr)
    let terminal = try XCTUnwrap(try store.dispatch(dispatchId: dispatchId))
    XCTAssertEqual(terminal.state, .terminal, "The restarted service must project the original child receipt")
    XCTAssertNil(terminal.childProcessId, "Receipt reconciliation closes the monitor handle after its original child was reaped")
    XCTAssertNotNil(terminal.childReceiptObservedAt)
    XCTAssertEqual(try store.task(taskId: claimed.taskId, principal: principal)?.state, .succeeded)
    XCTAssertEqual(try String(contentsOf: effects, encoding: .utf8).split(whereSeparator: \.isNewline), ["effect"])
  }

  func testProductionCancelTerminatesBarrierHeldDescendantAndProjectsCancelledState() throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/specialist-supervisor/production-cancel/\(UUID().uuidString)")
    let work = root.appendingPathComponent("work")
    let workflow = work.appendingPathComponent(".riela/workflows/cancellable-child")
    let ready = root.appendingPathComponent("ready")
    let release = root.appendingPathComponent("release")
    let descendantStopped = root.appendingPathComponent("descendant-stopped")
    let effects = root.appendingPathComponent("effects.log")
    try FileManager.default.createDirectory(at: workflow.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    defer { try? cleanup(root) }
    XCTAssertEqual(mkfifo(ready.path, 0o666), 0)
    XCTAssertEqual(mkfifo(release.path, 0o666), 0)
    // Keep a writer present so the shell blocks in read, where its TERM trap
    // is active, rather than waiting in an uninterruptible FIFO open.
    let releaseOwner = open(release.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
    guard releaseOwner >= 0 else { throw POSIXError(.EIO) }
    defer { close(releaseOwner) }

    let definition = #"""
    {"workflowId":"cancellable-child","defaults":{"nodeTimeoutMs":30000,"maxLoopIterations":1},"entryStepId":"work",
    "nodes":[{"id":"work","nodeFile":"nodes/work.json"}],"steps":[{"id":"work","nodeId":"work","role":"worker"}]}
    """#
    try Data(definition.utf8).write(to: workflow.appendingPathComponent("workflow.json"))
    // The grandchild is deliberately barrier-held. Its TERM trap is an
    // observable descendant-termination receipt, independent of task state.
    let command = #"""
    [ -z "${RIELA_SPECIALIST_MONITOR_CONTROL+x}" ] || exit 97
    stopped=$1; effects=$2; ready=$3; release=$4
    echo parent >> "$effects"
    echo "$$" > "$effects.pids"
    /bin/sh -c '
      stopped=$1; effects=$2; ready=$3; release=$4
      trap '\''echo stopped > "$stopped"; exit 0'\'' TERM
      echo descendant >> "$effects"
      echo "$$" >> "$effects.pids"
      echo ready > "$ready"
      read _ < "$release"
    ' descendant "$stopped" "$effects" "$ready" "$release" &
    descendant=$!
    trap 'wait "$descendant"; exit 0' TERM
    wait "$descendant"
    """#
    let node: [String: Any] = [
      "id": "work",
      "nodeType": "command",
      "modelFreeze": false,
      "command": [
        "executable": "/bin/sh",
        "arguments": ["-c", command, "barrier", descendantStopped.path, effects.path, ready.path, release.path]
      ]
    ]
    try JSONSerialization.data(withJSONObject: node).write(to: workflow.appendingPathComponent("nodes/work.json"))
    let registered = try WorkflowRegistryService().fetch(
      target: .init(workflowId: "cancellable-child", scope: .project), workingDirectory: work.path
    )
    XCTAssertTrue(registered.valid, String(describing: registered))
    let selected = try XCTUnwrap(try WorkflowCompactCatalog().refresh(workingDirectory: work.path).first {
      $0.workflowId == "cancellable-child"
    })
    XCTAssertTrue(selected.active)

    let store = SpecialistSupervisorStore(rootDirectory: root.path)
    let principal = SpecialistPrincipal(accountId: "local", actorId: "operator", roomId: "local")
    let request = SpecialistRequest(
      requestId: "cancel-request", sourceEventId: "cancel-event", principal: principal, route: .work, body: "work"
    )
    let task = try XCTUnwrap(try store.createTaskIfWorkRequest(request, taskId: "cancel-task"))
    let claimed = try store.claim(taskId: task.taskId, ownerId: "owner", capacity: 1, expectedVersion: task.version)
    let dispatchId = "cancel-dispatch"
    let snapshot = root.appendingPathComponent("workflow-snapshots/\(dispatchId)")
    try FileManager.default.createDirectory(at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: workflow, to: snapshot)
    _ = try store.reserveDispatch(
      taskId: claimed.taskId,
      dispatchId: dispatchId,
      childSessionId: "cancel-child-session",
      expectedVersion: claimed.version,
      workflowId: selected.workflowId,
      workflowOriginId: selected.originId,
      workflowRevision: selected.revision,
      entryStepId: "work",
      inputJSON: "{}"
    )

    let service = try startSpecialistServiceProcess(repository: repository, stateRoot: root, workingDirectory: work, once: true)
    defer { stopOwnedProcess(service, store: store, dispatchId: dispatchId) }
    let readyData = try readBarrier(ready, service: service)
    XCTAssertEqual(String(data: readyData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), "ready")
    XCTAssertEqual(try store.dispatch(dispatchId: dispatchId)?.state, .running)

    let cancelled = try runSpecialistCancelProcess(repository: repository, taskId: task.taskId, stateRoot: root)
    XCTAssertEqual(cancelled.status, 0, cancelled.stderr)
    XCTAssertTrue(cancelled.stdout.contains("cancel_requested"))
    try waitForExit(service)
    XCTAssertEqual(service.terminationStatus, 0, "The production service must confirm cancellation")

    XCTAssertTrue(FileManager.default.fileExists(atPath: descendantStopped.path), "Cancellation must reach the barrier-held descendant process group")
    let stoppedProcessIds = try String(contentsOfFile: effects.path + ".pids", encoding: .utf8)
      .split(whereSeparator: \.isNewline).compactMap { Int32($0) }
    XCTAssertEqual(stoppedProcessIds.count, 2)
    for processId in stoppedProcessIds {
      XCTAssertEqual(kill(processId, 0), -1, "Both the command and descendant must be reaped before the cancelled projection")
      XCTAssertEqual(errno, ESRCH)
    }
    let terminalTask = try XCTUnwrap(try store.task(taskId: task.taskId, principal: principal))
    let terminalDispatch = try XCTUnwrap(try store.dispatch(dispatchId: dispatchId))
    XCTAssertEqual(terminalTask.state, .cancelled)
    XCTAssertEqual(terminalDispatch.state, .terminal)
    XCTAssertNil(terminalDispatch.childProcessId)
    let terminalChild = try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path)
    ).load(sessionId: terminalDispatch.childSessionId)
    XCTAssertEqual(terminalChild.session.status, .failed)
    XCTAssertEqual(terminalChild.session.failureKind, .cancelled)
    XCTAssertFalse(try store.recoverableDispatches().contains { $0.dispatchId == dispatchId && $0.state == .prepared })
    XCTAssertEqual(try String(contentsOf: effects, encoding: .utf8).split(whereSeparator: \.isNewline), ["parent", "descendant"])

    let cancelledProjections = try store.outboxEvents(taskId: task.taskId).filter { $0.taskState == .cancelled }
    XCTAssertEqual(Set(cancelledProjections.map(\.destination)), Set(["chat", "tracker"]))
    XCTAssertTrue(cancelledProjections.allSatisfy { $0.operation == "child_terminal" && $0.payload.contains("cancelled") })
    let restarted = try runSpecialistServiceProcess(repository: repository, stateRoot: root, workingDirectory: work)
    XCTAssertEqual(restarted.status, 0, restarted.stderr)
    XCTAssertEqual(try String(contentsOf: effects, encoding: .utf8).split(whereSeparator: \.isNewline), ["parent", "descendant"])
  }

  func testDeadMonitorWithoutTerminalReceiptKeepsCancellationPendingForRecovery() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/specialist-supervisor/unconfirmed-cancel/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SpecialistSupervisorStore(rootDirectory: root.path)
    let principal = SpecialistPrincipal(accountId: "local", actorId: "operator", roomId: "local")
    let request = SpecialistRequest(requestId: "pending", sourceEventId: "event", principal: principal, route: .work, body: "work")
    let task = try XCTUnwrap(try store.createTaskIfWorkRequest(request, taskId: "pending-task"))
    let claimed = try store.claim(taskId: task.taskId, ownerId: "owner", capacity: 1, expectedVersion: task.version)
    _ = try store.reserveDispatch(taskId: task.taskId, dispatchId: "pending-dispatch", childSessionId: "pending-child", expectedVersion: claimed.version)
    _ = try store.beginDispatch(dispatchId: "pending-dispatch")
    let stoppedMonitor = Process()
    stoppedMonitor.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try stoppedMonitor.run()
    try waitForExit(stoppedMonitor)
    _ = try store.recordChildMonitor(dispatchId: "pending-dispatch", processId: stoppedMonitor.processIdentifier, receiptPath: root.appendingPathComponent("receipt").path)
    let running = try XCTUnwrap(try store.task(taskId: task.taskId, principal: principal))
    _ = try store.transition(taskId: task.taskId, to: .cancelRequested, expectedVersion: running.version)

    let result = await SpecialistCommandRunner().run(SpecialistCommand(kind: .serve, options: .init(
      scope: "specialist", command: "serve", target: nil, arguments: ["--state-root", root.path, "--once"], output: .json
    )))
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    XCTAssertEqual(try store.dispatch(dispatchId: "pending-dispatch")?.state, .recoveryRequired)
    XCTAssertEqual(try store.task(taskId: task.taskId, principal: principal)?.state, .cancelRequested)
    XCTAssertFalse(try store.outboxEvents(taskId: task.taskId).contains { $0.taskState == .cancelled })
  }

  func testSIGKILLEDServiceLaunchWindowsReopenOnlyFromCanonicalNoEffectEvidence() throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    for boundary in ["after-begin-dispatch", "after-process-run-before-monitor-binding"] {
      let fixture = try prepareLaunchWindowFixture(repository: repository, boundary: boundary)
      defer { try? cleanup(fixture.root) }
      let acknowledgement = fixture.root.appendingPathComponent("launch-boundary")
      let service = try startSpecialistServiceProcess(
        repository: repository, stateRoot: fixture.root, workingDirectory: fixture.work,
        launchBoundary: boundary, acknowledgement: acknowledgement
      )
      try waitForLaunchBoundary(acknowledgement, service: service)
      XCTAssertEqual(kill(service.processIdentifier, SIGKILL), 0, "Kill the actual serving supervisor at \(boundary)")
      try waitForExit(service)

      let reopenedStore = SpecialistSupervisorStore(rootDirectory: fixture.root.path)
      let afterDeath = try XCTUnwrap(try reopenedStore.dispatch(dispatchId: fixture.dispatchId))
      XCTAssertEqual(afterDeath.state, .running)
      XCTAssertNil(afterDeath.childProcessId, "The crash-window monitor was never durably bound")
      let runtime = SQLiteWorkflowRuntimePersistenceStore(
        rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: fixture.root.path)
      )
      let evidence = try runtime.load(sessionId: afterDeath.childSessionId)
      XCTAssertEqual(evidence.session.status, .created)
      XCTAssertTrue(evidence.session.executions.isEmpty, "Only canonical created/no-execution evidence may reopen this dispatch")

      // The killed process cannot release its lease. Simulate its bounded
      // expiry with the persisted-clock seam before starting a replacement.
      let expiredLease = try reopenedStore.acquireServiceLease(
        workerId: "recovery-\(boundary)", now: Date().addingTimeInterval(121), staleAfter: 120
      )
      try reopenedStore.releaseServiceLease(expiredLease)

      // First recovery pass fences the unbound launch; the second consumes the
      // canonical no-effect receipt and reopens it. Neither may execute work.
      let fenced = try runSpecialistServiceProcess(repository: repository, stateRoot: fixture.root, workingDirectory: fixture.work)
      XCTAssertEqual(fenced.status, 0, fenced.stderr)
      XCTAssertEqual(try reopenedStore.dispatch(dispatchId: fixture.dispatchId)?.state, .recoveryRequired)
      let reopened = try runSpecialistServiceProcess(repository: repository, stateRoot: fixture.root, workingDirectory: fixture.work)
      XCTAssertEqual(reopened.status, 0, reopened.stderr)
      XCTAssertEqual(try reopenedStore.dispatch(dispatchId: fixture.dispatchId)?.state, .prepared)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.effect.path), "Recovery must not claim node execution")

      let relaunched = try runSpecialistServiceProcess(repository: repository, stateRoot: fixture.root, workingDirectory: fixture.work)
      XCTAssertEqual(relaunched.status, 0, relaunched.stderr)
      XCTAssertEqual(try String(contentsOf: fixture.effect, encoding: .utf8).split(whereSeparator: \.isNewline), ["effect"])
      XCTAssertEqual(try reopenedStore.dispatch(dispatchId: fixture.dispatchId)?.state, .terminal)
    }
  }

  func testBarrierReaderReturnsWhenNoWriterEverConnects() throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/specialist-supervisor/missing-writer/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let barrier = root.appendingPathComponent("ready")
    XCTAssertEqual(mkfifo(barrier.path, 0o600), 0)
    XCTAssertThrowsError(try readBarrier(barrier, timeout: 0.05))
  }

  private func cleanup(_ root: URL) throws {
    if let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
      for case let file as URL in files where try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
      }
    }
    try FileManager.default.removeItem(at: root)
  }

  private func prepareLaunchWindowFixture(repository: URL, boundary: String) throws -> LaunchWindowFixture {
    let root = repository.appendingPathComponent("tmp/specialist-supervisor/real-launch-window/\(boundary)-\(UUID().uuidString)")
    let work = root.appendingPathComponent("work")
    let workflow = work.appendingPathComponent(".riela/workflows/launch-window")
    let effect = root.appendingPathComponent("effect")
    let dispatchId = "launch-window-dispatch"
    try FileManager.default.createDirectory(at: workflow.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    let definition = #"""
    {"workflowId":"launch-window","defaults":{"nodeTimeoutMs":30000,"maxLoopIterations":1},
    "entryStepId":"work","nodes":[{"id":"work","nodeFile":"nodes/work.json"}],
    "steps":[{"id":"work","nodeId":"work","role":"worker"}]}
    """#
    try Data(definition.utf8)
      .write(to: workflow.appendingPathComponent("workflow.json"))
    try Data(#"{"id":"work","nodeType":"command","modelFreeze":false,"command":{"executable":"/bin/sh","arguments":["-c","echo effect >> \"$1\"","effect","\#(effect.path)"]}}"#.utf8)
      .write(to: workflow.appendingPathComponent("nodes/work.json"))
    let selected = try XCTUnwrap(WorkflowCompactCatalog().refresh(workingDirectory: work.path).first { $0.workflowId == "launch-window" })
    let snapshot = root.appendingPathComponent("workflow-snapshots/\(dispatchId)")
    try FileManager.default.createDirectory(at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: workflow, to: snapshot)

    let principal = SpecialistPrincipal(accountId: "local", actorId: "operator", roomId: "local")
    let store = SpecialistSupervisorStore(rootDirectory: root.path)
    let request = SpecialistRequest(requestId: "launch-window-request", sourceEventId: "launch-window-event", principal: principal, route: .work, body: "work")
    let task = try XCTUnwrap(try store.createTaskIfWorkRequest(request, taskId: "launch-window-task"))
    let claimed = try store.claim(taskId: task.taskId, ownerId: "owner", capacity: 1, expectedVersion: task.version)
    _ = try store.reserveDispatch(
      taskId: claimed.taskId, dispatchId: dispatchId, childSessionId: "launch-window-child",
      expectedVersion: claimed.version, workflowId: selected.workflowId, workflowOriginId: selected.originId,
      workflowRevision: selected.revision, entryStepId: "work", inputJSON: "{}"
    )
    return LaunchWindowFixture(root: root, work: work, dispatchId: dispatchId, effect: effect)
  }

  private func waitForLaunchBoundary(_ acknowledgement: URL, service: Process) throws {
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
      if FileManager.default.fileExists(atPath: acknowledgement.path) { return }
      if !service.isRunning { throw processError("service exited before launch boundary") }
      Thread.sleep(forTimeInterval: 0.01)
    }
    throw processError("service did not reach requested launch boundary")
  }

  private func readBarrier(_ barrier: URL, service: Process? = nil, timeout: TimeInterval = 20) throws -> Data {
    let descriptor = open(barrier.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw POSIXError(.EIO) }
    defer { close(descriptor) }
    var data = Data()
    var bytes = [UInt8](repeating: 0, count: 256)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      let count = read(descriptor, &bytes, bytes.count)
      if count > 0 {
        data.append(contentsOf: bytes.prefix(count))
        if data.contains(10) { return data }
      } else if count < 0, errno != EAGAIN, errno != EINTR {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      if let service, !service.isRunning { throw processError("service exited before child barrier") }
      Thread.sleep(forTimeInterval: 0.01)
    }
    throw processError("service did not reach child barrier within \(timeout) seconds")
  }

  private func writeBarrier(_ barrier: URL) throws {
    let deadline = Date().addingTimeInterval(20)
    var descriptor: Int32 = -1
    repeat {
      descriptor = open(barrier.path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
      if descriptor >= 0 { break }
      guard errno == ENXIO || errno == EINTR else { throw processError("child barrier is unavailable") }
      Thread.sleep(forTimeInterval: 0.01)
    } while Date() < deadline
    guard descriptor >= 0 else { throw processError("child barrier has no live reader") }
    defer { close(descriptor) }
    _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
    XCTAssertEqual("release\n".withCString { write(descriptor, $0, 8) }, 8)
  }

  private func waitForCanonicalTerminalChild(stateRoot: URL, sessionId: String) throws {
    let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: stateRoot.path))
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
      let snapshot = try runtime.load(sessionId: sessionId)
      if snapshot.session.status == .completed || snapshot.session.status == .failed { return }
      Thread.sleep(forTimeInterval: 0.01)
    }
    throw processError("child terminal checkpoint was not persisted")
  }

  private func waitForExit(_ process: Process, timeout: TimeInterval = 30) throws {
    try WorkflowSubprocessTestSupport.waitForExit(process, timeout: timeout)
  }

  private func stopOwnedProcess(_ process: Process, store: SpecialistSupervisorStore, dispatchId: String) {
    if let dispatch = try? store.dispatch(dispatchId: dispatchId), dispatch.state == .running {
      let principal = SpecialistPrincipal(accountId: "local", actorId: "operator", roomId: "local")
      if let task = try? store.task(taskId: dispatch.taskId, principal: principal), task.state == .running {
        _ = try? store.transition(taskId: task.taskId, to: .cancelRequested, expectedVersion: task.version)
      }
      // Cleanup uses the same durable owner channel. Even test cleanup must
      // never signal a PID loaded from a record that could outlive its process.
      let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: URL(fileURLWithPath: store.databasePath).deletingLastPathComponent().path)
      let deadline = Date().addingTimeInterval(15)
      while Date() < deadline {
        if let snapshot = try? runtime.load(sessionId: dispatch.childSessionId),
           snapshot.session.status == .failed || snapshot.session.status == .completed { break }
        Thread.sleep(forTimeInterval: 0.01)
      }
    }
    if process.isRunning { process.terminate() }
    try? waitForExit(process, timeout: 3)
  }

  private func processError(_ message: String) -> NSError {
    NSError(domain: "SpecialistServiceResponsivenessTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }

  private func runSpecialistServiceProcess(repository: URL, stateRoot: URL, workingDirectory: URL? = nil) throws -> (status: Int32, stderr: String) {
    let executable = try currentSpecialistExecutable(repository: repository)
    let result = try captureProcess(executable: executable, arguments: ["specialist", "serve", "--state-root", stateRoot.path]
      + (workingDirectory.map { ["--working-dir", $0.path] } ?? [])
      + ["--once", "--output", "json"], logRoot: stateRoot)
    return (result.status, result.stderr)
  }

  private func startSpecialistServiceProcess(
    repository: URL, stateRoot: URL, workingDirectory: URL, once: Bool = false,
    launchBoundary: String? = nil, acknowledgement: URL? = nil
  ) throws -> Process {
    let executable = try currentSpecialistExecutable(repository: repository)
    let process = Process()
    process.executableURL = executable
    process.arguments = ["specialist", "serve", "--state-root", stateRoot.path, "--working-dir", workingDirectory.path]
      + (once ? ["--once"] : [])
      + ["--output", "json"]
    if let launchBoundary, let acknowledgement {
      var environment = ProcessInfo.processInfo.environment
      environment["RIELA_SPECIALIST_TEST_LAUNCH_BOUNDARY"] = launchBoundary
      environment["RIELA_SPECIALIST_TEST_LAUNCH_BOUNDARY_ACK"] = acknowledgement.path
      process.environment = environment
    }
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    try process.run()
    return process
  }

  private func runSpecialistCancelProcess(repository: URL, taskId: String, stateRoot: URL) throws -> CapturedWorkflowTestProcess {
    try captureProcess(
      executable: currentSpecialistExecutable(repository: repository),
      arguments: ["specialist", "cancel", taskId, "--state-root", stateRoot.path, "--output", "json"], logRoot: stateRoot
    )
  }

  private func captureProcess(
    executable: URL, arguments: [String], logRoot: URL, workingDirectory: URL? = nil, timeout: TimeInterval = 30
  ) throws -> CapturedWorkflowTestProcess {
    try WorkflowSubprocessTestSupport.capture(
      executable: executable, arguments: arguments, logRoot: logRoot, workingDirectory: workingDirectory, timeout: timeout
    )
  }

  /// Rebuilds the product in the active test scratch path before launching it.
  /// XCTest itself only guarantees the test bundle is current; this explicit
  /// product build prevents process-boundary tests from executing a stale
  /// `riela` binary that happens to be beside an older bundle.
  private func currentSpecialistExecutable(repository: URL) throws -> URL {
    // A distinct build tree is necessary: SwiftPM holds the test tree's
    // package lock while XCTest is executing, so rebuilding that same tree
    // from the test would deadlock. This tree is still built explicitly on
    // every process launch and is never treated as a pre-existing artifact.
    let scratch = repository.appendingPathComponent("tmp/specialist-supervisor/process-test-build")
    let swift = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
    let build = try captureProcess(executable: URL(fileURLWithPath: swift),
                                   arguments: ["build", "--product", "riela", "--scratch-path", scratch.path],
                                   logRoot: scratch.appendingPathComponent("logs"), workingDirectory: repository, timeout: 180)
    guard build.status == 0 else { throw processError("current riela product build failed: \(build.stderr)") }
    let locate = try captureProcess(executable: URL(fileURLWithPath: swift),
                                    arguments: ["build", "--show-bin-path", "--scratch-path", scratch.path],
                                    logRoot: scratch.appendingPathComponent("logs"), workingDirectory: repository)
    let directory = locate.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard locate.status == 0, !directory.isEmpty else { throw processError("current riela product path lookup failed") }
    let executable = URL(fileURLWithPath: directory).appendingPathComponent("riela")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw NSError(domain: "SpecialistServiceResponsivenessTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "current product build did not produce riela at \(executable.path)"])
    }
    return executable
  }
}

private struct HeldClassifier: NodeAdapter {
  func execute(_ input: AdapterExecutionInput, context _: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    AdapterExecutionOutput(provider: "fixture", model: "fixture", promptText: input.promptText, completionPassed: true,
                           payload: ["specialistId": .string("engineering"), "kind": .string("claim"), "reason": .string("fixture")])
  }
}

private final class FailClosedPersistenceFault: @unchecked Sendable {
  private let lock = NSLock()
  private let failAtWrite: Int
  private var writeCount = 0

  init(failAtWrite: Int) {
    self.failAtWrite = failAtWrite
  }

  func save(_: WorkflowRuntimePersistenceSnapshot) throws {
    lock.lock()
    defer { lock.unlock() }
    writeCount += 1
    guard writeCount != failAtWrite else {
      throw WorkflowRuntimePersistenceStoreError.sqliteFailed("injected SQLite persistence failure")
    }
  }

  func currentWriteCount() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return writeCount
  }
}

private actor FailClosedEffectAdapter: NodeAdapter {
  private var invocations = 0

  func execute(_ input: AdapterExecutionInput, context _: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    invocations += 1
    return AdapterExecutionOutput(
      provider: "fixture", model: "fixture", promptText: input.promptText,
      completionPassed: true, payload: ["result": .string("effect")]
    )
  }

  func invocationCount() -> Int { invocations }
}

private actor HeldChildTransport: SpecialistHTTPTransport {
  let store: SpecialistSupervisorStore
  let requestId: String
  var sentWork = false
  var sentStatus = false
  var observedRunningReply = false
  var observedTerminalReply = false

  init(store: SpecialistSupervisorStore) {
    self.store = store
    requestId = "matrix-" + SHA256.hash(data: Data("$held-work".utf8)).map { String(format: "%02x", $0) }.joined().prefix(48)
  }

  func send(url _: URL, method: String, headers _: [String: String], body: Data) async throws -> (status: Int, body: Data) {
    if method == "PUT" {
      let content = try JSONSerialization.jsonObject(with: body) as? [String: Any]
      if let text = content?["body"] as? String, text.contains("task-\(requestId): running"), try dispatchIsRunning() {
        observedRunningReply = true
      }
      if let text = content?["body"] as? String, text.contains("task-\(requestId) child") && text.contains("succeeded") {
        observedTerminalReply = true
      }
      return (200, Data(#"{"event_id":"$receipt"}"#.utf8))
    }
    let event: [String: Any]?
    if !sentWork {
      sentWork = true
      event = ["type": "m.room.message", "event_id": "$held-work", "sender": "@user", "content": ["body": "work"]]
    } else if !sentStatus, try dispatchIsRunning() {
      sentStatus = true
      event = ["type": "m.room.message", "event_id": "$status", "sender": "@user", "content": ["body": "/status"]]
    } else { event = nil }
    let page: [String: Any] = ["next_batch": "cursor", "rooms": ["join": ["!room": ["timeline": ["events": event.map { [$0] } ?? []]]]]]
    return (200, try JSONSerialization.data(withJSONObject: page))
  }

  private func dispatchIsRunning() throws -> Bool {
    guard let dispatch = try store.dispatch(dispatchId: "dispatch-\(requestId)"), dispatch.state == .running else { return false }
    let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: URL(fileURLWithPath: store.databasePath).deletingLastPathComponent().path)
    let snapshot = try runtime.load(sessionId: dispatch.childSessionId)
    return snapshot.session.status == .running && snapshot.session.executions.contains { $0.status == .running }
  }

  func waitForRunningReply() async throws {
    try await waitForReply(terminal: false)
  }

  func waitForTerminalReply() async throws {
    try await waitForReply(terminal: true)
  }

  private func waitForReply(terminal: Bool) async throws {
    let deadline = Date().addingTimeInterval(20)
    while !(terminal ? observedTerminalReply : observedRunningReply) {
      guard Date() < deadline else {
        throw NSError(domain: "HeldChildTransport", code: 1, userInfo: [NSLocalizedDescriptionKey: "reply deadline: \(diagnostics())"])
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  func diagnostics() -> String {
    let dispatch = try? store.dispatch(dispatchId: "dispatch-\(requestId)")
    return "work=\(sentWork) status=\(sentStatus) dispatch=\(String(describing: dispatch))"
  }
}
