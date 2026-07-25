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
    XCTAssertTrue(ServeHTTPCommand.isLongRunningInvocation(["serve", "--web-root", "/tmp/web"]))

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

  func testBareNoteAPIServeRemainsLiveWithoutWebRoot() async throws {
    let explicitPort = try await availablePort()
    let readyOutput = ReadyOutputBox()
    let ready = expectation(description: "headless serve listener became ready")
    let scratchRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/riela-swift-serve-http", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratchRoot) }
    let task = Task {
      await ServeHTTPCommand().run(
        arguments: [
          "serve",
          "--host", "localhost",
          "--port", "\(explicitPort)",
          "--note-api",
          "--note-root", scratchRoot.appendingPathComponent("note", isDirectory: true).path
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
    XCTAssertFalse(readyResult.records.contains { $0.hasPrefix("webRoot=") }, output)
    XCTAssertTrue(try curl("\(endpoint)/healthz").contains("\"status\":\"ok\""))

    task.cancel()
    let result = await task.value
    XCTAssertEqual(result.exitCode, .success)
  }

  func testNoteAPIServeHostsSPAAndRedeemsBearerForGraphQL() async throws {
    let explicitPort = try await availablePort()
    let readyOutput = ReadyOutputBox()
    let ready = expectation(description: "serve listener became ready")
    let scratchRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/riela-swift-serve-http", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let noteRoot = scratchRoot.appendingPathComponent("note", isDirectory: true)
    let webRoot = scratchRoot.appendingPathComponent("web", isDirectory: true)
    try FileManager.default.createDirectory(at: webRoot, withIntermediateDirectories: true)
    try Data("<main>Riela Notes SPA</main>".utf8).write(to: webRoot.appendingPathComponent("index.html"))
    defer { try? FileManager.default.removeItem(at: scratchRoot) }
    let task = Task {
      await ServeHTTPCommand().run(
        arguments: [
          "serve",
          "--host", "localhost",
          "--port", "\(explicitPort)",
          "--note-api",
          "--note-root", noteRoot.path,
          "--web-root", webRoot.path
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
    XCTAssertTrue(readyResult.records.contains("webRoot=\(webRoot.path)"), output)

    let healthBody = try curl("\(endpoint)/healthz")
    XCTAssertTrue(healthBody.contains("\"status\":\"ok\""), healthBody)
    let registrationURL = try XCTUnwrap(
      readyResult.records.first(where: { $0.hasPrefix("registrationURL=") })
        .map { String($0.dropFirst("registrationURL=".count)) }
    )
    XCTAssertEqual(try curl(registrationURL), "<main>Riela Notes SPA</main>")
    let code = try XCTUnwrap(
      URLComponents(string: registrationURL)?.queryItems?.first(where: { $0.name == "code" })?.value
    )
    let registrationBody = try curl(
      "\(endpoint)/note/register",
      method: "POST",
      headers: ["Content-Type": "application/json"],
      body: #"{"code":"\#(code)","displayName":"Web integration test"}"#
    )
    let credential = try JSONDecoder().decode(
      RegistrationResponse.self,
      from: Data(registrationBody.utf8)
    ).credential
    XCTAssertTrue(credential.bearerToken.hasPrefix("rn_"))
    let graphQLBody = try curl(
      "\(endpoint)/graphql",
      method: "POST",
      headers: [
        "Authorization": "Bearer \(credential.bearerToken)",
        "Content-Type": "application/json"
      ],
      body: #"{"query":"query WebTags { tags { result { accepted } value { name } } }","operationName":"WebTags"}"#
    )
    XCTAssertTrue(graphQLBody.contains("\"accepted\":true"), graphQLBody)

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

private struct RegistrationResponse: Decodable {
  var credential: NoteAPIRegistrationCredential
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
