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
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidOutput)
      XCTAssertFalse(String(describing: error).contains("outside"))
    }
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
