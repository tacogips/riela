import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import RielaServer
import XCTest
@testable import RielaCLI

final class ServeHTTPCommandTests: XCTestCase {
  func testLongRunningInvocationMatchesOnlyBareServeForms() {
    XCTAssertTrue(ServeHTTPCommand.isLongRunningInvocation(["serve"]))
    XCTAssertTrue(ServeHTTPCommand.isLongRunningInvocation(["serve", "--host", "127.0.0.1", "--port", "8787"]))
    XCTAssertTrue(ServeHTTPCommand.isLongRunningInvocation(["serve", "--note-api", "--note-root", "/tmp/notes"]))

    XCTAssertFalse(ServeHTTPCommand.isLongRunningInvocation(["serve", "status"]))
    XCTAssertFalse(ServeHTTPCommand.isLongRunningInvocation(["serve", "health"]))
    XCTAssertFalse(ServeHTTPCommand.isLongRunningInvocation(["serve", "overview"]))
    XCTAssertFalse(ServeHTTPCommand.isLongRunningInvocation(["serve", "graphql"]))
    XCTAssertFalse(ServeHTTPCommand.isLongRunningInvocation(["workflow", "list"]))
  }

  func testServeOneShotCommandsStillReturnSuccessfully() async throws {
    let app = RielaCLIApplication()
    for subcommand in ["status", "health", "overview", "graphql"] {
      let result = await app.run(["serve", subcommand, "--output", "json"])
      XCTAssertEqual(result.exitCode, .success, "\(subcommand): \(result.stderr)")
      let decoded = try JSONDecoder().decode(ScopedParityCommandResult.self, from: Data(result.stdout.utf8))
      XCTAssertEqual(decoded.status, "ok", subcommand)
    }
  }

  func testBareNoteAPIServeCurlsExplicitLocalhostPortAndReportsMatchingRegistrationURL() async throws {
    let explicitPort = try await availablePort()
    let readyOutput = ReadyOutputBox()
    let ready = expectation(description: "serve listener became ready")
    let noteRoot = FileManager.default.currentDirectoryPath + "/tmp/riela-swift-serve-http/test-note-root"
    let task = Task {
      await ServeHTTPCommand().run(
        arguments: [
          "serve",
          "--host", "localhost",
          "--port", "\(explicitPort)",
          "--note-api",
          "--note-root", noteRoot
        ],
        onReady: { output in
          readyOutput.store(output)
          ready.fulfill()
        }
      )
    }
    defer { task.cancel() }

    await fulfillment(of: [ready], timeout: 10)
    let output = readyOutput.load()
    let endpoint = "http://localhost:\(explicitPort)"
    let readyResult = try JSONDecoder().decode(ScopedParityCommandResult.self, from: Data(output.utf8))
    XCTAssertTrue(readyResult.records.contains("endpoint=\(endpoint)"), output)
    XCTAssertTrue(
      readyResult.records.contains { $0.hasPrefix("registrationURL=\(endpoint)/note/register?code=") },
      output
    )

    let healthBody = try curl("\(endpoint)/healthz")
    XCTAssertTrue(healthBody.contains("\"status\":\"ok\""), healthBody)

    task.cancel()
    let result = await task.value
    XCTAssertEqual(result.exitCode, .success)
  }

  private func availablePort() async throws -> Int {
    let handler = AnyRielaHTTPRouteHandler { request in
      await DeterministicServerHTTPAdapter().response(for: request)
    }
    let server = RielaLocalHTTPServer(routeHandler: handler)
    let port = try await server.startForTesting()
    await server.stop()
    return port
  }

  private func curl(_ url: String) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    process.arguments = ["--fail", "--silent", "--show-error", "--max-time", "5", url]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let body = String(data: data, encoding: .utf8) ?? ""
    XCTAssertEqual(process.terminationStatus, 0, body)
    return body
  }
}

private final class ReadyOutputBox: @unchecked Sendable {
  private let lock = NSLock()
  private var output = ""

  func store(_ value: String) {
    lock.withLock {
      output = value
    }
  }

  func load() -> String {
    lock.withLock { output }
  }
}
