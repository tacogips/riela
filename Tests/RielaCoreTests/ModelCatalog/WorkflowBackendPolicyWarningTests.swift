import XCTest
@testable import RielaCore

final class WorkflowBackendPolicyWarningTests: XCTestCase {
  func testUnknownModelProducesExactlyOneWarning() {
    let policy = WorkflowBackendPolicy(allowed: [.codexAgent], modelByBackend: [.codexAgent: "unknown"])
    let diagnostics = WorkflowBackendPolicyValidation.diagnostics(
      pin: nil, policy: policy, knownModels: [.codexAgent: ["known"]], path: "node.agent"
    )
    XCTAssertEqual(diagnostics, [
      .init(severity: .warning, path: "node.agent.backendPolicy.modelByBackend.codex-agent", message: "model_unknown: is not known for this backend")
    ])
  }

  func testDefaultSentinelIsKnownEvenWhenOmittedFromKnownModels() {
    let policy = WorkflowBackendPolicy(allowed: [.codexAgent], modelByBackend: [.codexAgent: ModelSentinel.defaultModel])
    XCTAssertEqual(WorkflowBackendPolicyValidation.diagnostics(
      pin: nil, policy: policy, knownModels: [.codexAgent: ["known"]]
    ), [])
  }
}
