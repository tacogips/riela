import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

@MainActor
final class AskReadOnlyTests: XCTestCase {
  func testFullToolInventoryCannotInvokeTheMutationSurface() async throws {
    let fixture = try await AskToolFixture(test: self)
    try await fixture.seedDefinitionAudit()
    let run = try await fixture.makeExecutor()
    let surface = ProviderAskReadSurface(providers: fixture.providers)
    let instant = fixture.now
    let proposals = AskActionProposer(surface: surface, store: fixture.store, environment: fixture.environment, now: { instant })
    let spy = AskToolMutationSpy()
    let actions = AskActionService(
      store: fixture.store, proposals: proposals, mutations: spy, environment: fixture.environment, now: { instant }
    )

    let descriptors = AskToolSet.all
    XCTAssertTrue(descriptors.allSatisfy { $0.kind == .read || $0.kind == .propose })
    XCTAssertEqual(descriptors.filter { $0.kind == .propose }.map(\.name), ["propose_action"])
    let proposal = AskToolCase(name: "propose_action", arguments: [
      "kind": .string(AskActionKind.setBotPaused.rawValue),
      "target": .object(["botId": .string(AskToolFixture.botId), "paused": .bool(true)]),
      "reason": .string("The model proposed a pause")
    ])
    let probes = fixture.readCases + [proposal]
    XCTAssertEqual(Set(probes.map(\.name)), Set(descriptors.map(\.name)))
    for probe in probes {
      let result = await run.executor.execute(
        conversationId: run.conversationId, turnId: run.turnId, toolCallId: probe.name,
        name: probe.name, arguments: probe.arguments
      )
      XCTAssertTrue(result.ok, "\(probe.name): \(String(describing: result.error))")
    }
    let callsBeforeConfirm = await spy.calls
    XCTAssertEqual(callsBeforeConfirm, [])
    XCTAssertEqual(try fixture.store.load(botId: AskToolFixture.botId)?.paused, false)
    let proposed = try fixture.store.askActions(conversationId: run.conversationId)
    XCTAssertEqual(proposed.map(\.status), [.proposed])

    let actionId = try XCTUnwrap(proposed.first?.actionId)
    let confirmed = try await actions.confirm(conversationId: run.conversationId, actionId: actionId, decidedBy: "local")
    let callsAfterConfirm = await spy.calls
    XCTAssertEqual(confirmed.status, .confirmed)
    XCTAssertEqual(callsAfterConfirm, [.setBotPaused])
  }
}

private actor AskToolMutationSpy: AskMutationSurface {
  private(set) var calls: [AskActionKind] = []

  func stopSession(sessionId: String, workflowId: String) -> AskActionResult {
    record(.stopSession)
  }

  func rerunSession(sessionId: String, workflowId: String, stepId: String) -> AskActionResult {
    record(.rerunSession)
  }

  func answerBotRequest(requestId: String, optionId: String?, decline: Bool) -> AskActionResult {
    record(.answerBotRequest)
  }

  func setBotPaused(botId: String, paused: Bool) -> AskActionResult {
    record(.setBotPaused)
  }

  private func record(_ kind: AskActionKind) -> AskActionResult {
    calls.append(kind)
    return AskActionResult(ok: true, ids: [])
  }
}
