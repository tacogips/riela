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
    XCTAssertFalse(calls[0].0.arguments.contains("--dns-option"))
    XCTAssertFalse(calls[0].0.arguments.contains("no-aaaa"))
    let network = try XCTUnwrap(calls[0].0.arguments.firstIndex(of: "--network"))
    XCTAssertEqual(calls[0].0.arguments[network + 1], "none")
    XCTAssertFalse(calls[0].0.arguments.contains("-e"))
    XCTAssertFalse(calls[0].0.arguments.contains("--tmpfs"))
    XCTAssertNil(calls[0].0.environment["X_GW_TOKEN"])
    XCTAssertEqual(calls[1].0.arguments.prefix(2), ["exec", "-i"])
    XCTAssertFalse(calls[1].0.arguments.contains("-e"))
    XCTAssertNil(calls[1].0.environment["X_GW_TOKEN"])
    XCTAssertEqual(calls[1].2, "RIELAENV1\n1\n10\n16\nX_GW_TOKENprivate-sentinel")
    XCTAssertTrue(calls[1].0.arguments.contains("/usr/local/bin/riela-gateway-guard"))
    XCTAssertEqual(calls[2].0.arguments.prefix(2), ["delete", "--force"])
    XCTAssertNil(calls[2].0.environment["X_GW_TOKEN"])
    for call in calls {
      XCTAssertFalse(call.0.arguments.joined().contains("private-sentinel"))
      XCTAssertFalse(call.0.inheritEnvironment)
    }
    XCTAssertLessThan(try XCTUnwrap(calls[2].1).timeIntervalSinceNow, 11)
  }

  func testNetworkAllowedUsesHostResolverWithoutAAAAAndKeepsPrivateExec() async throws {
    for gateway in [ContainerGatewayAddon.gmailRead, .xRead] {
      let runner = PrivateExecRunner(failure: nil)
      _ = try await process(runner).run(image: "fixture", mounts: [], networkAllowed: true, gateway: gateway,
        document: "query {}", bindings: ["X_GW_TOKEN": "private-sentinel"], deadline: nil)
      let calls = await runner.calls
      let start = calls[0].0.arguments
      let option = try XCTUnwrap(start.firstIndex(of: "--dns-option"))
      XCTAssertEqual(start[option + 1], "no-aaaa")
      XCTAssertFalse(start.contains("--dns"))
      XCTAssertFalse(start.contains("--no-dns"))
      XCTAssertFalse(start.contains("--network"))
      XCTAssertFalse(start.contains("-e"))
      XCTAssertEqual(calls[0].2, "")
      XCTAssertTrue(calls[1].2.hasPrefix("RIELAENV1\n"))
      XCTAssertEqual(calls[2].0.arguments.prefix(2), ["delete", "--force"])
      for call in calls {
        XCTAssertFalse(call.0.arguments.joined().contains("private-sentinel"))
        XCTAssertNil(call.0.environment["X_GW_TOKEN"])
      }
    }
  }

  func testCleanupAfterInitFailureExecFailureAndCancellation() async throws {
    for failure in ["run", "exec", "cancel", "status"] {
      let runner = PrivateExecRunner(failure: failure)
      do {
        let process = process(runner)
        _ = try await Task {
          try await process.run(image: "fixture", mounts: [], networkAllowed: true, gateway: .gmailRead,
            document: "query {}", bindings: [:], deadline: nil)
        }.value
        XCTFail("expected failure")
      } catch {}
      let calls = await runner.calls
      XCTAssertEqual(calls.last?.0.arguments.prefix(2), ["delete", "--force"])
      let cleanupWasCancelled = await runner.cleanupWasCancelled
      XCTAssertFalse(cleanupWasCancelled)
    }
  }

  func testPrivateFrameBoundsAndUTF8Lengths() throws {
    XCTAssertEqual(try AppleContainerGatewayProcess.bindingFrame(["X_GW_TOKEN": "a\nb=é"]),
      "RIELAENV1\n1\n10\n6\nX_GW_TOKENa\nb=é")
    XCTAssertThrowsError(try AppleContainerGatewayProcess.bindingFrame(["X_GW_TOKEN": "x\0y"]))
    XCTAssertThrowsError(try AppleContainerGatewayProcess.bindingFrame(["X_GW_TOKEN": String(repeating: "x", count: 1_048_576)]))
  }

  private func process(_ runner: PrivateExecRunner) -> AppleContainerGatewayProcess {
    .init(executable: "/usr/local/bin/container", environment: ["HOME": "/runtime"],
      workingDirectory: URL(fileURLWithPath: "/tmp"), runner: runner)
  }
}

private actor PrivateExecRunner: LocalProcessRunning {
  let failure: String?
  var calls: [(LocalProcessConfiguration, Date?, String)] = []
  var cleanupWasCancelled = false
  init(failure: String?) { self.failure = failure }
  func run(configuration: LocalProcessConfiguration, stdin: String, deadline: Date?) async throws -> LocalProcessResult {
    calls.append((configuration, deadline, stdin))
    let command = configuration.arguments.first
    if command == "delete" { cleanupWasCancelled = Task.isCancelled }
    if command == failure { throw CancellationError() }
    if failure == "cancel", command == "exec" {
      withUnsafeCurrentTask { $0?.cancel() }
      throw CancellationError()
    }
    if failure == "status", command == "run" {
      return .init(stdout: "", stderr: "private runtime detail", terminationStatus: 1)
    }
    return .init(stdout: command == "exec" ? "exec-output" : "init-or-cleanup", stderr: "", terminationStatus: 0)
  }
}
