import Foundation
import RielaAdapters
import XCTest
@testable import RielaCLI

final class AppleContainerGatewayProcessTests: XCTestCase {
  func testExecCarriesOnlyExplicitSecretsAndCleanupHasIndependentDeadline() async throws {
    let runner = PrivateExecRunner(failure: nil)
    let result = try await process(runner).run(image: "fixture", mounts: [], networkAllowed: false, gateway: .xRead,
      document: "query {}", bindings: ["X_GW_TOKEN": "private-sentinel"], deadline: Date().addingTimeInterval(30))
    XCTAssertEqual(result.stdout, "exec-output")
    let calls = await runner.calls
    XCTAssertEqual(calls.count, 3)
    XCTAssertEqual(calls[0].0.arguments.prefix(2), ["run", "-d"])
    for flag in ["--rm", "--read-only", "--cap-drop", "--shm-size", "nproc=256:256", "core=0:0", "--no-dns"] {
      XCTAssertTrue(calls[0].0.arguments.contains(flag))
    }
    XCTAssertFalse(calls[0].0.arguments.contains("-e"))
    XCTAssertFalse(calls[0].0.arguments.contains("--tmpfs"))
    XCTAssertNil(calls[0].0.environment["X_GW_TOKEN"])
    XCTAssertEqual(calls[1].0.arguments.prefix(4), ["exec", "-i", "-e", "X_GW_TOKEN"])
    XCTAssertEqual(calls[1].0.environment["X_GW_TOKEN"], "private-sentinel")
    XCTAssertTrue(calls[1].0.arguments.contains("/usr/local/bin/riela-gateway-guard"))
    XCTAssertEqual(calls[2].0.arguments.prefix(2), ["delete", "--force"])
    XCTAssertNil(calls[2].0.environment["X_GW_TOKEN"])
    for call in calls {
      XCTAssertFalse(call.0.arguments.joined().contains("private-sentinel"))
      XCTAssertFalse(call.0.inheritEnvironment)
    }
    XCTAssertLessThan(try XCTUnwrap(calls[2].1).timeIntervalSinceNow, 11)
  }

  func testCleanupAfterInitFailureExecFailureAndCancellation() async throws {
    for failure in ["run", "exec", "cancel"] {
      let runner = PrivateExecRunner(failure: failure)
      do {
        _ = try await process(runner).run(image: "fixture", mounts: [], networkAllowed: true, gateway: .gmailRead,
          document: "query {}", bindings: [:], deadline: nil)
        XCTFail("expected failure")
      } catch {}
      let calls = await runner.calls
      XCTAssertEqual(calls.last?.0.arguments.prefix(2), ["delete", "--force"])
      let cleanupWasCancelled = await runner.cleanupWasCancelled
      XCTAssertFalse(cleanupWasCancelled)
    }
  }

  private func process(_ runner: PrivateExecRunner) -> AppleContainerGatewayProcess {
    .init(executable: "/usr/local/bin/container", environment: ["HOME": "/runtime"],
      workingDirectory: URL(fileURLWithPath: "/tmp"), runner: runner)
  }
}

private actor PrivateExecRunner: LocalProcessRunning {
  let failure: String?
  var calls: [(LocalProcessConfiguration, Date?)] = []
  var cleanupWasCancelled = false
  init(failure: String?) { self.failure = failure }
  func run(configuration: LocalProcessConfiguration, stdin: String, deadline: Date?) async throws -> LocalProcessResult {
    calls.append((configuration, deadline))
    let command = configuration.arguments.first
    if command == "delete" { cleanupWasCancelled = Task.isCancelled }
    if command == failure { throw CancellationError() }
    if failure == "cancel", command == "exec" { throw CancellationError() }
    return .init(stdout: command == "exec" ? "exec-output" : "init-or-cleanup", stderr: "", terminationStatus: 0)
  }
}
