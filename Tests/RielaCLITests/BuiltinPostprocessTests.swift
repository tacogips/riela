import Foundation
import RielaAdapters
import RielaCore
import XCTest
@testable import RielaCLI

final class BuiltinPostprocessTests: XCTestCase {
  func testScenarioUsesSamePostprocessAndRejectsInvalidProgramsBeforeConsumingResponse() async throws {
    let resolver = ScenarioWorkflowAddonResolver(scenario: .init(responses: ["gateway": [
      MockNodeResponse(payload: ["rows": .array([.string("first"), .string("second")])])
    ]]), fallback: BuiltinWorkflowAddonResolver(environment: [:]))
    let valid = request("riela/gmail-gateway-reader", steps: .array([
      .object(["pick": .string("/rows")]), .object(["take": .integer(1)])
    ]))
    let output = try await resolver.execute(valid, context: .init())
    XCTAssertEqual(output.payload["processed"], .array([.string("first")]))
    XCTAssertEqual(output.when["postprocessPassed"], true)
    do {
      _ = try await resolver.execute(request("riela/gmail-gateway-reader", steps: .array([
        .object(["eval": .string("run()")])
      ])), context: .init())
      XCTFail("scenario must reject the same invalid program")
    } catch { XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidInput) }
    let counts = await resolver.consumedResponseCounts()
    XCTAssertEqual(counts["gateway"], 1)
  }

  func testSharedGraphQLPostprocessPreservesPaginationAndSourceStrings() async throws {
    for name in ["riela/gmail-gateway-reader", "riela/wrike-gateway-read", "riela/google-analytics-gateway-read"] {
      let gateway = RecordingGatewayGraphQLRunner(response:
        #"{"data":{"items":[{"id":"1","text":"{{secret}}"}],"cursor":"page-2"}}"#)
      let input = request(name, steps: .array([
        .object(["pick": .string("/data/items")]),
        .object(["map": .object(["id": .string("/id"), "text": .string("/text")])])
      ]))
      let output = try await BuiltinWorkflowAddonResolver(environment: [:], localGatewayGraphQLRunner: gateway.runner)
        .execute(input, context: .init())
      XCTAssertEqual(gateway.allCalls().count, 1)
      XCTAssertEqual(output.payload["processed"], .array([.object(["id": .string("1"), "text": .string("{{secret}}")])]))
      XCTAssertEqual(output.payload["data"], .object(["items": .array([.object([
        "id": .string("1"), "text": .string("{{secret}}")])]), "cursor": .string("page-2")]))
      XCTAssertEqual(output.when["postprocessPassed"], true)
    }
  }

  func testInvalidLaterInstructionStopsBeforeProviderWrite() async throws {
    let gateway = RecordingGatewayGraphQLRunner()
    var input = request("riela/wrike-gateway-write", steps: .array([
      .object(["pick": .string("/missing")]), .object(["eval": .string("execute()")])
    ]))
    input.addon.config?["queryTemplate"] = .string("mutation { createTask { id } }")
    do {
      _ = try await BuiltinWorkflowAddonResolver(environment: [:], localGatewayGraphQLRunner: gateway.runner)
        .execute(input, context: .init())
      XCTFail("invalid finite program must be rejected before a provider effect")
    } catch {
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidInput)
    }
    XCTAssertTrue(gateway.allCalls().isEmpty)
  }

  func testPostWriteShapeFailureReturnsProviderResultOnce() async throws {
    let gateway = RecordingGatewayGraphQLRunner(response: #"{"data":{"createTask":{"id":"created-1"}}}"#)
    var input = request("riela/wrike-gateway-write", steps: .array([
      .object(["pick": .string("/data/createTask")]), .object(["take": .integer(1)])
    ]))
    input.addon.config?["queryTemplate"] = .string("mutation { createTask { id } }")
    let output = try await BuiltinWorkflowAddonResolver(environment: [:], localGatewayGraphQLRunner: gateway.runner)
      .execute(input, context: .init())
    XCTAssertEqual(gateway.allCalls().count, 1)
    XCTAssertTrue(output.completionPassed)
    XCTAssertEqual(output.payload["data"], .object(["createTask": .object(["id": .string("created-1")])]))
    XCTAssertNil(output.payload["processed"])
    XCTAssertEqual(output.payload["postprocess"], .object([
      "status": .string("failed"), "reason": .string("input-shape-or-limit"), "retryProvider": .bool(false)
    ]))
    XCTAssertEqual(output.when["postprocessFailed"], true)
  }

  func testOuterResolverAppliesProgramOnceAndPreservesInternalReceipt() async throws {
    let receipt = WorkflowAddonFinalizationToken(value: "fixture-receipt")
    let primary = PostprocessFixtureResolver(receipt: receipt)
    let resolver = BuiltinAddonContainerResolver(primary: primary, environment: [:],
      workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    let output = try await resolver.execute(request("riela/notion-gateway-write", steps: .array([
      .object(["pick": .string("/rows")]), .object(["take": .integer(1)])
    ])), context: .init())
    XCTAssertEqual(output.payload["processed"], .array([.string("first")]))
    XCTAssertEqual(output.runtimeFinalizationToken, receipt)
    XCTAssertEqual(output.when["postprocessPassed"], true)
    let count = await primary.count
    XCTAssertEqual(count, 1)
  }

  private func request(_ name: String, steps: JSONValue) -> WorkflowAddonExecutionInput {
    .init(workflowId: "fixture", stepId: "gateway", nodeId: "gateway",
      addon: .init(name: name, version: "1", config: [
        "queryTemplate": .string("{ items { id text } }"), "postprocess": steps
      ]), variables: ["secret": .string("must-not-expand")])
  }
}

private actor PostprocessFixtureResolver: WorkflowAddonResolving {
  let receipt: WorkflowAddonFinalizationToken
  private(set) var count = 0

  init(receipt: WorkflowAddonFinalizationToken) { self.receipt = receipt }

  func execute(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    count += 1
    XCTAssertNil(input.addon.config?["postprocess"], "the finite program must not reach another worker")
    return .init(provider: "fixture", model: "fixture", promptText: "", completionPassed: true,
      payload: ["rows": .array([.string("first"), .string("second")])], runtimeFinalizationToken: receipt)
  }
}
