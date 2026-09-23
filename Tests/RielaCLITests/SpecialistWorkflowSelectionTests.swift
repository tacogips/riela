import Foundation
import XCTest
import RielaCore
import RielaWorkflowRegistry
@testable import RielaCLI

final class SpecialistWorkflowSelectionTests: XCTestCase {
  func testSelectionReturnsOnlyAnExactSuppliedOriginAndRevision() async throws {
    let card = card()
    let provider = provider(payload: [
      "workflowId": .string(card.workflowId), "originId": .string(card.originId), "revision": .string(card.revision)
    ])
    let selected = try await provider.selectWorkflow(
      request: request(), specialist: .init(id: "engineering", capacity: 1, domain: "software", allowedOriginIds: ["origin"]),
      deadline: Date().addingTimeInterval(30)
    )
    XCTAssertEqual(selected, card)
  }

  func testModelCannotInventOriginOrRevision() async {
    for changedKey in ["originId", "revision", "workflowId"] {
      var payload: JSONObject = ["workflowId": .string("build"), "originId": .string("origin"), "revision": .string("revision")]
      payload[changedKey] = .string("invented")
      do {
        _ = try await provider(payload: payload).selectWorkflow(
          request: request(), specialist: .init(id: "engineering", capacity: 1, domain: "software", allowedOriginIds: ["origin"]),
          deadline: Date().addingTimeInterval(30)
        )
        XCTFail("Selection must reject a changed \(changedKey)")
      } catch let error as SpecialistClassifierError {
        XCTAssertEqual(error, .invalidResponse)
      } catch {
        XCTFail("Expected invalid workflow selection for \(changedKey), got \(error)")
      }
    }
  }

  func testUnauthorizedSecretCanaryNeverReachesSelectorPrompt() async throws {
    let authorized = card()
    let canary = WorkflowCompactCatalogCard(
      workflowId: "forbidden-secret-workflow", workflowName: "FORBIDDEN_CANARY", shortSummary: "FORBIDDEN_SECRET_CANARY",
      tags: ["FORBIDDEN_SECRET_CANARY"], domain: "secret", originId: "forbidden-origin",
      sourceKind: .workflow, scope: .project, provenance: .immutable, revision: "forbidden", active: true
    )
    let adapter = CapturingSelectionAdapter(payload: [
      "workflowId": .string(authorized.workflowId), "originId": .string(authorized.originId), "revision": .string(authorized.revision)
    ])
    let classifier = SpecialistRielaClassifier(
      node: AgentNodePayload(id: "planner", executionBackend: .officialOpenAISDK, model: "fixture"),
      cards: [authorized, canary], adapter: adapter
    )
    _ = try await classifier.selectWorkflow(
      request: request(), specialist: .init(id: "engineering", capacity: 1, domain: "software", allowedOriginIds: ["origin"]),
      deadline: Date().addingTimeInterval(30)
    )
    let prompt = await adapter.prompt
    XCTAssertFalse(prompt.contains("FORBIDDEN_SECRET_CANARY"))
    XCTAssertFalse(prompt.contains("forbidden-origin"))
  }

  private func provider(payload: JSONObject) -> SpecialistRielaClassifier {
    SpecialistRielaClassifier(
      node: AgentNodePayload(id: "planner", executionBackend: .officialOpenAISDK, model: "fixture"),
      cards: [card()], adapter: SelectionFixtureAdapter(payload: payload)
    )
  }

  private func card() -> WorkflowCompactCatalogCard {
    WorkflowCompactCatalogCard(
      workflowId: "build", workflowName: "Build", shortSummary: "Build software", tags: [], domain: "software",
      originId: "origin", sourceKind: .workflow, scope: .project, provenance: .immutable, revision: "revision", active: true
    )
  }

  private func request() -> SpecialistRequest {
    SpecialistRequest(
      requestId: "request", sourceEventId: "event",
      principal: SpecialistPrincipal(accountId: "account", actorId: "actor", roomId: "room"),
      route: .work, body: "Build this project"
    )
  }
}

private struct SelectionFixtureAdapter: NodeAdapter {
  let payload: JSONObject

  func execute(_ input: AdapterExecutionInput, context _: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    AdapterExecutionOutput(provider: "fixture", model: "fixture", promptText: input.promptText, completionPassed: true, payload: payload)
  }
}

private actor CapturingSelectionAdapter: NodeAdapter {
  let payload: JSONObject
  var prompt = ""
  init(payload: JSONObject) { self.payload = payload }
  func execute(_ input: AdapterExecutionInput, context _: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    prompt = input.promptText
    return AdapterExecutionOutput(provider: "fixture", model: "fixture", promptText: input.promptText, completionPassed: true, payload: payload)
  }
}
