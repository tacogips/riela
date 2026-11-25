import Foundation
import RielaCore
import RielaWorkflowRegistry
import XCTest
@testable import RielaCLI

@MainActor
final class AskWorkflowAuthoringTests: XCTestCase {
  nonisolated static let definition: JSONObject = [
    "workflowId": .string("authored-workflow"),
    "description": .string("A workflow proposed by Ask"),
    "defaults": .object(["nodeTimeoutMs": .integer(120_000), "maxLoopIterations": .integer(3)]),
    "entryStepId": .string("work"),
    "nodes": .array([.object([
      "id": .string("worker"),
      "addon": .object([
        "name": .string("riela/codex-sdk-worker"), "version": .string("1"),
        "config": .object(["model": .string("gpt-5.5"), "promptTemplate": .string("Do the work")])
      ])
    ])]),
    "steps": .array([.object(["id": .string("work"), "nodeId": .string("worker"), "role": .string("worker")])])
  ]

  func testInvalidWorkflowReturnsIssuesWithoutWritingAnAction() async throws {
    let fixture = try await makeFixture()
    let run = try await fixture.makeExecutor()
    var invalid = Self.definition
    invalid["entryStepId"] = .string("missing")
    let result = await propose(invalid, on: run)
    XCTAssertEqual(result.error?.code, "workflow_invalid")
    guard case let .array(issues)? = result.data else { return XCTFail("Expected workflow issue list") }
    XCTAssertTrue(issues.contains { issue in
      guard case let .object(entry) = issue else { return false }
      return entry.askString("path")?.contains("entryStepId") == true
    })
    XCTAssertEqual(try fixture.store.askActions(conversationId: run.conversationId), [])
  }

  func testValidProposalReplacesPriorWorkflowProposalAtActionLimit() async throws {
    let fixture = try await makeFixture()
    var limits = AskLimits.standard
    limits.actionsPerTurn = 1
    let run = try await fixture.makeExecutor(limits: limits)
    let first = await propose(Self.definition, on: run)
    XCTAssertTrue(first.ok, "\(String(describing: first.error))")
    var revision = Self.definition
    revision["description"] = .string("Revised workflow")
    let second = await propose(revision, on: run)
    XCTAssertTrue(second.ok, "\(String(describing: second.error))")
    let actions = try fixture.store.askActions(conversationId: run.conversationId)
    XCTAssertEqual(actions.count, 2)
    XCTAssertEqual(actions.first { $0.status == .dismissed }?.decision, .replaced)
    let live = try XCTUnwrap(actions.first { $0.status == .proposed })
    XCTAssertEqual(live.kind, .applyWorkflow)
    XCTAssertEqual(live.target["mode"], .string("store"))
    XCTAssertEqual(live.target["definition"], .object(revision))
  }

  func testDraftConfirmReturnsDefinitionWithoutSavingAndSettledTurnClearsDraft() async throws {
    let fixture = try await makeFixture()
    let run = try await fixture.makeExecutor(draft: Self.definition)
    let result = await propose(Self.definition, on: run)
    XCTAssertTrue(result.ok, "\(String(describing: result.error))")
    let before = try fixture.store.askActions(conversationId: run.conversationId)
    XCTAssertEqual(try XCTUnwrap(before.first).target["mode"], .string("draft"))
    XCTAssertEqual(try fixture.store.askConversation(id: run.conversationId)?.turn?.draftDefinition, Self.definition)
    var host = AskHost.local(
      workingDirectory: fixture.root.path, sessionStore: fixture.sessions, scope: .project, environment: fixture.environment
    )
    let instant = fixture.now
    host.now = { instant }
    let service = AskService(host: host)
    XCTAssertNil(try service.conversation(id: run.conversationId).conversation.turn?.draftDefinition)
    XCTAssertNil(try service.conversations().first?.turn?.draftDefinition)
    try fixture.store.finishAskTurn(conversationId: run.conversationId, turnId: run.turnId, status: .completed)
    XCTAssertNil(try fixture.store.askConversation(id: run.conversationId)?.turn?.draftDefinition)
    let spy = AskEngineMutationSpy()
    let confirmed = try await confirm(fixture, run, mutations: spy)
    let calls = await spy.calls
    XCTAssertEqual(calls, 0)
    XCTAssertEqual(confirmed.status, .confirmed)
    XCTAssertEqual(confirmed.result?.ids, ["authored-workflow"])
    XCTAssertEqual(confirmed.result?.summary, "draft")
    XCTAssertEqual(confirmed.target["definition"], .object(Self.definition))
    let surface = ProviderAskReadSurface(providers: mutableProviders(fixture))
    do {
      _ = try await surface.workflowInspect(["workflowId": .string("authored-workflow")])
      XCTFail("Draft confirmation wrote a workflow")
    } catch let error as AskError {
      XCTAssertEqual(error.code, "not_found")
    }
  }

  func testImmutableBaseAndOversizeDefinitionDoNotWriteActions() async throws {
    let fixture = try await makeFixture()
    let run = try await fixture.makeExecutor()
    var sameId = Self.definition
    sameId["workflowId"] = .string(AskToolFixture.workflowId)
    let immutable = await propose(sameId, base: AskToolFixture.workflowId, on: run)
    XCTAssertEqual(immutable.error?.code, "workflow_not_mutable")
    var oversized = Self.definition
    oversized["description"] = .string(String(repeating: "a", count: AskLimits.standard.draftDefinitionBytes))
    let result = await propose(oversized, on: run)
    XCTAssertEqual(result.error?.code, "workflow_too_large")
    XCTAssertEqual(try fixture.store.askActions(conversationId: run.conversationId), [])
  }

  func testDraftPromptKeepsRetainHandleAndOmitsSecret() throws {
    let retained = String(repeating: "h", count: 43)
    var draft = Self.definition
    draft["description"] = .object(["$rielaRetain": .string(retained)])
    draft["environment"] = .object(["SERVICE_PASSWORD": .string(AskToolFixture.environmentSecret)])
    let prompt = try AskPrompt.user(
      context: nil, draft: draft, history: [], toolResults: [], message: "Edit this workflow",
      limits: .standard, environment: ["TEST_API_TOKEN": AskToolFixture.environmentSecret]
    )
    XCTAssertTrue(prompt.contains("Editor draft (user input)"))
    XCTAssertTrue(prompt.contains(retained))
    XCTAssertFalse(prompt.contains(AskToolFixture.environmentSecret))
  }

  func testStoreRegistrationReportsWrittenRevisionAndDuplicatePreservesIt() async throws {
    let fixture = try await makeFixture()
    let run = try await mutableTurn(fixture)
    let result = await propose(Self.definition, on: run)
    XCTAssertTrue(result.ok, "\(String(describing: result.error))")
    let confirmed = try await confirm(fixture, run)
    XCTAssertEqual(confirmed.status, .confirmed, "\(String(describing: confirmed.result))")
    let first = try storedData(fixture)
    XCTAssertEqual(confirmed.result?.ids, ["authored-workflow", WorkflowHistoryCanonicalCoding.sha256(first)])

    let duplicate = try await mutableTurn(fixture)
    var replacement = Self.definition
    replacement["description"] = .string("Must not overwrite")
    let proposed = await propose(replacement, on: duplicate)
    XCTAssertTrue(proposed.ok)
    let rejected = try await confirm(fixture, duplicate)
    XCTAssertEqual(rejected.status, .failed)
    XCTAssertEqual(rejected.result?.code, WorkflowRegistryErrorCode.registryIOFailure.rawValue)
    XCTAssertEqual(try storedData(fixture), first)
  }

  func testStoreUpdateReportsNewRevisionAndStaleProposalPreservesCompetingWrite() async throws {
    let fixture = try await makeFixture()
    let initial = try await register(Self.definition, fixture: fixture)
    let oldRevision = try XCTUnwrap(initial.result?.ids.last)
    let update = try await mutableTurn(fixture)
    let stale = try await mutableTurn(fixture)
    var changed = Self.definition
    changed["description"] = .string("Written by another confirmation")
    let updatedProposal = await propose(changed, base: "authored-workflow", on: update)
    XCTAssertTrue(updatedProposal.ok)
    let staleProposal = await propose(Self.definition, base: "authored-workflow", on: stale)
    XCTAssertTrue(staleProposal.ok)
    let action = try await confirm(fixture, update)
    XCTAssertEqual(action.status, .confirmed, "\(String(describing: action.result))")
    let updatedData = try storedData(fixture)
    let revision = WorkflowHistoryCanonicalCoding.sha256(updatedData)
    XCTAssertEqual(action.target["expectedDefinitionRevision"], .string(oldRevision))
    XCTAssertNotEqual(revision, oldRevision)
    XCTAssertEqual(action.result?.ids, ["authored-workflow", revision])

    let rejected = try await confirm(fixture, stale)
    XCTAssertEqual(rejected.status, .failed)
    XCTAssertEqual(rejected.result?.code, "REGISTRY_CONFLICT")
    XCTAssertEqual(try storedData(fixture), updatedData)
  }

  func testStoreUpdateRetainsProtectedValueWithKeySharedByIndependentProviders() async throws {
    let fixture = try await makeFixture()
    let protected = "password=AUTHORING_FIXTURE_CANARY"
    var definition = Self.definition
    definition["description"] = .string(protected)
    let registered = try await register(definition, fixture: fixture)
    XCTAssertEqual(registered.status, .confirmed, "\(String(describing: registered.result))")
    let run = try await mutableTurn(fixture)
    let result = await inspect(run)
    guard case let .object(entry)? = result.data, case let .object(projected)? = entry["definition"],
          let handle = projected["description"], AskWorkflowDraft.isRetainHandle(handle) else {
      return XCTFail("Expected the workflow_inspect result to contain a retain handle")
    }
    try await assertSharedRetainKey(fixture, originId: XCTUnwrap(entry.askString("originId")), handle: handle)

    let proposed = await propose(projected, base: "authored-workflow", on: run)
    XCTAssertTrue(proposed.ok, "\(String(describing: proposed.error))")
    let confirmed = try await confirm(fixture, run)
    XCTAssertEqual(confirmed.status, .confirmed, "\(String(describing: confirmed.result))")
    let stored = try JSONDecoder().decode(JSONObject.self, from: storedData(fixture))
    XCTAssertEqual(stored["description"], .string(protected))
  }

  func testMalformedStoredBaseNeverCallsRegistryAndMismatchedProposalWritesNothing() async throws {
    let fixture = try await makeFixture()
    let run = try await mutableTurn(fixture)
    let mismatched = await propose(Self.definition, base: "another-workflow", on: run)
    XCTAssertEqual(mismatched.error?.code, "workflow_invalid")
    XCTAssertEqual(try fixture.store.askActions(conversationId: run.conversationId), [])

    let record: JSONObject = [
      "mode": .string("store"), "definition": .object(Self.definition), "workflowId": .string("authored-workflow"),
      "baseWorkflowId": .string("authored-workflow"), "expectedDefinitionRevision": .string("stale")
    ]
    _ = try fixture.store.insertAskAction(.init(
      conversationId: run.conversationId, turnId: run.turnId, kind: .applyWorkflow, target: record,
      reason: "", createdAt: RoutineStore.timestamp(fixture.now),
      expiresAt: RoutineStore.timestamp(fixture.now.addingTimeInterval(60))
    ), limits: .standard)
    let spy = AskEngineMutationSpy()
    let rejected = try await confirm(fixture, run, mutations: spy)
    let calls = await spy.calls
    XCTAssertEqual(rejected.status, .failed)
    XCTAssertEqual(rejected.result?.code, "action_target_invalid")
    XCTAssertEqual(calls, 0)
  }

  func testStoreProposalRetainsTypedProtectedFields() async throws {
    let fixture = try await makeFixture()
    var proposal = try await projectedDefinitionWithTypedHandles(fixture)
    let before = try storedData(fixture)
    proposal["description"] = .string("Updated through Ask")
    let run = try await mutableTurn(fixture)
    let result = await propose(proposal, base: "authored-workflow", on: run)
    XCTAssertTrue(result.ok, "\(String(describing: result.error)), \(String(describing: result.data))")
    guard result.ok else { return }
    XCTAssertEqual(try storedData(fixture), before)
    let confirmed = try await confirm(fixture, run)
    XCTAssertEqual(confirmed.status, .confirmed, "\(String(describing: confirmed.result))")
    XCTAssertEqual(confirmed.target["definition"], .object(proposal))
    let stored = try JSONDecoder().decode(JSONObject.self, from: storedData(fixture))
    let fields = try typedFields(in: stored)
    XCTAssertEqual(fields.promptBudget, .integer(65_536))
    XCTAssertEqual(fields.inputFilters, Self.inputFilters)
    XCTAssertEqual(stored["description"], proposal["description"])
  }

  func testDraftProposalRetainsTypedProtectedFieldsWithoutRegistryMutation() async throws {
    let fixture = try await makeFixture()
    let draft = try await projectedDefinitionWithTypedHandles(fixture)
    let before = try storedData(fixture)
    var proposal = draft
    proposal["description"] = .string("Changed in draft only")
    let run = try await fixture.makeExecutor(surface: ProviderAskReadSurface(providers: mutableProviders(fixture)), draft: draft)
    let result = await propose(proposal, base: "authored-workflow", on: run)
    XCTAssertTrue(result.ok, "\(String(describing: result.error)), \(String(describing: result.data))")
    guard result.ok else { return }
    let spy = AskEngineMutationSpy()
    let confirmed = try await confirm(fixture, run, mutations: spy)
    XCTAssertEqual(confirmed.status, .confirmed, "\(String(describing: confirmed.result))")
    XCTAssertEqual(confirmed.target["mode"], .string("draft"))
    XCTAssertEqual(confirmed.target["definition"], .object(proposal))
    let calls = await spy.calls
    XCTAssertEqual(calls, 0)
    XCTAssertEqual(try storedData(fixture), before)
  }

  // Use the filter shape from examples/telegram-sdk-trio-chat/workflow.json.
  private static let inputFilters: JSONValue = .array([.object([
    "kind": .string("telegram"), "builtin": .string("mention-responder"),
    "config": .object(["aliases": .array([.string("fixture-bot")]), "defaultResponder": .bool(true)])
  ])])

  private func projectedDefinitionWithTypedHandles(_ fixture: AskToolFixture) async throws -> JSONObject {
    var definition = Self.definition
    guard case var .object(defaults)? = definition["defaults"], case let .array(nodes)? = definition["nodes"],
          case var .object(node)? = nodes.first else {
      throw AskError(code: "test_fixture_invalid", message: "Missing fixture defaults or node")
    }
    defaults["agentPromptMaxBytes"] = .integer(65_536)
    node["inputFilters"] = Self.inputFilters
    definition["defaults"] = .object(defaults)
    definition["nodes"] = .array([.object(node)])
    let registered = try await register(definition, fixture: fixture)
    XCTAssertEqual(registered.status, .confirmed, "\(String(describing: registered.result))")
    let run = try await mutableTurn(fixture)
    let inspected = await inspect(run)
    XCTAssertTrue(inspected.ok, "\(String(describing: inspected.error))")
    guard case let .object(entry)? = inspected.data, case let .object(projected)? = entry["definition"] else {
      throw AskError(code: "test_fixture_invalid", message: "Missing projected definition")
    }
    let fields = try typedFields(in: projected)
    XCTAssertTrue(AskWorkflowDraft.isRetainHandle(fields.promptBudget))
    XCTAssertTrue(AskWorkflowDraft.isRetainHandle(fields.inputFilters))
    return projected
  }

  private func typedFields(in definition: JSONObject) throws -> (promptBudget: JSONValue, inputFilters: JSONValue) {
    guard case let .object(defaults)? = definition["defaults"], case let .array(nodes)? = definition["nodes"],
          case let .object(node)? = nodes.first else {
      throw AskError(code: "test_fixture_invalid", message: "Missing fixture defaults or node")
    }
    return (try XCTUnwrap(defaults["agentPromptMaxBytes"]), try XCTUnwrap(node["inputFilters"]))
  }

  func testInvalidRetainKeyFailsClosedAndIsPreserved() async throws {
    let fixture = try await makeFixture()
    let registered = try await register(Self.definition, fixture: fixture)
    XCTAssertEqual(registered.status, .confirmed)
    let key = URL(fileURLWithPath: fixture.sessions).appendingPathComponent("ask-retain-key")
    let truncated = Data([0])
    try truncated.write(to: key)
    let run = try await mutableTurn(fixture)
    let inspected = await inspect(run)
    XCTAssertEqual(inspected.error?.code, "retain_key_invalid")
    XCTAssertEqual(try Data(contentsOf: key), truncated)
  }

  private func assertSharedRetainKey(_ fixture: AskToolFixture, originId: String, handle: JSONValue) async throws {
    let key = URL(fileURLWithPath: fixture.sessions).appendingPathComponent("ask-retain-key")
    let bytes = try Data(contentsOf: key)
    let attributes = try FileManager.default.attributesOfItem(atPath: key.path)
    XCTAssertEqual(bytes.count, 32)
    XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    let independent = try mutableProviders(fixture).authoringRegistry.get()
    let explicit = FileWorkflowRegistryGraphQLProvider(
      workingDirectory: fixture.root.path, webPrincipalId: "ask", retainKey: bytes, authoringProjection: true
    )
    let target = WorkflowRegistryTarget(workflowId: "authored-workflow", scope: .user, originId: originId)
    for provider in [independent, explicit] {
      let entry = try await CLIRuntimeEnvironment.$captured.withValue(fixture.environment) {
        try await provider.workflow(target: target)
      }
      XCTAssertEqual(entry.definition?["description"], handle)
    }
  }

  private func mutableProviders(_ fixture: AskToolFixture) -> AskReadProviders {
    .local(workingDirectory: fixture.root.path, sessionStore: fixture.sessions, scope: .auto, environment: fixture.environment)
  }

  private func mutableTurn(_ fixture: AskToolFixture) async throws -> AskToolFixture.RunningTurn {
    try await fixture.makeExecutor(surface: ProviderAskReadSurface(providers: mutableProviders(fixture)))
  }

  private func inspect(_ run: AskToolFixture.RunningTurn) async -> AskToolResult {
    await run.executor.execute(
      conversationId: run.conversationId, turnId: run.turnId, toolCallId: UUID().uuidString,
      name: "workflow_inspect", arguments: ["workflowId": .string("authored-workflow")]
    )
  }

  private func register(_ definition: JSONObject, fixture: AskToolFixture) async throws -> AskAction {
    let run = try await mutableTurn(fixture)
    let proposed = await propose(definition, on: run)
    XCTAssertTrue(proposed.ok, "\(String(describing: proposed.error))")
    return try await confirm(fixture, run)
  }

  private func confirm(
    _ fixture: AskToolFixture, _ run: AskToolFixture.RunningTurn, mutations: (any AskMutationSurface)? = nil
  ) async throws -> AskAction {
    let action = try XCTUnwrap(try fixture.store.askActions(conversationId: run.conversationId).first)
    var host = AskHost.local(
      workingDirectory: fixture.root.path, sessionStore: fixture.sessions, scope: .auto, environment: fixture.environment
    )
    let instant = fixture.now
    host.now = { instant }
    let actions = host.actionService()
    let service = mutations.map {
      AskActionService(store: actions.store, proposals: actions.proposals, mutations: $0, now: actions.now)
    } ?? actions
    return try await service.confirm(conversationId: run.conversationId, actionId: action.actionId, decidedBy: "local")
  }

  private func storedData(_ fixture: AskToolFixture) throws -> Data {
    try CLIRuntimeEnvironment.$overrides.withValue(fixture.environment) {
      try Data(contentsOf: WorkflowMutableRegistry().root.appendingPathComponent("authored-workflow/workflow.json"))
    }
  }

  private func makeFixture() async throws -> AskToolFixture {
    try await AskToolFixture(test: self, evidencePlan: "ask-06-workflow-authoring")
  }

  private func propose(_ definition: JSONObject, base: String? = nil, on run: AskToolFixture.RunningTurn) async -> AskToolResult {
    var arguments: JSONObject = ["definition": .object(definition)]
    arguments["baseWorkflowId"] = base.map(JSONValue.string)
    return await run.executor.execute(
      conversationId: run.conversationId, turnId: run.turnId, toolCallId: UUID().uuidString,
      name: "propose_workflow", arguments: arguments
    )
  }
}
