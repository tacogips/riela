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

    XCTAssertFalse(ServeHTTPCommand.isLongRunningInvocation(["serve", "status"]))
    XCTAssertFalse(ServeHTTPCommand.isLongRunningInvocation(["serve", "health"]))
    XCTAssertFalse(ServeHTTPCommand.isLongRunningInvocation(["serve", "overview"]))
    XCTAssertFalse(ServeHTTPCommand.isLongRunningInvocation(["serve", "graphql"]))
    XCTAssertFalse(ServeHTTPCommand.isLongRunningInvocation(["workflow", "list"]))
  }

  func testWebRootValidationRequiresReadableIndex() throws {
    var parsed = try ParsedParityOptions(["--web-root", "/definitely/missing/riela-web"])
    XCTAssertThrowsError(try resolvedServeWebRoot(parsed: parsed))

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    parsed = try ParsedParityOptions(["--web-root", root.path])
    XCTAssertThrowsError(try resolvedServeWebRoot(parsed: parsed))
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("index.html"),
      withIntermediateDirectories: false
    )
    XCTAssertThrowsError(try resolvedServeWebRoot(parsed: parsed))
    try FileManager.default.removeItem(at: root.appendingPathComponent("index.html"))
    try Data("outside".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("index.html"),
      withDestinationURL: outside
    )
    XCTAssertThrowsError(try resolvedServeWebRoot(parsed: parsed))
    try FileManager.default.removeItem(at: root.appendingPathComponent("index.html"))
    try Data("app".utf8).write(to: root.appendingPathComponent("index.html"))
    XCTAssertEqual(try resolvedServeWebRoot(parsed: parsed)?.path, root.resolvingSymlinksInPath().path)
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



  private func availablePort() async throws -> Int {
    let handler = AnyRielaHTTPRouteHandler { request in
      await DeterministicServerHTTPAdapter().response(for: request)
    }
    let server = RielaLocalHTTPServer(routeHandler: handler)
    let port = try await server.startForTesting()
    await server.stop()
    return port
  }

  private func curl(
    _ url: String,
    method: String = "GET",
    headers: [String: String] = [:],
    body: String? = nil
  ) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    var arguments = ["--fail", "--silent", "--show-error", "--max-time", "5"]
    if method != "GET" {
      arguments.append(contentsOf: ["--request", method])
    }
    for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
      arguments.append(contentsOf: ["--header", "\(name): \(value)"])
    }
    if let body {
      arguments.append(contentsOf: ["--data-binary", body])
    }
    arguments.append(url)
    process.arguments = arguments
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
