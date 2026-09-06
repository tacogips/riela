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

  func testKaibaInstancePatchProjectsOnlyIntoEffectiveKaibaAddonConfig() throws {
    let nodes = [
      WorkflowNodeRef(
        id: "search",
        addon: WorkflowNodeAddonRef(name: "kaiba/note-search", config: ["query": .string("old")])
      )
    ]

    let patched = try WorkflowInstanceResolver.applyKaibaInstancePatches(
      ["search": WorkflowInstanceNodePatch(kaibaInstanceId: "named-instance")],
      to: nodes
    )

    XCTAssertEqual(patched[0].addon?.config?["query"], .string("old"))
    XCTAssertEqual(patched[0].addon?.config?["kaibaInstanceId"], .string("named-instance"))
  }

  func testRunPatchPreservesInheritedKaibaBindingWhileOverridingModel() throws {
    let base = WorkflowInstanceDefinition(
      identity: "prod",
      workflowId: "wf",
      configuration: WorkflowInstanceConfiguration(
        nodePatches: ["search": WorkflowInstanceNodePatch(kaibaInstanceId: "named-instance")]
      )
    )

    let resolved = try WorkflowInstanceResolver.resolve(
      workflowId: "wf",
      base: base,
      runNodePatch: ["search": WorkflowInstanceNodePatch(model: "gpt-5.1")],
      nodePayloads: ["search": payload(id: "search", model: "gpt-5")]
    )

    XCTAssertEqual(resolved.instance.configuration.nodePatches["search"]?.kaibaInstanceId, "named-instance")
    XCTAssertEqual(resolved.instance.configuration.nodePatches["search"]?.model, "gpt-5.1")
  }

  func testKaibaInstancePatchResetRemovesOnlyBinding() throws {
    let nodes = [
      WorkflowNodeRef(
        id: "search",
        addon: WorkflowNodeAddonRef(
          name: "kaiba/note-search",
          config: ["query": .string("old"), "kaibaInstanceId": .string("named-instance")]
        )
      )
    ]

    let patched = try WorkflowInstanceResolver.applyKaibaInstancePatches(
      ["search": WorkflowInstanceNodePatch(clearsKaibaInstanceId: true)],
      to: nodes
    )

    XCTAssertEqual(patched[0].addon?.config?["query"], .string("old"))
    XCTAssertNil(patched[0].addon?.config?["kaibaInstanceId"])
  }

  private func payload(id: String, model: String, modelFreeze: Bool = false) -> AgentNodePayload {
    AgentNodePayload(id: id, executionBackend: .codexAgent, model: model, modelFreeze: modelFreeze)
  }
}
