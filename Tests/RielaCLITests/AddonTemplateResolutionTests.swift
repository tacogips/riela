import XCTest
import RielaAddonSupport
@testable import RielaCore

final class AddonTemplateResolutionTests: XCTestCase {
  func testMissingPayloadReferenceReportsProducerPathAndConsumer() throws {
    let input = addonInput(
      config: ["commitMessage": .string("{{inbox.latest.output.payload.commitMessage}}")],
      resolvedInput: metadata(fromStepId: "producer", payload: [:])
    )
    XCTAssertThrowsError(try addonVariables(for: input)) { error in
      guard let adapterError = error as? AdapterExecutionError else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertEqual(adapterError.code, .templateResolutionFailed)
      XCTAssertTrue(adapterError.message.contains("producer"))
      XCTAssertTrue(adapterError.message.contains("commitMessage"))
      XCTAssertTrue(adapterError.message.contains("consumer-step"))
      XCTAssertTrue(adapterError.message.contains("consumer-node"))
      XCTAssertTrue(adapterError.message.contains("riela/git-commit"))
    }
  }

  func testProducerFallsBackToSoleSourceStepId() throws {
    var resolved = metadata(fromStepId: nil, payload: [:])
    if case var .object(metadata)? = resolved["_rielaInput"] {
      metadata["sourceStepIds"] = .array([.string("fallback-producer")])
      resolved["_rielaInput"] = .object(metadata)
    }
    let input = addonInput(config: ["value": .string("{{missingField}}")], resolvedInput: resolved)
    XCTAssertThrowsError(try addonVariables(for: input)) { error in
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("fallback-producer") == true)
    }
  }

  func testMissingContextRemainsLenientAndConfigCanReadRenderedInput() throws {
    let input = WorkflowAddonExecutionInput(
      workflowId: "workflow", stepId: "consumer-step", nodeId: "consumer-node",
      addon: WorkflowNodeAddonRef(
        name: "riela/memory-save",
        config: [
          "optional": .string("{{event.input.attachmentText}}"),
          "copied": .string("{{results}}")
        ],
        inputs: ["results": .string("{{input.results}}")]
      ),
      resolvedInputPayload: metadata(fromStepId: "producer", payload: ["results": .array([.string("ok")])])
    )
    let variables = try addonVariables(for: input)
    XCTAssertEqual(variables["results"], .array([.string("ok")]))
    let rendered = try renderAddonConfig(.object(input.addon.config ?? [:]), variables: variables)
    guard case let .object(config) = rendered else { return XCTFail("expected object") }
    XCTAssertEqual(config["optional"], .string(""))
    XCTAssertEqual(config["copied"], .array([.string("ok")]))
  }

  func testPayloadReferenceInsideInputsIsStrict() throws {
    let input = WorkflowAddonExecutionInput(
      workflowId: "workflow", stepId: "consumer-step", nodeId: "consumer-node",
      addon: WorkflowNodeAddonRef(
        name: "riela/example", config: ["copy": .string("{{results}}")],
        inputs: ["results": .string("{{missingPayload}}")]
      ),
      resolvedInputPayload: metadata(fromStepId: "producer", payload: [:])
    )
    XCTAssertThrowsError(try addonVariables(for: input)) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .templateResolutionFailed)
    }
  }

  func testBareDeclaredNameIsStrictAndWorkflowInputNamespaceResolves() throws {
    let missing = addonInput(
      config: ["team": .string("{{teamName}}")],
      resolvedInput: metadata(fromStepId: "producer", payload: [:])
    )
    XCTAssertThrowsError(try addonVariables(for: missing)) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .templateResolutionFailed)
    }

    let namespaced = WorkflowAddonExecutionInput(
      workflowId: "workflow", stepId: "consumer-step", nodeId: "consumer-node",
      addon: WorkflowNodeAddonRef(
        name: "riela/git-commit",
        config: ["team": .string("{{workflowInput.teamName}}")]
      ),
      variables: ["workflowInput": .object(["teamName": .string("platform")])],
      resolvedInputPayload: metadata(fromStepId: "producer", payload: [:])
    )
    let variables = try addonVariables(for: namespaced)
    guard case let .object(rendered) = try renderAddonConfig(
      .object(namespaced.addon.config ?? [:]),
      variables: variables
    ) else {
      return XCTFail("expected rendered config")
    }
    XCTAssertEqual(rendered["team"], .string("platform"))
  }

  private func addonInput(config: JSONObject, resolvedInput: JSONObject) -> WorkflowAddonExecutionInput {
    WorkflowAddonExecutionInput(
      workflowId: "workflow", stepId: "consumer-step", nodeId: "consumer-node",
      addon: WorkflowNodeAddonRef(name: "riela/git-commit", config: config),
      resolvedInputPayload: resolvedInput
    )
  }

  private func metadata(fromStepId: String?, payload: JSONObject) -> JSONObject {
    var latest: JSONObject = ["payload": .object(payload)]
    if let fromStepId { latest["fromStepId"] = .string(fromStepId) }
    var result = payload
    result["_rielaInput"] = .object(["latest": .object(latest)])
    return result
  }
}
