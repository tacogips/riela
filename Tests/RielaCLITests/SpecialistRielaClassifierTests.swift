import Foundation
import XCTest
import RielaCore
@testable import RielaCLI

final class SpecialistRielaClassifierTests: XCTestCase {
  func testConfiguredSpecialistsReceiveIndependentSDKRequests() async throws {
    let adapter = ClassifierCaptureAdapter()
    let provider = makeProvider(adapter)
    let decisions = try await provider.classify(
      request: request(), specialists: specialists(), deadline: Date().addingTimeInterval(30)
    )
    XCTAssertEqual(decisions.map(\.specialistId), ["engineering", "finance"])
    let inputs = await adapter.inputs
    XCTAssertEqual(inputs.count, 2)
    for input in inputs {
      XCTAssertEqual(input.node.executionBackend, .officialOpenAISDK)
      XCTAssertNotNil(input.node.output?.jsonSchema)
      XCTAssertNil(input.sessionPolicy)
      XCTAssertFalse(input.promptText.contains("workflowDirectory"))
      XCTAssertFalse(input.promptText.contains("promptTemplate"))
    }
  }

  func testCodingAgentBackendIsRejectedBeforeInvocation() async {
    let adapter = ClassifierCaptureAdapter()
    let provider = SpecialistRielaClassifier(
      node: AgentNodePayload(id: "classifier", executionBackend: .codexAgent, model: "fixture"),
      cards: [], adapter: adapter
    )
    do {
      _ = try await provider.classify(request: request(), specialists: specialists(), deadline: Date().addingTimeInterval(30))
      XCTFail("Classification must not start a coding agent with command tools")
    } catch let error as SpecialistClassifierError {
      XCTAssertEqual(error, .unavailable)
    } catch {
      XCTFail("Expected unavailable classifier backend, got \(error)")
    }
    let inputs = await adapter.inputs
    XCTAssertTrue(inputs.isEmpty)
  }

  func testModelCannotSubstituteSpecialistIdentity() async {
    let provider = makeProvider(ClassifierCaptureAdapter(substituteIdentity: true))
    let decisions = try? await provider.classify(
      request: request(), specialists: specialists(), deadline: Date().addingTimeInterval(30)
    )
    XCTAssertEqual(decisions?.map(\.kind), [.unavailable, .unavailable],
                   "An identity substitution is sealed as unavailable, never accepted as a claim")
  }

  func testExpiredRoundNeverInvokesProvider() async {
    let adapter = ClassifierCaptureAdapter()
    do {
      _ = try await makeProvider(adapter).classify(
        request: request(), specialists: specialists(), deadline: Date().addingTimeInterval(-1)
      )
      XCTFail("Expired round must fail before invocation")
    } catch let error as SpecialistClassifierError {
      XCTAssertEqual(error, .unavailable)
    } catch {
      XCTFail("Expected unavailable classifier for an expired round, got \(error)")
    }
    let inputs = await adapter.inputs
    XCTAssertTrue(inputs.isEmpty)
  }

  func testClassifierSecretProviderAcceptsOnlyNamedNonemptyEnvironmentSecret() throws {
    let provider = EnvironmentSpecialistSecretProvider(environment: ["RIELA_CLASSIFIER_TOKEN": "secret"])
    XCTAssertEqual(try provider.secret(named: "RIELA_CLASSIFIER_TOKEN"), "secret")
    XCTAssertThrowsError(try provider.secret(named: "token"))
    XCTAssertThrowsError(try provider.secret(named: "MISSING_TOKEN"))
  }

  private func makeProvider(_ adapter: ClassifierCaptureAdapter) -> SpecialistRielaClassifier {
    SpecialistRielaClassifier(
      node: AgentNodePayload(id: "classifier", executionBackend: .officialOpenAISDK, model: "fixture"),
      cards: [], adapter: adapter
    )
  }

  private func request() -> SpecialistRequest {
    SpecialistRequest(
      requestId: "request", sourceEventId: "event",
      principal: SpecialistPrincipal(accountId: "account", actorId: "actor", roomId: "room"),
      route: .work, body: "Review this request"
    )
  }

  private func specialists() -> [SpecialistConfiguredSpecialist] {
    [.init(id: "engineering", capacity: 1, domain: "software"), .init(id: "finance", capacity: 1, domain: "finance")]
  }
}

private actor ClassifierCaptureAdapter: NodeAdapter {
  var inputs: [AdapterExecutionInput] = []
  let substituteIdentity: Bool

  init(substituteIdentity: Bool = false) { self.substituteIdentity = substituteIdentity }

  func execute(_ input: AdapterExecutionInput, context _: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    inputs.append(input)
    let object = try JSONDecoder().decode(JSONObject.self, from: Data(input.promptText.utf8))
    let identity = substituteIdentity ? JSONValue.string("injected") : object["specialistId"] ?? .null
    return AdapterExecutionOutput(
      provider: "fixture", model: "fixture", promptText: input.promptText, completionPassed: true,
      payload: ["specialistId": identity, "kind": .string("claim"), "reason": .string("in domain")]
    )
  }
}
