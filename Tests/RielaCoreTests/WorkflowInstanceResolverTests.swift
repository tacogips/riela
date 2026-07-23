import XCTest
@testable import RielaCore

final class WorkflowInstanceResolverTests: XCTestCase {
  func testDefaultInstanceHasEmptyConfigurationAndUnchangedPayloads() throws {
    let payloads = ["worker": payload(id: "worker", model: "gpt-5")]

    let resolved = try WorkflowInstanceResolver.resolve(
      workflowId: "wf",
      base: nil,
      nodePayloads: payloads
    )

    XCTAssertEqual(resolved.instance.identity, "default")
    XCTAssertEqual(resolved.instance.kind, .default)
    XCTAssertNil(resolved.instance.baseIdentity)
    XCTAssertEqual(resolved.instance.configuration, WorkflowInstanceConfiguration())
    XCTAssertEqual(resolved.nodePayloads["worker"]?.model, "gpt-5")
  }

  func testNamedInstanceAndRunOverridesUseExpectedPrecedence() throws {
    let base = WorkflowInstanceDefinition(
      identity: "prod",
      workflowId: "wf",
      configuration: WorkflowInstanceConfiguration(
        defaultVariables: ["tone": .string("formal"), "region": .string("jp")],
        nodePatches: ["worker": WorkflowInstanceNodePatch(model: "gpt-5-mini", effort: .medium)]
      )
    )

    let resolved = try WorkflowInstanceResolver.resolve(
      workflowId: "wf",
      base: base,
      runVariables: ["tone": .string("urgent")],
      runNodePatch: ["worker": WorkflowInstanceNodePatch(model: "gpt-5.1", effort: .high)],
      nodePayloads: ["worker": payload(id: "worker", model: "gpt-5")]
    )

    XCTAssertEqual(resolved.instance.identity, "prod+overrides")
    XCTAssertEqual(resolved.instance.kind, .ephemeral)
    XCTAssertEqual(resolved.instance.baseIdentity, "prod")
    XCTAssertEqual(resolved.instance.configuration.defaultVariables["tone"], .string("urgent"))
    XCTAssertEqual(resolved.instance.configuration.defaultVariables["region"], .string("jp"))
    XCTAssertEqual(resolved.nodePayloads["worker"]?.model, "gpt-5.1")
    XCTAssertEqual(resolved.nodePayloads["worker"]?.effort, .high)
  }

  func testHistoricalTemporaryInstanceKindDecodesAsEphemeral() throws {
    let decoded = try JSONDecoder().decode(
      WorkflowInstanceKind.self,
      from: Data(#""temporary""#.utf8)
    )
    XCTAssertEqual(decoded, .ephemeral)
    XCTAssertEqual(String(data: try JSONEncoder().encode(decoded), encoding: .utf8), #""ephemeral""#)
  }

  func testFrozenModelRejectsInstanceLayerPatch() throws {
    let base = WorkflowInstanceDefinition(
      identity: "prod",
      workflowId: "wf",
      configuration: WorkflowInstanceConfiguration(
        nodePatches: ["worker": WorkflowInstanceNodePatch(model: "gpt-5.1")]
      )
    )

    XCTAssertThrowsError(try WorkflowInstanceResolver.resolve(
      workflowId: "wf",
      base: base,
      nodePayloads: ["worker": payload(id: "worker", model: "gpt-5", modelFreeze: true)]
    )) { error in
      XCTAssertEqual(error as? WorkflowInstanceResolutionError, .modelChangeFrozen("worker"))
    }
  }

  func testNodePatchJSONObjectParserRejectsUnsupportedFields() throws {
    XCTAssertThrowsError(try WorkflowInstanceResolver.nodePatches(from: [
      "worker": .object(["temperature": .number(0.2)])
    ])) { error in
      XCTAssertEqual(error as? WorkflowInstanceResolutionError, .unsupportedField("temperature"))
    }
  }

  private func payload(id: String, model: String, modelFreeze: Bool = false) -> AgentNodePayload {
    AgentNodePayload(id: id, executionBackend: .codexAgent, model: model, modelFreeze: modelFreeze)
  }
}
