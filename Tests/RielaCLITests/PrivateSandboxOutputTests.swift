import RielaCore
import XCTest
@testable import RielaCLI

final class PrivateSandboxOutputTests: XCTestCase {
  func testGuestValidatesPayloadAndReturnsNoPromptOrRawProviderMetadata() throws {
    let contract = NodeOutputContract(jsonSchema: ["type": .string("object"), "additionalProperties": .bool(false),
      "required": .array([.string("id")]), "properties": .object([
        "id": .object(["enum": .array([.string("allowed")])])])])
    var output = AdapterExecutionOutput(provider: "fixture", model: "fixture", promptText: "PRIVATE_INPUT_BODY",
      completionPassed: true, payload: ["id": .string("allowed")],
      usage: .init(inputTokens: 3, outputTokens: 2, providerRaw: ["tool_output": .string("PRIVATE_PROVIDER_BODY")]))
    let accepted = try SandboxNodeWorker.privateOutput(output, contract: contract)
    XCTAssertEqual(accepted.payload, output.payload)
    XCTAssertEqual(accepted.promptText, "")
    XCTAssertEqual(accepted.usage?.inputTokens, 3)
    XCTAssertEqual(accepted.usage?.providerRaw, [:])
    output.payload["id"] = .string("outside")
    XCTAssertThrowsError(try SandboxNodeWorker.privateOutput(output, contract: contract)) { error in
      // A contract miss is a retryable validation rejection with fixed text.
      XCTAssertEqual(error as? WorkflowPublicationError, .validationRejected(SandboxNodeWorker.privateRejectionMessage))
      XCTAssertFalse(String(describing: error).contains("outside"))
    }
    output.payload["id"] = .string("allowed")
    output.completionPassed = false
    XCTAssertThrowsError(try SandboxNodeWorker.privateOutput(output, contract: contract)) { error in
      XCTAssertEqual(error as? WorkflowPublicationError, .validationRejected(SandboxNodeWorker.privateRejectionMessage))
    }
  }

  func testRoutingLabelsAndVendorMetadataAreBoundedAtThePrivateBoundary() throws {
    let contract = NodeOutputContract(jsonSchema: ["type": .string("object")])
    var output = AdapterExecutionOutput(provider: "codex-agent", model: "gpt-5.5-codex", promptText: "",
      completionPassed: true, when: ["always": true, "needs-work": false, "review.ok_1": true], payload: [:])
    let accepted = try SandboxNodeWorker.privateOutput(output, contract: contract, configuredModel: "configured")
    XCTAssertEqual(accepted.when, output.when)
    XCTAssertEqual(accepted.model, "gpt-5.5-codex")
    XCTAssertEqual(accepted.provider, "codex-agent")
    let tooMany = Dictionary(uniqueKeysWithValues: (0...SandboxNodeWorker.maximumPrivateRoutingLabels).map { ("l\($0)", true) })
    for when: [String: Bool] in [["PRIVATE SOURCE SENTENCE": true], [String(repeating: "a", count: 65): true],
                                 ["": true], ["line\nbreak": true], tooMany] {
      output.when = when
      XCTAssertThrowsError(try SandboxNodeWorker.privateOutput(output, contract: contract)) { error in
        XCTAssertEqual(error as? WorkflowPublicationError, .validationRejected(SandboxNodeWorker.privateRejectionMessage))
      }
    }
    output.when = ["always": true]
    output.model = "vendor reported PRIVATE TEXT"
    output.provider = "provider\nPRIVATE"
    let normalized = try SandboxNodeWorker.privateOutput(output, contract: contract, configuredModel: "configured")
    XCTAssertEqual(normalized.model, "configured")
    XCTAssertEqual(normalized.provider, "unreported")
    XCTAssertEqual(try SandboxNodeWorker.privateOutput(output, contract: contract, configuredModel: "bad model").model,
      "unreported")
  }

  func testMissingUnsupportedOrNonobjectContractsCannotStartPrivateModel() {
    for contract: NodeOutputContract? in [nil, .init(), .init(jsonSchema: ["if": .object([:])]),
      .init(jsonSchema: ["type": .string("string")])] {
      XCTAssertThrowsError(try SandboxNodeWorker.privateContract(contract))
    }
  }

  func testPrivateFailuresRetainFiniteCodeAndDiscardFreeformProviderText() {
    let source = AdapterExecutionError(.providerError, "PRIVATE_PROVIDER_BODY", isRetryable: true)
    let failure = SandboxNodeWorker.privateFailure(source)
    XCTAssertEqual(failure.code, .providerError)
    XCTAssertEqual(failure.message, "ephemeral agent execution failed")
    XCTAssertEqual(failure.isRetryable, true)
  }
}
