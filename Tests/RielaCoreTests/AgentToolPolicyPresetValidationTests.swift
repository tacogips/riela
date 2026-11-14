import Foundation
import XCTest
@testable import RielaCore

final class AgentToolPolicyPresetValidationTests: XCTestCase {
  func testSupportedBackendsAndPresetModesHaveNoPresetDiagnostics() {
    for mode: AgentToolPolicyMode? in [nil, .backendArguments] {
      XCTAssertTrue(presetDiagnostics(payload(
        backend: .codexAgent,
        preset: .noTools,
        mode: mode
      )).isEmpty)
    }

    for backend in [
      NodeExecutionBackend.officialOpenAISDK,
      .officialAnthropicSDK,
      .officialGeminiSDK,
      .claudeCodeAgent
    ] {
      XCTAssertTrue(presetDiagnostics(payload(backend: backend, preset: .webSearch)).isEmpty)
    }
    XCTAssertTrue(presetDiagnostics(payload(backend: .officialCursorSDK, preset: .noTools)).isEmpty)
  }

  func testBackendDefaultModeIsRejected() throws {
    let diagnostic = try XCTUnwrap(presetDiagnostics(payload(
      backend: .codexAgent,
      preset: .noTools,
      mode: .backendDefault
    )).first)

    XCTAssertEqual(diagnostic.path, "node.agentToolPolicy.mode")
    XCTAssertEqual(diagnostic.severity, .error)
    XCTAssertEqual(diagnostic.message, "cannot be combined with agentToolPolicy.preset")
  }

  func testUnsupportedPinnedBackendsAreRejected() throws {
    for preset in [AgentToolPolicyPreset.noTools, .webSearch] {
      let diagnostic = try XCTUnwrap(presetDiagnostics(payload(
        backend: .cursorCliAgent,
        preset: preset
      )).first)
      XCTAssertEqual(diagnostic.path, "node.agentToolPolicy.preset")
      XCTAssertEqual(diagnostic.severity, .error)
      XCTAssertTrue(diagnostic.message.contains("executionBackend 'cursor-cli-agent'"))
    }

    let cursorSDK = try XCTUnwrap(presetDiagnostics(payload(
      backend: .officialCursorSDK,
      preset: .webSearch
    )).first)
    XCTAssertEqual(cursorSDK.path, "node.agentToolPolicy.preset")
    XCTAssertEqual(cursorSDK.severity, .error)
    XCTAssertTrue(cursorSDK.message.contains("official/cursor-sdk"))
  }

  func testBackendPolicyRejectsFirstUnsupportedAllowedBackend() throws {
    let policy = WorkflowBackendPolicy(allowed: [.codexAgent, .cursorCliAgent])
    let diagnostic = try XCTUnwrap(presetDiagnostics(payload(
      backendPolicy: policy,
      preset: .webSearch
    )).first)

    XCTAssertEqual(diagnostic.path, "node.backendPolicy.allowed")
    XCTAssertEqual(diagnostic.severity, .error)
    XCTAssertEqual(
      diagnostic.message,
      "backend 'cursor-cli-agent' does not support agentToolPolicy preset 'web-search'"
    )
  }

  func testBackendPolicyWithSupportedAllowedBackendsIsAccepted() {
    let policy = WorkflowBackendPolicy(allowed: [.codexAgent, .claudeCodeAgent])
    XCTAssertTrue(presetDiagnostics(payload(backendPolicy: policy, preset: .webSearch)).isEmpty)
  }

  func testPresetRequiresExplicitBackendSelection() throws {
    let diagnostic = try XCTUnwrap(presetDiagnostics(payload(preset: .noTools)).first)

    XCTAssertEqual(diagnostic.path, "node.agentToolPolicy.preset")
    XCTAssertEqual(diagnostic.severity, .error)
    XCTAssertEqual(diagnostic.message, "requires an explicit executionBackend")
  }

  func testUnsupportedPresetIsReportedBeforeProviderEarlyReturn() throws {
    let diagnostic = try XCTUnwrap(presetDiagnostics(payload(
      backend: .cursorCliAgent,
      preset: .webSearch
    )).first)

    XCTAssertEqual(diagnostic.path, "node.agentToolPolicy.preset")
    XCTAssertEqual(diagnostic.severity, .error)
  }

  func testCodexReuseIsRejectedOnlyWhenPresetCapabilityDisallowsIt() {
    let diagnostics = presetDiagnostics(payload(
      backend: .codexAgent,
      preset: .noTools,
      sessionPolicy: WorkflowStepSessionPolicy(mode: .reuse)
    ))
    let reuseDiagnostic = diagnostics.first {
      $0.path == "node.agentToolPolicy.preset" && $0.message.contains("sessionPolicy mode 'reuse'")
    }

    XCTAssertEqual(reuseDiagnostic != nil, !AgentToolPolicyPresetArguments.codexSupportsSessionReuse)
  }

  func testPoliciesWithoutPresetHaveNoPresetDiagnostics() {
    let payload = AgentNodePayload(
      id: "worker",
      executionBackend: .cursorCliAgent,
      model: "model",
      agentToolPolicy: AgentToolPolicy(codexArguments: ["--example"])
    )

    XCTAssertTrue(presetDiagnostics(payload).isEmpty)
  }

  func testResolvedCLIPayloadHasNoPresetDiagnostics() {
    let payload = AgentNodePayload(
      id: "worker",
      executionBackend: .codexAgent,
      model: "model",
      agentToolPolicy: AgentToolPolicy(codexArguments: ["--ignore-user-config", "--disable", "shell_tool"])
    )

    XCTAssertTrue(presetDiagnostics(payload).isEmpty)
  }

  private func presetDiagnostics(_ payload: AgentNodePayload) -> [WorkflowValidationDiagnostic] {
    validateAgentNodePayload(payload).filter { $0.path.contains("agentToolPolicy") || $0.path.contains("backendPolicy.allowed") }
  }

  private func payload(
    backend: NodeExecutionBackend? = nil,
    backendPolicy: WorkflowBackendPolicy? = nil,
    preset: AgentToolPolicyPreset,
    mode: AgentToolPolicyMode? = nil,
    sessionPolicy: WorkflowStepSessionPolicy? = nil
  ) -> AgentNodePayload {
    AgentNodePayload(
      id: "worker",
      executionBackend: backend,
      backendPolicy: backendPolicy,
      model: "model",
      agentToolPolicy: AgentToolPolicy(mode: mode, preset: preset),
      sessionPolicy: sessionPolicy
    )
  }
}
