import Foundation
import RielaCore
import RielaGraphQL
import RielaWork
import XCTest
@testable import RielaCLI

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class TaskRemoteTakeoverTests: XCTestCase {
  func testRemoteTakeoverUsesReservedSessionHeartbeatsAndReportsCompletedSession() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let bundle = try harness.bundle("task-handover-presence")
    let packet = try remotePacket(workflowId: bundle.workflow.workflowId, workflowDirectory: harness.examples.path)
    let transport = TaskRemoteTakeoverTestTransport(packet: packet)
    var runner = WorkflowRunCommand(resolver: TaskExampleBundleResolver(bundle: bundle))
    runner.taskNodeAdapterOverride = RemoteTakeoverNodeAdapter()
    let takeover = TaskRemoteTakeover(
      transport: transport, resolver: TaskExampleBundleResolver(bundle: bundle), runner: runner,
      hostResolver: TaskHandoverTestHostResolver()
    )
    let result = await takeover.run(remoteOptions(harness: harness, packet: packet))

    XCTAssertEqual(result.exitCode, .success, "\(result.stderr)\n\(result.stdout)")
    let snapshot = await transport.reportedSnapshot
    XCTAssertEqual(snapshot?.session.status, .completed)
    XCTAssertEqual(snapshot?.session.sessionId, "task-session-remote-successor")
    XCTAssertEqual(snapshot?.session.entryStepId, packet.contract.resumeStepId)
    let heartbeatCount = await transport.heartbeatCount
    let didReport = await transport.didReport
    XCTAssertGreaterThan(heartbeatCount, 0)
    XCTAssertTrue(didReport)
  }

  func testAnsweredQuestionRemoteTakeoverDeliversAnswerVariableAndMessage() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let bundle = try harness.bundle("task-handover-presence")
    let sourceExecution = WorkflowStepExecution(
      executionId: "source-answer-execution", stepId: "check-login", nodeId: "check-login", attempt: 1,
      status: .completed,
      acceptedOutput: WorkflowAcceptedOutputMetadata(payload: [:], when: [:], acceptedAt: Date()),
      createdAt: Date(), updatedAt: Date()
    )
    let packet = try remotePacket(
      workflowId: bundle.workflow.workflowId, workflowDirectory: harness.examples.path,
      reason: .userInputRequired(HandoverQuestion(
        id: "approval", text: "Approve?", answerSchema: ["type": .string("object")]
      )),
      history: HandoverHistoryBundle(executions: [sourceExecution], messages: [], compatibilityDigests: [:], truncated: false),
      resumeStepId: "publish"
    )
    let answeredAt = "2026-10-01T00:00:00.000Z"
    let answer = GraphQLHandoverAnswer(
      questionId: "approval", payload: ["approved": .bool(true)],
      answeredBy: ["kind": .string("human"), "principal": .string("test")], answeredAt: answeredAt
    )
    let transport = TaskRemoteTakeoverTestTransport(packet: packet, answer: answer)
    var runner = WorkflowRunCommand(resolver: TaskExampleBundleResolver(bundle: bundle))
    runner.taskNodeAdapterOverride = RemoteTakeoverNodeAdapter()
    let takeover = TaskRemoteTakeover(
      transport: transport, resolver: TaskExampleBundleResolver(bundle: bundle), runner: runner,
      hostResolver: TaskHandoverTestHostResolver()
    )
    let result = await takeover.run(remoteOptions(harness: harness, packet: packet))

    XCTAssertEqual(result.exitCode, .success, "\(result.stderr)\n\(result.stdout)")
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: harness.sessionStore.path)
    ).load(sessionId: "task-session-remote-successor")
    let resumeExecution = try XCTUnwrap(snapshot.session.executions.first { $0.stepId == packet.contract.resumeStepId })
    guard case let .object(arguments)? = resumeExecution.inputSnapshot?["arguments"],
          case let .object(handover)? = arguments["handover"],
          case let .object(answerValue)? = handover["answer"] else {
      return XCTFail("resume input did not contain handover.answer")
    }
    XCTAssertEqual(answerValue["approved"], JSONValue.bool(true))
    guard case let .object(delivered)? = arguments["delivered"],
          case let .object(deliveredHandover)? = delivered["handover"] else {
      return XCTFail("resume input did not contain delivered.handover.answer")
    }
    XCTAssertEqual(deliveredHandover["answer"], .object(["approved": .bool(true)]))
    let answerMessage = try XCTUnwrap(snapshot.workflowMessages.first {
      $0.communicationId == "handover-answer-\(packet.id.rawValue)-attempt-remote-successor"
    })
    XCTAssertEqual(answerMessage.toStepId, packet.contract.resumeStepId)
    let importedSource = try XCTUnwrap(snapshot.session.executions.first {
      $0.importedFrom?.executionId == "source-answer-execution"
    })
    XCTAssertEqual(answerMessage.sourceStepExecutionId, importedSource.executionId)
    XCTAssertEqual(answerMessage.lifecycleStatus, WorkflowMessageLifecycleStatus.delivered)
    XCTAssertEqual(answerMessage.createdAt, try XCTUnwrap(ISO8601DateFormatter.remoteTakeoverTestDate(answeredAt)))
  }

  func testUnansweredQuestionRemoteTakeoverFailsBeforeSavingOrReporting() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let bundle = try harness.bundle("task-handover-answer")
    let packet = try remotePacket(
      workflowId: bundle.workflow.workflowId, workflowDirectory: harness.examples.path,
      reason: .userInputRequired(HandoverQuestion(
        id: "q-deploy-target", text: "Choose a deployment target", answerSchema: ["type": .string("object")]
      )), resumeStepId: "apply"
    )
    let transport = TaskRemoteTakeoverTestTransport(packet: packet)
    let sessionStore = harness.sessionStore.appendingPathComponent("missing-answer-sessions", isDirectory: true)
    let takeover = TaskRemoteTakeover(
      transport: transport, resolver: TaskExampleBundleResolver(bundle: bundle),
      hostResolver: TaskHandoverTestHostResolver()
    )
    var options = remoteOptions(harness: harness, packet: packet)
    options.sessionStore = sessionStore.path
    let result = await takeover.run(options)

    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stderr.contains("missing its answer"), result.stderr)
    let didReport = await transport.didReport
    XCTAssertFalse(didReport)
    XCTAssertFalse(FileManager.default.fileExists(atPath: sessionStore.path))
  }

  func testFencedRemoteHeartbeatFailsLocalSessionWithoutReporting() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let bundle = try harness.bundle("task-handover-presence")
    let packet = try remotePacket(workflowId: bundle.workflow.workflowId, workflowDirectory: harness.examples.path)
    let transport = TaskRemoteTakeoverTestTransport(packet: packet, fenceHeartbeats: true)
    var runner = WorkflowRunCommand(resolver: TaskExampleBundleResolver(bundle: bundle))
    runner.taskNodeAdapterOverride = RemoteTakeoverNodeAdapter(delayMs: 250)
    let takeover = TaskRemoteTakeover(
      transport: transport, resolver: TaskExampleBundleResolver(bundle: bundle), runner: runner,
      hostResolver: TaskHandoverTestHostResolver()
    )
    let result = await takeover.run(remoteOptions(harness: harness, packet: packet))

    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stderr.contains("fenced out by a newer takeover"))
    let didReport = await transport.didReport
    XCTAssertFalse(didReport)
    let runtimeRoot = canonicalRuntimeStoreRoot(sessionStoreRoot: harness.sessionStore.path)
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: runtimeRoot)
      .load(sessionId: "task-session-remote-successor")
    XCTAssertEqual(snapshot.session.status, .failed)
    XCTAssertEqual(snapshot.session.failureKind, .leaseLost)
  }

  func testTaskServeRequiresTakeoverAndOnceReturnsWhenNoTasksAreEligible() async throws {
    let root = try TaskHandoverHermeticGit.makeRoot("remote-serve")
    defer { try? FileManager.default.removeItem(at: root) }
    let withoutFlag = await RielaCLIApplication().run(["task", "serve", "--once", "--working-dir", root.path])
    XCTAssertEqual(withoutFlag.exitCode, .usage)
    XCTAssertTrue(withoutFlag.stderr.contains("supports --takeover"))

    let withFlag = await RielaCLIApplication().run([
      "task", "serve", "--takeover", "--once", "--working-dir", root.path,
      "--session-store", root.appendingPathComponent("sessions").path
    ])
    XCTAssertEqual(withFlag.exitCode, .success, withFlag.stderr)
  }

  func testLocalServeOnceSkipsAnUnansweredQuestionHandover() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let task = try harness.seed("task-repair-loop", state: .waiting)
    let packet = HandoverPacket(
      id: HandoverID(rawValue: "handover-unanswered-serve-test"), taskId: task.id, intentId: task.intentId,
      fromAttemptId: AttemptID("attempt-unanswered-serve-test"), fromSessionId: "session-unanswered-serve-test",
      generation: 1, reason: .userInputRequired(HandoverQuestion(
        id: "approval", text: "Approve?", answerSchema: ["type": .string("object")]
      )),
      workflow: HandoverWorkflowRef(workflowId: "task-repair-loop", entryStepId: "start", resumeStepId: "repair"),
      progress: HandoverProgress(acceptedSteps: [], remainingSteps: ["repair"], latestGateResults: [],
        openFindings: [], evidenceSummary: [:], remainingBudget: BudgetSnapshot(attemptsUsed: 0, tokensUsed: 0, wallClockMsUsed: 0)),
      history: HandoverHistoryBundle(executions: [], messages: [], compatibilityDigests: [:], truncated: false),
      contract: HandoverContinuationContract(resumeStepId: "repair", completion: task.completion,
        verification: [], guardPolicy: task.guardPolicy), brief: "Waiting for an answer", producedBy: .runtime,
      producedOn: "test", createdAt: Date()
    )
    try harness.store.saveHandover(packet.sealed())
    let result = await RielaCLIApplication().run([
      "task", "serve", "--takeover", "--once", "--traits", "userReachable",
      "--scope", "project", "--working-dir", harness.repository.path, "--session-store", harness.sessionStore.path
    ])
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    XCTAssertEqual(try harness.store.listAttempts(taskId: task.id), [])
  }

  func testEndpointWithForceOrphanIsRejectedBeforeLocalLookup() async {
    let result = await RielaCLIApplication().run([
      "task", "takeover", "missing-task", "--endpoint", "https://controller.invalid/graphql", "--force-orphan"
    ])
    XCTAssertEqual(result.exitCode, .usage)
    XCTAssertTrue(result.stderr.contains("cannot be combined"))
  }

  func testURLTransportUsesManagerAuthorizationHeaders() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TaskRemoteTakeoverURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    TaskRemoteTakeoverURLProtocol.reset()
    let result = try await URLSessionTaskHandoverGraphQLTransport(session: session).execute(
      endpoint: "https://controller.invalid/graphql", query: "query { status }", variables: [:],
      auth: TaskRemoteAuth(token: "manager-secret", managerSessionId: "manager-session")
    )
    XCTAssertEqual(result["ok"], .bool(true))
    let headers = try XCTUnwrap(TaskRemoteTakeoverURLProtocol.lastHeaders)
    XCTAssertEqual(headers["Authorization"], "Bearer manager-secret")
    XCTAssertEqual(headers["X-Riela-Manager-Session-Id"], "manager-session")
  }

  func testInProcessTransportExecutesGraphQLDocument() async throws {
    let executor = TaskRemoteTakeoverStubExecutor()
    let result = try await InProcessTaskHandoverGraphQLTransport(executor: executor).execute(
      endpoint: "in-process", query: "query { marker }", variables: ["id": .string("task-1")], auth: TaskRemoteAuth()
    )
    XCTAssertEqual(result["marker"], .string("handled"))
    let request = await executor.lastRequest
    XCTAssertEqual(request?.query, "query { marker }")
    XCTAssertEqual(request?.variables["id"], .string("task-1"))
  }

  func testSecondCloneMaterializesPublishedTaskBranch() async throws {
    let fixture = try TaskHandoverRepositoryFixture()
    defer { fixture.remove() }
    let branch = "riela/task/task-remote/g2"
    _ = try fixture.git(["checkout", "-b", branch])
    try fixture.write("successor", to: "handover.txt")
    _ = try fixture.git(["add", "--", "handover.txt"])
    _ = try fixture.git(["-c", "user.name=Riela Test", "-c", "user.email=riela-test@example.invalid", "commit", "-m", "handover"])
    _ = try fixture.git(["push", "origin", "HEAD:refs/heads/\(branch)"])
    let publishedSHA = try fixture.git(["rev-parse", "HEAD"])
    let successor = try fixture.secondClone()
    let deliverable = RepositoryDeliverable(
      root: fixture.clone.path, remote: fixture.bareRemote.absoluteString, branch: branch,
      baseRevision: fixture.baseRevision, headCommit: publishedSHA, state: .published
    )
    let workspace = GitBranchWorkspaceRuntime(
      git: FoundationGitCommandRunner(), environment: fixture.gitEnvironment
    )
    let isolation = try await workspace.materialize(
      deliverable, into: successor.path, worktree: false, attempt: AttemptID("attempt-remote-successor")
    )
    XCTAssertEqual(try fixture.git(["-C", isolation.path, "rev-parse", "HEAD"], at: URL(fileURLWithPath: isolation.path)), publishedSHA)
    XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: isolation.path).appendingPathComponent("handover.txt"), encoding: .utf8), "successor")
  }

  // MARK: Provider-backed end-to-end (controller A over the real GraphQL executor and provider)

  func testRemoteTakeoverOverProviderReconcilesControllerTaskWithDirector() async throws {
    let controller = try TaskExampleHarness()
    defer { controller.remove() }
    let sealed = try await sealPresenceHandover(controller)
    let executor = TaskRemoteTakeoverControllerExecutor(controller: controller)
    let successorRoot = try Self.makeSuccessorRoot()
    defer { try? FileManager.default.removeItem(at: successorRoot) }
    let bundle = try controller.bundle("task-handover-presence")
    var runner = WorkflowRunCommand(resolver: TaskExampleBundleResolver(bundle: bundle))
    runner.taskNodeAdapterOverride = RemoteTakeoverNodeAdapter()
    let takeover = TaskRemoteTakeover(
      transport: InProcessTaskHandoverGraphQLTransport(executor: executor),
      resolver: TaskExampleBundleResolver(bundle: bundle), runner: runner,
      hostResolver: TaskHandoverTestHostResolver(traits: [.userReachable])
    )
    let successorStore = successorRoot.appendingPathComponent("sessions", isDirectory: true)
    XCTAssertNotEqual(successorStore.path, controller.sessionStore.path)
    let attemptsBefore = try controller.store.listAttempts(taskId: sealed.task.id)
    let result = await takeover.run(providerOptions(
      sealed, traits: [.userReachable], root: successorRoot, sessionStore: successorStore
    ))

    if Self.isPendingSchemaRegistration(result.stderr) {
      XCTExpectFailure(Self.pendingSchemaRegistrationMessage) {
        XCTFail(result.stderr)
      }
      XCTAssertEqual(try controller.store.listAttempts(taskId: sealed.task.id), attemptsBefore)
      return
    }
    XCTAssertEqual(result.exitCode, .success, "\(result.stderr)\n\(result.stdout)")
    XCTAssertEqual(try controller.store.loadTask(id: sealed.task.id)?.state, .succeeded)
    let attempts = try controller.store.listAttempts(taskId: sealed.task.id)
    XCTAssertEqual(attempts.count, 2)
    let successor = try XCTUnwrap(attempts.last)
    XCTAssertNotEqual(successor.id, sealed.predecessorId)
    XCTAssertEqual(
      successor.entry, .takeover(fromAttemptId: sealed.predecessorId, handoverId: sealed.packet.id)
    )
    let decisions = try controller.store.listDecisions(taskId: sealed.task.id)
    XCTAssertTrue(
      decisions.contains { $0.attemptId == successor.id && $0.kind.kindName == "accept" },
      "the controller director must accept the reported successor attempt: \(decisions.map(\.kind.kindName))"
    )
    let heartbeats = await executor.heartbeatBodies
    XCTAssertFalse(heartbeats.isEmpty)
    XCTAssertTrue(heartbeats.contains { body in
      guard body["errors"] == nil, case let .object(data)? = body["data"],
            case let .object(payload)? = data["heartbeatAttempt"],
            payload["fenced"] == .bool(false), case .string? = payload["expiresAt"],
            case let .array(errors)? = payload["errors"] else { return false }
      return errors.isEmpty
    }, "expected an unfenced heartbeat response with expiresAt and no errors: \(heartbeats)")
    let output = try JSONDecoder().decode(JSONObject.self, from: Data(result.stdout.utf8))
    XCTAssertEqual(output["controllerTaskState"], .string("succeeded"))
    XCTAssertEqual(output["attemptId"], .string(successor.id.rawValue))
    let successorSnapshot = try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: successorStore.path)
    ).load(sessionId: successor.sessionId)
    XCTAssertEqual(successorSnapshot.session.status, .completed)
  }

  func testRemoteTakeoverOverProviderRefusesHostWithoutRequiredTraits() async throws {
    let controller = try TaskExampleHarness()
    defer { controller.remove() }
    let sealed = try await sealPresenceHandover(controller)
    let executor = TaskRemoteTakeoverControllerExecutor(controller: controller)
    let successorRoot = try Self.makeSuccessorRoot()
    defer { try? FileManager.default.removeItem(at: successorRoot) }
    let bundle = try controller.bundle("task-handover-presence")
    var runner = WorkflowRunCommand(resolver: TaskExampleBundleResolver(bundle: bundle))
    runner.taskNodeAdapterOverride = RemoteTakeoverNodeAdapter()
    let takeover = TaskRemoteTakeover(
      transport: InProcessTaskHandoverGraphQLTransport(executor: executor),
      resolver: TaskExampleBundleResolver(bundle: bundle), runner: runner,
      hostResolver: TaskHandoverTestHostResolver()
    )
    let attemptsBefore = try controller.store.listAttempts(taskId: sealed.task.id)
    let result = await takeover.run(providerOptions(
      sealed, traits: [], root: successorRoot,
      sessionStore: successorRoot.appendingPathComponent("sessions", isDirectory: true)
    ))

    if Self.isPendingSchemaRegistration(result.stderr) {
      XCTExpectFailure(Self.pendingSchemaRegistrationMessage) {
        XCTFail(result.stderr)
      }
      XCTAssertEqual(try controller.store.listAttempts(taskId: sealed.task.id), attemptsBefore)
      return
    }
    XCTAssertEqual(result.exitCode, .failure, "\(result.stderr)\n\(result.stdout)")
    XCTAssertTrue(result.stderr.contains("host-traits-unavailable"), result.stderr)
    XCTAssertEqual(try controller.store.listAttempts(taskId: sealed.task.id), attemptsBefore)
    XCTAssertEqual(attemptsBefore.count, 1)
    XCTAssertNotEqual(try controller.store.loadTask(id: sealed.task.id)?.state, .succeeded)
    let heartbeats = await executor.heartbeatBodies
    XCTAssertTrue(heartbeats.isEmpty)
  }

  func testRemoteTakeoverOverProviderDeliversAnsweredQuestion() async throws {
    let controller = try TaskExampleHarness()
    defer { controller.remove() }
    let task = try controller.seed("task-handover-answer")
    let name = "task-handover-answer"
    let bundle = try controller.bundle(name)
    let resolver = TaskExampleBundleResolver(bundle: bundle)
    let dispatch = TaskDispatch(
      resolver: resolver,
      hostResolver: RemoteTakeoverDispatchHostResolver(),
      runner: WorkflowRunCommand(resolver: resolver),
      mockScenarioPath: controller.examples.appendingPathComponent(name)
        .appendingPathComponent("mock-scenario.json").path
    )
    let suspended = await dispatch.run(
      taskId: task.id.rawValue,
      options: TaskStoreOptions(scope: .project, workingDirectory: controller.repository.path,
                                sessionStore: controller.sessionStore.path),
      dryRun: false, output: .json
    )
    XCTAssertEqual(suspended.exitCode, .suspended, "\(suspended.stderr)\n\(suspended.stdout)")
    let packet = try XCTUnwrap(controller.store.latestHandover(taskId: task.id))
    guard case .userInputRequired = packet.reason else { return XCTFail("expected an S1 handover") }
    let provider = TaskHandoverGraphQLProvider(
      workingDirectory: controller.repository.path, sessionStore: controller.sessionStore.path, scope: .project
    )
    _ = try await provider.answerTask(
      GraphQLAnswerTaskInput(taskId: task.id.rawValue, questionId: "q-deploy-target", answer: ["option": .string("staging")], principal: "qa"),
      context: GraphQLDocumentRequest(query: "mutation { answerTask }", isLocallyTrusted: true,
                                      localWorkingDirectory: controller.repository.path)
    )
    let executor = TaskRemoteTakeoverControllerExecutor(controller: controller)
    let successorRoot = try Self.makeSuccessorRoot()
    defer { try? FileManager.default.removeItem(at: successorRoot) }
    var successorRunner = WorkflowRunCommand(resolver: resolver)
    successorRunner.taskNodeAdapterOverride = RemoteTakeoverNodeAdapter()
    let takeover = TaskRemoteTakeover(
      transport: InProcessTaskHandoverGraphQLTransport(executor: executor), resolver: resolver,
      runner: successorRunner, hostResolver: TaskHandoverTestHostResolver()
    )
    let sessionStore = successorRoot.appendingPathComponent("sessions", isDirectory: true)
    let attemptsBefore = try controller.store.listAttempts(taskId: task.id)
    let result = await takeover.run(TaskRemoteTakeoverOptions(
      taskId: task.id.rawValue, handoverId: packet.id.rawValue, endpoint: "in-process", auth: TaskRemoteAuth(),
      traits: [], workingDirectory: successorRoot.path, cloneInto: nil, sessionStore: sessionStore.path,
      scope: .project, output: .json
    ))

    if Self.isPendingSchemaRegistration(result.stderr) {
      XCTExpectFailure(Self.pendingSchemaRegistrationMessage) { XCTFail(result.stderr) }
      XCTAssertEqual(try controller.store.listAttempts(taskId: task.id), attemptsBefore)
      return
    }
    XCTAssertEqual(result.exitCode, .success, "\(result.stderr)\n\(result.stdout)")
    XCTAssertEqual(try controller.store.loadTask(id: task.id)?.state, .succeeded)
    let attempts = try controller.store.listAttempts(taskId: task.id)
    XCTAssertEqual(attempts.count, 2)
    let successor = try XCTUnwrap(attempts.last)
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStore.path)
    ).load(sessionId: successor.sessionId)
    let resumeExecution = try XCTUnwrap(snapshot.session.executions.first { $0.stepId == packet.contract.resumeStepId })
    guard case let .object(arguments)? = resumeExecution.inputSnapshot?["arguments"],
          case let .object(handover)? = arguments["handover"],
          case let .object(answerValue)? = handover["answer"] else {
      return XCTFail("resume input did not contain handover.answer")
    }
    XCTAssertEqual(answerValue["option"], JSONValue.string("staging"))
    XCTAssertTrue(snapshot.workflowMessages.contains {
      $0.communicationId == "handover-answer-\(packet.id.rawValue)-\(successor.id.rawValue)"
        && $0.toStepId == packet.contract.resumeStepId && $0.lifecycleStatus == .delivered
    })
  }

  // MARK: Repository path through TaskRemoteTakeover (hermetic temp repo + local bare remote)

  func testRemoteTakeoverMaterializesCommitsAndPublishesRepositoryBeforeReporting() async throws {
    let fixture = try TaskHandoverRepositoryFixture()
    defer { fixture.remove() }
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let branch = "riela/task/task-remote/g2"
    let publishedSHA = try Self.publishBranch(branch, in: fixture)
    let successor = try fixture.secondClone()
    _ = try fixture.git(["config", "user.name", "Riela Test"], at: successor)
    _ = try fixture.git(["config", "user.email", "riela-test@example.invalid"], at: successor)
    let deliverable = RepositoryDeliverable(
      root: fixture.clone.path, remote: fixture.bareRemote.absoluteString, branch: branch,
      baseRevision: fixture.baseRevision, headCommit: publishedSHA, state: .published
    )
    let bundle = try harness.bundle("task-handover-presence")
    let packet = try remotePacket(
      workflowId: bundle.workflow.workflowId, workflowDirectory: harness.examples.path,
      deliverables: [.repository(deliverable)]
    )
    let transport = TaskRemoteTakeoverTestTransport(packet: packet)
    var runner = WorkflowRunCommand(resolver: TaskExampleBundleResolver(bundle: bundle))
    runner.taskNodeAdapterOverride = RemoteTakeoverNodeAdapter(publishDirectory: successor)
    let takeover = TaskRemoteTakeover(
      transport: transport, resolver: TaskExampleBundleResolver(bundle: bundle), runner: runner,
      workspace: GitBranchWorkspaceRuntime(git: FoundationGitCommandRunner(), environment: fixture.gitEnvironment),
      hostResolver: TaskHandoverTestHostResolver()
    )
    let sessionRoot = try Self.makeSuccessorRoot()
    defer { try? FileManager.default.removeItem(at: sessionRoot) }
    let result = await takeover.run(TaskRemoteTakeoverOptions(
      taskId: packet.taskId.rawValue, handoverId: packet.id.rawValue, endpoint: "in-process",
      auth: TaskRemoteAuth(), traits: [.userReachable], workingDirectory: successor.path, cloneInto: nil,
      sessionStore: sessionRoot.appendingPathComponent("sessions", isDirectory: true).path,
      scope: .project, output: .json
    ))

    XCTAssertEqual(result.exitCode, .success, "\(result.stderr)\n\(result.stdout)")
    let didReport = await transport.didReport
    XCTAssertTrue(didReport)
    let reported = await transport.reportedDeliverables.compactMap { ref -> RepositoryDeliverable? in
      guard case let .repository(value) = ref else { return nil }
      return value
    }
    let repository = try XCTUnwrap(reported.first, "the report must carry a repository deliverable")
    XCTAssertEqual(reported.count, 1)
    XCTAssertEqual(repository.state, .published)
    XCTAssertEqual(repository.branch, branch)
    let remoteSHA = try fixture.git(["rev-parse", "refs/heads/\(branch)"], at: fixture.bareRemote)
    XCTAssertEqual(repository.headCommit, remoteSHA)
    XCTAssertNotEqual(remoteSHA, publishedSHA, "the successor must have pushed a new commit")
    XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], at: successor), remoteSHA)
    XCTAssertEqual(
      try String(contentsOf: successor.appendingPathComponent("successor-output.txt"), encoding: .utf8),
      "published by successor"
    )
  }

  func testRemoteTakeoverRefusesUnpublishedRepositoryDeliverable() async throws {
    let fixture = try TaskHandoverRepositoryFixture()
    defer { fixture.remove() }
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let branch = "riela/task/task-remote/g2"
    let publishedSHA = try Self.publishBranch(branch, in: fixture)
    let successor = try fixture.secondClone()
    let deliverable = RepositoryDeliverable(
      root: fixture.clone.path, remote: fixture.bareRemote.absoluteString, branch: branch,
      baseRevision: fixture.baseRevision, headCommit: publishedSHA, state: .unpublished(lastKnown: publishedSHA)
    )
    let bundle = try harness.bundle("task-handover-presence")
    let packet = try remotePacket(
      workflowId: bundle.workflow.workflowId, workflowDirectory: harness.examples.path,
      deliverables: [.repository(deliverable)]
    )
    let transport = TaskRemoteTakeoverTestTransport(packet: packet)
    var runner = WorkflowRunCommand(resolver: TaskExampleBundleResolver(bundle: bundle))
    runner.taskNodeAdapterOverride = RemoteTakeoverNodeAdapter(publishDirectory: successor)
    let takeover = TaskRemoteTakeover(
      transport: transport, resolver: TaskExampleBundleResolver(bundle: bundle), runner: runner,
      workspace: GitBranchWorkspaceRuntime(git: FoundationGitCommandRunner(), environment: fixture.gitEnvironment),
      hostResolver: TaskHandoverTestHostResolver()
    )
    let sessionRoot = try Self.makeSuccessorRoot()
    defer { try? FileManager.default.removeItem(at: sessionRoot) }
    let result = await takeover.run(TaskRemoteTakeoverOptions(
      taskId: packet.taskId.rawValue, handoverId: packet.id.rawValue, endpoint: "in-process",
      auth: TaskRemoteAuth(), traits: [.userReachable], workingDirectory: successor.path, cloneInto: nil,
      sessionStore: sessionRoot.appendingPathComponent("sessions", isDirectory: true).path,
      scope: .project, output: .json
    ))

    XCTAssertEqual(result.exitCode, .failure, "\(result.stderr)\n\(result.stdout)")
    XCTAssertTrue(
      result.stderr.contains("remote takeover needs a published branch with a reachable remote"), result.stderr
    )
    let takeoverCalls = await transport.takeoverCallCount
    let didReport = await transport.didReport
    XCTAssertEqual(takeoverCalls, 0)
    XCTAssertFalse(didReport)
    XCTAssertEqual(try fixture.git(["rev-parse", "refs/heads/\(branch)"], at: fixture.bareRemote), publishedSHA)
  }

  // MARK: Local `task serve --takeover --once`

  func testLocalServeOnceTakesEligiblePresenceTaskAndSkipsUnansweredQuestionTask() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let sealed = try await sealPresenceHandover(harness)
    let questionTask = try harness.seed("task-repair-loop", state: .waiting)
    try harness.store.saveHandover(Self.unansweredQuestionPacket(for: questionTask).sealed())
    let dispatch = try presenceDispatch(harness)
    var serve = TaskServeTakeover()
    serve.localDispatch = { signalState in
      var configured = dispatch
      configured.signalState = signalState
      return configured
    }
    let result = await serve.run([
      "--takeover", "--once", "--traits", "userReachable", "--scope", "project",
      "--working-dir", harness.repository.path, "--session-store", harness.sessionStore.path
    ], signalState: nil)

    XCTAssertEqual(result.exitCode, .success, "\(result.stderr)\n\(result.stdout)")
    let attempts = try harness.store.listAttempts(taskId: sealed.task.id)
    XCTAssertEqual(attempts.count, 2, "serve must take the eligible presence task")
    let successor = try XCTUnwrap(attempts.last)
    XCTAssertEqual(
      successor.entry, .takeover(fromAttemptId: sealed.predecessorId, handoverId: sealed.packet.id)
    )
    XCTAssertEqual(try harness.store.loadTask(id: sealed.task.id)?.state, .succeeded)
    XCTAssertEqual(try harness.store.listAttempts(taskId: questionTask.id), [])
    XCTAssertEqual(try harness.store.loadTask(id: questionTask.id)?.state, .waiting)
  }

  // MARK: Helpers

  private static let pendingSchemaRegistrationMessage =
    "Pending wh-20 step 3: taskHandoverGraphQLSchemaTypes is not yet registered in the GraphQL schema, "
    + "so $input: TakeoverTaskInput! fails variable validation. Remove this branch once wh-20 registers it."

  /// True while the server rejects `$input: TakeoverTaskInput!` (pending wh-20 step 3). The error text reaches the
  /// caller through `String(describing:)`, which escapes single quotes, so both renderings are accepted.
  private static func isPendingSchemaRegistration(_ stderr: String) -> Bool {
    stderr.contains("unknown or non-input type 'TakeoverTaskInput'")
      || stderr.contains("unknown or non-input type \\'TakeoverTaskInput\\'")
  }

  private struct SealedPresence {
    var task: WorkTask
    var packet: HandoverPacket
    var predecessorId: AttemptID
  }

  private func presenceDispatch(_ harness: TaskExampleHarness) throws -> TaskDispatch {
    let name = "task-handover-presence"
    let resolver = TaskExampleBundleResolver(bundle: try harness.bundle(name))
    return TaskDispatch(
      resolver: resolver,
      hostResolver: RemoteTakeoverDispatchHostResolver(),
      runner: WorkflowRunCommand(resolver: resolver),
      mockScenarioPath: harness.examples.appendingPathComponent(name)
        .appendingPathComponent("mock-scenario.json").path
    )
  }

  /// Drives the packaged presence example until it really suspends and seals a presence handover.
  private func sealPresenceHandover(_ harness: TaskExampleHarness) async throws -> SealedPresence {
    let task = try harness.seed("task-handover-presence")
    let dispatch = try presenceDispatch(harness)
    let result = await dispatch.run(
      taskId: task.id.rawValue,
      options: TaskStoreOptions(
        scope: .project, workingDirectory: harness.repository.path, sessionStore: harness.sessionStore.path
      ),
      dryRun: false, output: .json
    )
    XCTAssertEqual(result.exitCode, .suspended, "\(result.stderr)\n\(result.stdout)")
    let packet = try XCTUnwrap(harness.store.latestHandover(taskId: task.id))
    guard case .userPresenceRequired = packet.reason else {
      XCTFail("expected a presence handover, got \(packet.reason)")
      throw WorkStoreError("presence handover was not sealed")
    }
    XCTAssertEqual(packet.digest, try packet.canonicalDigest())
    let attempts = try harness.store.listAttempts(taskId: task.id)
    XCTAssertEqual(attempts.count, 1)
    return SealedPresence(
      task: try XCTUnwrap(harness.store.loadTask(id: task.id)), packet: packet,
      predecessorId: try XCTUnwrap(attempts.last).id
    )
  }

  private func providerOptions(
    _ sealed: SealedPresence, traits: [HostTrait], root: URL, sessionStore: URL
  ) -> TaskRemoteTakeoverOptions {
    TaskRemoteTakeoverOptions(
      taskId: sealed.task.id.rawValue, handoverId: sealed.packet.id.rawValue, endpoint: "in-process",
      auth: TaskRemoteAuth(), traits: traits, workingDirectory: root.path, cloneInto: nil,
      sessionStore: sessionStore.path, scope: .project, output: .json
    )
  }

  private static func makeSuccessorRoot() throws -> URL {
    try TaskHandoverHermeticGit.makeRoot("riela-remote-successor")
  }

  /// Commits one file on `branch` in the fixture clone and pushes it to the fixture's bare remote.
  private static func publishBranch(_ branch: String, in fixture: TaskHandoverRepositoryFixture) throws -> String {
    _ = try fixture.git(["checkout", "-b", branch])
    try fixture.write("successor", to: "handover.txt")
    _ = try fixture.git(["add", "--", "handover.txt"])
    _ = try fixture.git(["commit", "-m", "handover"])
    _ = try fixture.git(["push", "origin", "HEAD:refs/heads/\(branch)"])
    return try fixture.git(["rev-parse", "HEAD"])
  }

  private static func unansweredQuestionPacket(for task: WorkTask) -> HandoverPacket {
    HandoverPacket(
      id: HandoverID(rawValue: "handover-unanswered-serve-eligible-test"), taskId: task.id, intentId: task.intentId,
      fromAttemptId: AttemptID("attempt-unanswered-serve-eligible-test"),
      fromSessionId: "session-unanswered-serve-eligible-test",
      generation: 1, reason: .userInputRequired(HandoverQuestion(
        id: "approval", text: "Approve?", answerSchema: ["type": .string("object")]
      )),
      workflow: HandoverWorkflowRef(workflowId: "task-repair-loop", entryStepId: "start", resumeStepId: "repair"),
      progress: HandoverProgress(acceptedSteps: [], remainingSteps: ["repair"], latestGateResults: [],
        openFindings: [], evidenceSummary: [:],
        remainingBudget: BudgetSnapshot(attemptsUsed: 0, tokensUsed: 0, wallClockMsUsed: 0)),
      history: HandoverHistoryBundle(executions: [], messages: [], compatibilityDigests: [:], truncated: false),
      contract: HandoverContinuationContract(resumeStepId: "repair", completion: task.completion,
        verification: [], guardPolicy: task.guardPolicy), brief: "Waiting for an answer", producedBy: .runtime,
      producedOn: "test", createdAt: Date()
    )
  }

  private func remoteOptions(harness: TaskExampleHarness, packet: HandoverPacket) -> TaskRemoteTakeoverOptions {
    TaskRemoteTakeoverOptions(
      taskId: packet.taskId.rawValue, handoverId: packet.id.rawValue, endpoint: "in-process",
      auth: TaskRemoteAuth(token: "test-secret", managerSessionId: "test-manager"),
      traits: [.userReachable], workingDirectory: harness.repository.path, cloneInto: nil,
      sessionStore: harness.sessionStore.path, scope: .project, output: .json
    )
  }

  private func remotePacket(
    workflowId: String, workflowDirectory: String, deliverables: [DeliverableRef] = [],
    reason: HandoverReason? = nil, history: HandoverHistoryBundle? = nil, resumeStepId: String = "publish"
  ) throws -> HandoverPacket {
    let taskId = TaskID("task-remote-\(UUID().uuidString.lowercased())")
    let completion = CompletionContract()
    let policy = GuardPolicy()
    return try HandoverPacket(
      id: HandoverID("handover-remote-\(UUID().uuidString.lowercased())"), taskId: taskId,
      intentId: IntentID("intent-remote"), fromAttemptId: AttemptID("attempt-remote-predecessor"),
      fromSessionId: "session-remote-predecessor", generation: 1,
      reason: reason ?? .userPresenceRequired(PresenceRequirement(traits: [.userReachable], instructions: "Continue")),
      workflow: HandoverWorkflowRef(workflowId: workflowId, scope: "project",
        workflowDefinitionDir: workflowDirectory, entryStepId: "check-login", resumeStepId: resumeStepId),
      progress: HandoverProgress(acceptedSteps: [], remainingSteps: ["publish", "report"], latestGateResults: [],
        openFindings: [], evidenceSummary: [:], remainingBudget: BudgetSnapshot(attemptsUsed: 1, tokensUsed: 0, wallClockMsUsed: 0)),
      history: history ?? HandoverHistoryBundle(executions: [], messages: [], compatibilityDigests: [:], truncated: false),
      deliverables: deliverables,
      contract: HandoverContinuationContract(resumeStepId: resumeStepId, completion: completion, verification: [], guardPolicy: policy),
      brief: "Continue remotely", producedBy: .runtime, producedOn: "controller", createdAt: Date()
    ).sealed()
  }
}

private actor TaskRemoteTakeoverTestTransport: TaskHandoverGraphQLTransporting {
  let packet: HandoverPacket
  let fenceHeartbeats: Bool
  let answer: GraphQLHandoverAnswer?
  private(set) var heartbeatCount = 0
  private(set) var didReport = false
  private(set) var reportedSnapshot: WorkflowRuntimePersistenceSnapshot?
  private(set) var reportedDeliverables: [DeliverableRef] = []
  private(set) var takeoverCallCount = 0

  init(packet: HandoverPacket, fenceHeartbeats: Bool = false, answer: GraphQLHandoverAnswer? = nil) {
    self.packet = packet
    self.fenceHeartbeats = fenceHeartbeats
    self.answer = answer
  }

  func execute(endpoint: String, query: String, variables: JSONObject, auth: TaskRemoteAuth) async throws -> JSONObject {
    if query.contains("taskHandover(") {
      let graphPacket = GraphQLHandoverPacket(
        handoverId: packet.id.rawValue, taskId: packet.taskId.rawValue, digest: packet.digest,
        reasonKind: packet.reason.kindName, resumeStepId: packet.contract.resumeStepId, brief: packet.brief,
        packet: try Self.jsonObject(packet)
      )
      return ["taskHandover": .object(["handover": .object(try Self.jsonObject(graphPacket)), "errors": .array([])])]
    }
    if query.contains("takeoverTask(") {
      takeoverCallCount += 1
      return ["takeoverTask": .object([
        "attemptId": .string("attempt-remote-successor"), "sessionId": .string("task-session-remote-successor"),
        "fence": .integer(2), "heartbeatToken": .string("lease-secret"), "heartbeatMs": .integer(30),
        "answer": try answer.map(Self.jsonValue) ?? .null, "errors": .array([])
      ])]
    }
    if query.contains("heartbeatAttempt(") {
      heartbeatCount += 1
      return ["heartbeatAttempt": .object([
        "attemptId": .string("attempt-remote-successor"), "fence": .integer(2), "expiresAt": .null,
        "fenced": .bool(fenceHeartbeats), "errors": .array([])
      ])]
    }
    if query.contains("reportAttempt(") {
      didReport = true
      if case let .object(input)? = variables["input"], case let .object(raw)? = input["snapshot"] {
        reportedSnapshot = try JSONCanonical.decoder().decode(WorkflowRuntimePersistenceSnapshot.self,
          from: JSONCanonical.encode(JSONValue.object(raw)))
      }
      if case let .object(input)? = variables["input"], case let .array(raw)? = input["deliverables"] {
        reportedDeliverables = try JSONCanonical.decoder().decode([DeliverableRef].self,
          from: JSONCanonical.encode(JSONValue.array(raw)))
      }
      return ["reportAttempt": .object(["taskState": .string("succeeded"), "decisionKind": .string("accept"),
        "handoverId": .null, "errors": .array([])])]
    }
    throw WorkStoreError("unexpected remote GraphQL operation")
  }

  private static func jsonObject<T: Encodable>(_ value: T) throws -> JSONObject {
    try JSONCanonical.decoder().decode(JSONObject.self, from: JSONCanonical.encode(value))
  }

  private static func jsonValue<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONCanonical.decoder().decode(JSONValue.self, from: JSONCanonical.encode(value))
  }
}

private extension ISO8601DateFormatter {
  static func remoteTakeoverTestDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value)
  }
}

private struct RemoteTakeoverNodeAdapter: NodeAdapter {
  var delayMs = 0
  /// When set, the `publish` step writes a new file here so the successor checkout has a fresh commit to publish.
  var publishDirectory: URL?
  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    if delayMs > 0 { try await Task.sleep(for: .milliseconds(delayMs)) }
    if input.node.id == "publish", let publishDirectory {
      try "published by successor".write(
        to: publishDirectory.appendingPathComponent("successor-output.txt"), atomically: true, encoding: .utf8
      )
    }
    let payload: JSONObject = input.node.id == "publish" ? ["published": .bool(true)] : ["summary": .string("Published")]
    return AdapterExecutionOutput(provider: "test", model: "test", promptText: "", completionPassed: true, payload: payload)
  }
  func workflowRunDidEnd(_ context: WorkflowRunLifecycleContext) async {}
}

private struct RemoteTakeoverDispatchHostResolver: HostCapabilityResolving {
  func resolve(
    host: String, scope: WorkflowScope, workingDirectory: String, readOnly: Bool, localAddonExecutables: [String: Bool]
  ) async throws -> [HostCapabilitySnapshot] {
    let now = Date()
    return [HostCapabilitySnapshot(
      hostId: "local", capacity: 1,
      backends: [BackendCapability(
        backend: .codexAgent, source: .observed, observedAt: now, availability: .available,
        authentication: .available, models: ["gpt-5.4-mini"]
      )],
      refreshedAt: now
    )]
  }
}

/// Mirrors the post-authentication step of `ServeWebRegistryExecutor` (mark the request locally trusted and
/// pin the working directory), then delegates to the real task-handover GraphQL executor and provider over
/// the controller's own store. Heartbeat response bodies are recorded for inspection.
private actor TaskRemoteTakeoverControllerExecutor: GraphQLDocumentExecuting {
  private let inner: TaskHandoverGraphQLDocumentExecutor
  private let workingDirectory: String
  private(set) var heartbeatBodies: [JSONObject] = []

  init(controller: TaskExampleHarness) {
    workingDirectory = controller.repository.path
    inner = TaskHandoverGraphQLDocumentExecutor(provider: TaskHandoverGraphQLProvider(
      workingDirectory: controller.repository.path, sessionStore: controller.sessionStore.path, scope: .project
    ))
  }

  func execute(_ request: GraphQLDocumentRequest) async -> GraphQLDocumentExecutionResponse {
    var trusted = request
    trusted.isLocallyTrusted = true
    trusted.localWorkingDirectory = workingDirectory
    let response = await inner.execute(trusted)
    if request.query.contains("heartbeatAttempt(") { heartbeatBodies.append(response.body) }
    return response
  }
}

private actor TaskRemoteTakeoverStubExecutor: GraphQLDocumentExecuting {
  private(set) var lastRequest: GraphQLDocumentRequest?
  func execute(_ request: GraphQLDocumentRequest) async -> GraphQLDocumentExecutionResponse {
    lastRequest = request
    return GraphQLDocumentExecutionResponse(handled: true, body: ["data": .object(["marker": .string("handled")])])
  }
}

private final class TaskRemoteTakeoverURLProtocol: URLProtocol, @unchecked Sendable {
  private static let capturedHeaders = TaskRemoteTakeoverHeaderCapture()
  static var lastHeaders: [String: String]? { capturedHeaders.get() }

  static func reset() { capturedHeaders.set(nil) }

  override static func canInit(with request: URLRequest) -> Bool { true }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.capturedHeaders.set(request.allHTTPHeaderFields ?? [:])
    let body = Data(#"{"data":{"ok":true}}"#.utf8)
    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private final class TaskRemoteTakeoverHeaderCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var headers: [String: String]?
  func get() -> [String: String]? {
    lock.lock()
    defer { lock.unlock() }
    return headers
  }
  func set(_ value: [String: String]?) {
    lock.lock()
    headers = value
    lock.unlock()
  }
}
