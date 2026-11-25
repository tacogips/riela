import Foundation
import RielaCore
import Testing
@testable import RielaCLI

@Suite
struct AskActionTests {
  @Test
  func terminalSessionDoesNotProduceProposal() async throws {
    let fixture = try AskActionFixture()
    try fixture.saveSession(status: .completed)
    let result = await fixture.executor.execute(
      conversationId: fixture.conversationId, turnId: fixture.turnId, toolCallId: "call-1",
      name: "propose_action", arguments: [
        "kind": .string(AskActionKind.stopSession.rawValue),
        "target": .object(["sessionId": .string("session")])
      ]
    )
    #expect(!result.ok)
    #expect(result.error?.code == "action_target_invalid")
    #expect(try fixture.store.askActions(conversationId: fixture.conversationId).isEmpty)
  }

  @Test
  func rejectsOptionThatWasNeverOffered() async throws {
    let fixture = try AskActionFixture()
    try fixture.savePermissionRequest()
    let kind = AskActionKind.answerBotRequest.rawValue
    let unknownOption: JSONObject = ["requestId": .string("request"), "optionId": .string("unknown")]
    await expectAskError("action_target_invalid") {
      _ = try await fixture.propose(kind: kind, target: unknownOption)
    }
    #expect(try fixture.store.askActions(conversationId: fixture.conversationId).isEmpty)

    let target: JSONObject = ["requestId": .string("request"), "optionId": .string("offered")]
    let action = try await fixture.propose(kind: kind, target: target)
    let confirmed = try await fixture.confirm(action)
    #expect(confirmed.status == .confirmed)
    #expect(await fixture.spy.calls == [.answer("request", "offered", false)])
  }

  @Test
  func rejectsUnknownActionKindAndModelSuppliedWorkflowId() async throws {
    let fixture = try AskActionFixture()
    await expectAskError("action_kind_unknown") {
      _ = try await fixture.propose(kind: "deleteBot", target: ["botId": .string("bot")])
    }
    try fixture.saveSession(status: .running)
    await expectAskError("action_target_invalid") {
      _ = try await fixture.propose(kind: AskActionKind.stopSession.rawValue, target: [
        "sessionId": .string("session"), "workflowId": .string("unrelated-flow")
      ])
    }
    #expect(try fixture.store.askActions(conversationId: fixture.conversationId).isEmpty)
  }

  @Test
  func rerunValidatesStepInSessionDefinition() async throws {
    let fixture = try AskActionFixture()
    let definitionDir = try fixture.saveWorkflow()
    try fixture.saveSession(status: .failed, definitionDir: definitionDir)
    let kind = AskActionKind.rerunSession.rawValue
    await expectAskError("action_target_invalid") {
      _ = try await fixture.propose(kind: kind, target: ["sessionId": .string("session"), "stepId": .string("unknown")])
    }
    let action = try await fixture.propose(
      kind: kind, target: ["sessionId": .string("session"), "stepId": .string("final")]
    )
    let confirmed = try await fixture.confirm(action)
    #expect(confirmed.status == .confirmed)
    #expect(await fixture.spy.calls == [.rerun("session", "flow-id", "final")])
  }

  @Test
  func limitsPendingProposalsPerTurn() async throws {
    let fixture = try AskActionFixture()
    for _ in 0..<AskLimits.standard.actionsPerTurn {
      _ = try await fixture.proposePause()
    }
    await expectAskError("action_limit") {
      _ = try await fixture.proposePause()
    }
    #expect(try fixture.store.askActions(conversationId: fixture.conversationId).count == AskLimits.standard.actionsPerTurn)
    #expect(await fixture.spy.calls.isEmpty)
  }

  @Test
  func confirmsOnceWithStoredTargetAndAuditsDecision() async throws {
    let fixture = try AskActionFixture()
    try fixture.saveSession(status: .running)
    let reason = "Cancel\nnow \(String(repeating: "a", count: 250))"
    let proposal = try await fixture.propose(
      kind: AskActionKind.stopSession.rawValue, target: ["sessionId": .string("session")], reason: reason
    )
    #expect(proposal.status == .proposed)
    #expect(proposal.actionId.hasPrefix("act-"))
    #expect(proposal.target == ["sessionId": .string("session"), "workflowId": .string("flow-id")])
    #expect(proposal.reason.count == 200)
    #expect(!proposal.reason.contains("\n"))
    #expect(proposal.expiresAt == RoutineStore.timestamp(
      fixture.at.addingTimeInterval(TimeInterval(AskLimits.standard.actionLifetimeSeconds))
    ))

    let confirmed = try await fixture.confirm(proposal)
    #expect(confirmed.status == .confirmed)
    #expect(confirmed.decision == .confirm)
    #expect(confirmed.decidedBy == "grant-1 Client")
    #expect(confirmed.decidedAt == RoutineStore.timestamp(fixture.at))
    #expect(confirmed.result?.ok == true)
    #expect(try fixture.store.askAction(id: proposal.actionId) == confirmed)
    await expectAskError("action_already_decided") {
      _ = try await fixture.confirm(proposal)
    }
    #expect(await fixture.spy.calls == [.stop("session", "flow-id")])
  }

  @Test
  func simultaneousConfirmationsHaveOneWinner() async throws {
    let fixture = try AskActionFixture()
    let proposed = try await fixture.proposePause()
    let outcomes = await withTaskGroup(of: String.self) { group in
      for _ in 0..<2 {
        group.addTask {
          do {
            return try await fixture.confirm(proposed).status.rawValue
          } catch let error as AskError {
            return error.code
          } catch {
            return String(describing: error)
          }
        }
      }
      var outcomes: [String] = []
      for await outcome in group { outcomes.append(outcome) }
      return outcomes.sorted()
    }
    #expect(outcomes == ["action_already_decided", "confirmed"])
    #expect(await fixture.spy.calls == [.pause("bot", true)])
  }

  @Test
  func dismissesWithoutExecutingMutation() async throws {
    let fixture = try AskActionFixture()
    let proposal = try await fixture.proposePause()
    let dismissed = try fixture.service.dismiss(
      conversationId: fixture.conversationId, actionId: proposal.actionId, decidedBy: "local"
    )
    #expect(dismissed.status == .dismissed)
    #expect(dismissed.decision == .dismiss)
    #expect(dismissed.decidedBy == "local")
    #expect(try fixture.store.askAction(id: proposal.actionId) == dismissed)
    await expectAskError("action_already_decided") {
      _ = try await fixture.confirm(proposal)
    }
    #expect(await fixture.spy.calls.isEmpty)
  }

  @Test
  func rejectsExpiredAndCrossConversationConfirmations() async throws {
    let fixture = try AskActionFixture()
    let proposal = try await fixture.proposePause()
    await expectAskError("action_not_found") {
      _ = try await fixture.service.confirm(
        conversationId: "another-conversation", actionId: proposal.actionId, decidedBy: "local"
      )
    }
    var service = fixture.service
    service.now = { fixture.at.addingTimeInterval(TimeInterval(AskLimits.standard.actionLifetimeSeconds)) }
    await expectAskError("action_expired") {
      _ = try await service.confirm(
        conversationId: fixture.conversationId, actionId: proposal.actionId, decidedBy: "local"
      )
    }
    #expect(await fixture.spy.calls.isEmpty)
  }

  @Test
  func redactsFailedMutationAndReturnsAuditedRow() async throws {
    let fixture = try AskActionFixture()
    await fixture.spy.fail(with: AskError(code: "mutation_rejected", message: "Error \(AskActionFixture.secret)"))
    let proposal = try await fixture.proposePause()
    let failed = try await fixture.confirm(proposal)
    #expect(failed.status == .failed)
    #expect(failed.result?.ok == false)
    #expect(failed.result?.code == "mutation_rejected")
    let message = try #require(failed.result?.message)
    #expect(!message.contains(AskActionFixture.secret))
    #expect(try fixture.store.askAction(id: proposal.actionId) == failed)
    #expect(await fixture.spy.calls == [.pause("bot", true)])
  }

  @Test
  func targetRemovedAfterProposalDoesNotExecuteMutation() async throws {
    let fixture = try AskActionFixture()
    let proposal = try await fixture.proposePause()
    try fixture.store.remove(botId: "bot")
    let failed = try await fixture.confirm(proposal)
    #expect(failed.status == .failed)
    #expect(failed.result?.code == "action_target_invalid")
    #expect(try fixture.store.askAction(id: proposal.actionId) == failed)
    #expect(await fixture.spy.calls.isEmpty)
  }

  private func expectAskError(_ code: String, _ operation: () async throws -> Void) async {
    do {
      try await operation()
      Issue.record("Expected an Ask error with code \(code)")
    } catch let error as AskError {
      #expect(error.code == code)
    } catch {
      Issue.record("Unexpected error \(error)")
    }
  }
}

private final class AskActionFixture: Sendable {
  static let secret = "example-fixture-token-1234"

  let at = Date(timeIntervalSince1970: 1_790_000_000)
  let directory: URL
  let environment: [String: String]
  let store: BotStore
  let conversationId: String
  let turnId: String
  let surface: ProviderAskReadSurface
  let spy = AskActionMutationSpy()
  let sessions: String

  init() throws {
    let repository = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
    let directory = repository
      .appendingPathComponent("tmp/ask-riela/ask-02-store-tools/actions/fixture-\(UUID().uuidString)")
    self.directory = directory
    let environment = [
      "HOME": directory.path,
      "XDG_CONFIG_HOME": directory.appendingPathComponent("config").path,
      "XDG_STATE_HOME": directory.appendingPathComponent("state").path,
      "RIELA_CREDENTIAL_DIR": directory.appendingPathComponent("credentials").path,
      "RIELA_MEMORY_ROOT": directory.appendingPathComponent("memory").path,
      "RIELA_WORKFLOW_HOME": directory.appendingPathComponent("workflows").path,
      RoutineStore.rootDirectoryEnvironmentKey: directory.appendingPathComponent("routines").path,
      "TEST_API_TOKEN": Self.secret
    ]
    self.environment = environment
    let sessions = directory.appendingPathComponent("sessions").path
    self.sessions = sessions
    let store = BotStore(sessionStoreRoot: canonicalRuntimeStoreRoot(sessionStoreRoot: sessions))
    self.store = store
    self.surface = ProviderAskReadSurface(providers: .local(
      workingDirectory: directory.path, sessionStore: sessions, scope: .project, environment: environment
    ))
    do {
      let timestamp = RoutineStore.timestamp(at)
      try store.create(BotRecord(botId: "bot", name: "Bot", createdAt: timestamp, updatedAt: timestamp))
      let conversation = try store.createAskConversation(context: .init(), selection: .init(), firstMessage: "Help", now: at)
      conversationId = conversation.conversationId
      let started = try store.beginAskTurn(
        conversationId: conversation.conversationId, message: "Help", context: nil,
        turn: .init(backend: "script", providerInstanceId: "fixture", toolTransport: .rounds, runnerId: "runner"),
        limits: .standard, now: at
      )
      turnId = try #require(started.turn?.turnId)
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  deinit { try? FileManager.default.removeItem(at: directory) }

  var proposer: AskActionProposer {
    .init(surface: surface, store: store, environment: environment, now: { self.at })
  }

  var service: AskActionService {
    .init(store: store, proposals: proposer, mutations: spy, environment: environment, now: { self.at })
  }

  var executor: AskToolExecutor {
    .init(
      store: store, surface: surface, proposals: proposer,
      recorder: SQLiteWorkflowActivityRecorder(sessionStoreRoot: store.sessionStoreRoot),
      environment: environment, limits: .standard, now: { self.at }
    )
  }

  func proposePause() async throws -> AskAction {
    try await propose(
      kind: AskActionKind.setBotPaused.rawValue,
      target: ["botId": .string("bot"), "paused": .bool(true)]
    )
  }

  func propose(kind: String, target: JSONObject, reason: String? = nil) async throws -> AskAction {
    try await proposer.propose(conversationId: conversationId, turnId: turnId, kind: kind, target: target, reason: reason)
  }

  func confirm(_ action: AskAction) async throws -> AskAction {
    try await service.confirm(conversationId: conversationId, actionId: action.actionId, decidedBy: "grant-1 Client")
  }

  func saveSession(status: WorkflowSessionStatus, definitionDir: String? = nil) throws {
    try CLIWorkflowSessionStore(rootDirectory: sessions).save(.init(
      workflowName: "flow-name",
      session: .init(
        workflowId: "flow-id", sessionId: "session", status: status, entryStepId: "step", createdAt: at, updatedAt: at
      ),
      resolution: .init(
        workflowName: "flow-name", scope: .project, workflowDefinitionDir: definitionDir, workingDirectory: directory.path
      )
    ))
  }

  func saveWorkflow() throws -> String {
    let definitions = directory.appendingPathComponent("definitions")
    let workflow = definitions.appendingPathComponent("flow-name")
    try FileManager.default.createDirectory(at: workflow, withIntermediateDirectories: true)
    try """
    {"workflowId":"flow-id","defaults":{"nodeTimeoutMs":120000,"maxLoopIterations":2},"entryStepId":"step",
     "nodes":[{"id":"step","nodeFile":"step.json"},{"id":"final","nodeFile":"final.json"}],
     "steps":[{"id":"step","nodeId":"step","transitions":[{"toStepId":"final"}]},{"id":"final","nodeId":"final"}]}
    """.write(to: workflow.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    for step in ["step", "final"] {
      try """
      {"id":"\(step)","executionBackend":"codex-agent","agentSandbox":"read-only","model":"fixture","variables":{},
       "output":{"jsonSchema":{"type":"object","required":["answer"]},"maxValidationAttempts":2}}
      """.write(to: workflow.appendingPathComponent("\(step).json"), atomically: true, encoding: .utf8)
    }
    return definitions.path
  }

  func savePermissionRequest() throws {
    try store.write { database in
      try database.execute(
        """
        INSERT INTO activity_requests
          (request_id, session_id, execution_id, options_json, status, created_at, expires_at)
        VALUES ('request', 'session', 'step-execution', jsonb(?), 'pending', ?, ?)
        """,
        bindings: [
          .text(#"[{"optionId":"offered","name":"Allow","kind":"allow_once"}]"#),
          .text(RoutineStore.timestamp(at)),
          .text(RoutineStore.timestamp(at.addingTimeInterval(60)))
        ]
      )
    }
  }
}

private actor AskActionMutationSpy: AskMutationSurface {
  enum Call: Equatable {
    case stop(String, String), rerun(String, String, String), answer(String, String?, Bool), pause(String, Bool), apply(String)
  }

  private(set) var calls: [Call] = []
  private var failure: AskError?

  func fail(with error: AskError) { failure = error }

  func stopSession(sessionId: String, workflowId: String) throws -> AskActionResult {
    try record(.stop(sessionId, workflowId), id: sessionId)
  }

  func rerunSession(sessionId: String, workflowId: String, stepId: String) throws -> AskActionResult {
    try record(.rerun(sessionId, workflowId, stepId), id: sessionId)
  }

  func answerBotRequest(requestId: String, optionId: String?, decline: Bool) throws -> AskActionResult {
    try record(.answer(requestId, optionId, decline), id: requestId)
  }

  func setBotPaused(botId: String, paused: Bool) throws -> AskActionResult {
    try record(.pause(botId, paused), id: botId)
  }

  func applyWorkflow(_ target: AskWorkflowActionTarget) throws -> AskActionResult {
    try record(.apply(target.workflowId), id: target.workflowId)
  }

  private func record(_ call: Call, id: String) throws -> AskActionResult {
    calls.append(call)
    if let failure { throw failure }
    return .init(ok: true, summary: "Applied", ids: [id])
  }
}
