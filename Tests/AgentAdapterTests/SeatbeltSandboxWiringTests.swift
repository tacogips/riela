import Foundation
import XCTest
@testable import ClaudeCodeAgent
@testable import CodexAgent
@testable import CursorCLIAgent
@testable import RielaAdapters
@testable import RielaCore

extension AgentAdapterTests {
  func testClaudeBuilderAttachesSeatbeltPolicyWhenEnvSwitchOn() async throws {
    let runner = RecordingRunner(output: "done")
    let adapter = ClaudeCodeAgentAdapter(
      runner: runner,
      environment: ["RIELA_SANDBOX_SEATBELT": "auto"],
      authPreflight: false
    )

    _ = try await adapter.execute(
      input(backend: .claudeCodeAgent, workingDirectory: "/tmp/work", agentSandbox: .readOnly),
      context: AdapterExecutionContext()
    )

    let runs = await runner.runs()
    let policy = try XCTUnwrap(runs.last?.configuration.sandboxPolicy)
    XCTAssertEqual(policy.enforcement, .auto)
    XCTAssertEqual(policy.writeScope, .paths(["~/.claude", "~/.claude.json", "~/Library/Caches/claude-cli-nodejs"]))
  }

  func testClaudeBuilderRequiredEnforcementReachesPolicy() async throws {
    let runner = RecordingRunner(output: "done")
    let adapter = ClaudeCodeAgentAdapter(
      runner: runner,
      environment: ["RIELA_SANDBOX_SEATBELT": "required"],
      authPreflight: false
    )

    _ = try await adapter.execute(
      input(backend: .claudeCodeAgent, workingDirectory: "/tmp/work", agentSandbox: .workspaceWrite),
      context: AdapterExecutionContext()
    )

    let runs = await runner.runs()
    let policy = try XCTUnwrap(runs.last?.configuration.sandboxPolicy)
    XCTAssertEqual(policy.enforcement, .required)
    guard case let .paths(roots) = policy.writeScope else {
      return XCTFail("expected workspace paths scope")
    }
    XCTAssertTrue(roots.contains("/tmp/work"))
    XCTAssertTrue(roots.contains("/tmp/work/.riela/artifacts"))
    XCTAssertTrue(roots.contains("~/.claude"))
  }

  func testClaudeBuilderAttachesNoPolicyByDefault() async throws {
    // The builder falls back to the process environment, so shed any value
    // exported in the developer's shell to keep this test hermetic.
    unsetenv(SeatbeltSandboxSettings.environmentKey)
    let runner = RecordingRunner(output: "done")
    let adapter = ClaudeCodeAgentAdapter(runner: runner, authPreflight: false)

    _ = try await adapter.execute(
      input(backend: .claudeCodeAgent, workingDirectory: "/tmp/work", agentSandbox: .readOnly),
      context: AdapterExecutionContext()
    )

    let runs = await runner.runs()
    XCTAssertNil(runs.last?.configuration.sandboxPolicy)
  }

  func testClaudeBuilderAttachesNoPolicyForDangerFullAccess() async throws {
    let runner = RecordingRunner(output: "done")
    let adapter = ClaudeCodeAgentAdapter(
      runner: runner,
      environment: ["RIELA_SANDBOX_SEATBELT": "auto"],
      authPreflight: false
    )

    _ = try await adapter.execute(
      input(backend: .claudeCodeAgent, workingDirectory: "/tmp/work", agentSandbox: .dangerFullAccess),
      context: AdapterExecutionContext()
    )

    let runs = await runner.runs()
    XCTAssertNil(runs.last?.configuration.sandboxPolicy)
  }

  func testCursorBuilderAttachesSeatbeltPolicyWhenEnvSwitchOn() async throws {
    let runner = RecordingRunner(output: "done")
    let adapter = CursorCLIAgentAdapter(
      runner: runner,
      environment: ["RIELA_SANDBOX_SEATBELT": "auto"],
      authPreflight: false
    )

    _ = try await adapter.execute(
      input(backend: .cursorCliAgent, workingDirectory: "/tmp/work", agentSandbox: .workspaceWrite),
      context: AdapterExecutionContext()
    )

    let runs = await runner.runs()
    let policy = try XCTUnwrap(runs.last?.configuration.sandboxPolicy)
    guard case let .paths(roots) = policy.writeScope else {
      return XCTFail("expected workspace paths scope")
    }
    XCTAssertTrue(roots.contains("/tmp/work"))
    XCTAssertTrue(roots.contains("~/.cursor"))
    XCTAssertTrue(roots.contains("~/Library/Application Support/Cursor"))
  }

  func testCodexBuilderNeverAttachesSeatbeltPolicy() async throws {
    let runner = RecordingRunner(output: "done")
    let adapter = CodexAgentAdapter(runner: runner, environment: ["RIELA_SANDBOX_SEATBELT": "required"], authPreflight: false)

    _ = try await adapter.execute(
      input(backend: .codexAgent, workingDirectory: "/tmp/work", agentSandbox: .readOnly),
      context: AdapterExecutionContext()
    )

    let runs = await runner.runs()
    XCTAssertNil(runs.last?.configuration.sandboxPolicy)
  }
}
