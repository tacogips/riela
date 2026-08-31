import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import RielaServer
import XCTest
@testable import RielaCLI

final class ServeHTTPCommandTests: XCTestCase {
  private var temporaryDirectories: [URL] = []

  override func tearDownWithError() throws {
    for directory in temporaryDirectories {
      try? FileManager.default.removeItem(at: directory)
    }
    temporaryDirectories = []
  }

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
    XCTAssertEqual(try resolvedServeWebRoot(parsed: parsed).root?.path, root.resolvingSymlinksInPath().path)
    XCTAssertEqual(try resolvedServeWebRoot(parsed: parsed).source, .explicit)
  }

  func testExplicitWebRootWinsOverDiscovery() throws {
    let explicit = try makeWebRoot()
    let located = try makeWebRoot()
    let parsed = try ParsedParityOptions(["--web-root", explicit.path])
    let locatorBox = LocatorCallBox()

    let resolution = try resolvedServeWebRoot(parsed: parsed, locateDefault: {
      locatorBox.markCalled()
      return located
    })

    XCTAssertEqual(resolution.root?.path, explicit.resolvingSymlinksInPath().path)
    XCTAssertEqual(resolution.source, .explicit)
    XCTAssertNil(resolution.diagnostic)
    XCTAssertFalse(locatorBox.wasCalled(), "an explicit --web-root must not trigger discovery")
  }

  func testDefaultWebRootUsesLocatedAssets() throws {
    let located = try makeWebRoot()
    let parsed = try ParsedParityOptions([])

    let resolution = try resolvedServeWebRoot(parsed: parsed, locateDefault: { located })

    XCTAssertEqual(resolution.root?.path, located.resolvingSymlinksInPath().path)
    XCTAssertEqual(resolution.source, .located)
    XCTAssertNil(resolution.diagnostic)
  }

  func testDefaultWebRootIsUnavailableWhenNothingLocated() throws {
    let parsed = try ParsedParityOptions([])

    let resolution = try resolvedServeWebRoot(parsed: parsed, locateDefault: { nil })

    XCTAssertNil(resolution.root)
    XCTAssertNil(resolution.source)
    XCTAssertEqual(resolution.diagnostic?.hasPrefix("missing;"), true, resolution.diagnostic ?? "<nil>")
  }

  func testLocatedWebRootFailingValidationDoesNotThrow() throws {
    let located = try makeTempDirectory()
    // index.html as a directory is exactly what the explicit path rejects.
    try FileManager.default.createDirectory(
      at: located.appendingPathComponent("index.html"),
      withIntermediateDirectories: false
    )
    let parsed = try ParsedParityOptions([])

    var resolution: ServeWebRootResolution?
    XCTAssertNoThrow(resolution = try resolvedServeWebRoot(parsed: parsed, locateDefault: { located }))

    let unwrapped = try XCTUnwrap(resolution)
    XCTAssertNil(unwrapped.root)
    XCTAssertNil(unwrapped.source)
    let diagnostic = unwrapped.diagnostic ?? ""
    XCTAssertTrue(diagnostic.hasPrefix("rejected "), diagnostic)
    XCTAssertTrue(diagnostic.contains(located.path), diagnostic)
  }

  func testReadyRecordsDescribeWebRootState() {
    let root = URL(fileURLWithPath: "/tmp/riela-web", isDirectory: true)

    XCTAssertEqual(
      ServeHTTPCommand.readyRecords(
        endpoint: "http://127.0.0.1:8787",
        webRoot: ServeWebRootResolution(root: root, source: .located)
      ),
      ["endpoint=http://127.0.0.1:8787", "webRoot=/tmp/riela-web", "webRootSource=auto"]
    )
    XCTAssertEqual(
      ServeHTTPCommand.readyRecords(
        endpoint: "http://127.0.0.1:8787",
        webRoot: ServeWebRootResolution(root: root, source: .explicit)
      ),
      ["endpoint=http://127.0.0.1:8787", "webRoot=/tmp/riela-web", "webRootSource=--web-root"]
    )
    let apiOnly = ServeHTTPCommand.readyRecords(
      endpoint: "http://127.0.0.1:8787",
      webRoot: .unavailable
    )
    XCTAssertEqual(apiOnly.count, 3)
    XCTAssertEqual(apiOnly[0], "endpoint=http://127.0.0.1:8787")
    XCTAssertEqual(apiOnly[1], "webRoot=none")
    XCTAssertTrue(apiOnly[2].hasPrefix("webAssets=missing;"), apiOnly[2])
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

#if canImport(Network)
  func testBareServeServesLocatedSPAAndAPI() async throws {
    let root = try makeWebRoot(indexHTML: "<main>Dashboard</main>")
    try Data("body{}".utf8).write(to: root.appendingPathComponent("assets/app.css"))
    let port = try await availablePort()
    let command = ServeHTTPCommand(locateWebAssets: { root })
    let box = ReadyOutputBox()
    let task = Task {
      await command.run(arguments: ["serve", "--host", "127.0.0.1", "--port", "\(port)"]) { box.store($0) }
    }
    defer {
      task.cancel()
    }

    let ready = try await readyRecords(box)
    XCTAssertTrue(ready.contains("webRootSource=auto"), "\(ready)")
    XCTAssertTrue(ready.contains("webRoot=\(root.resolvingSymlinksInPath().path)"), "\(ready)")

    let index = try curl("http://127.0.0.1:\(port)/")
    XCTAssertTrue(index.contains("<main>Dashboard</main>"), index)
    XCTAssertEqual(try curl("http://127.0.0.1:\(port)/assets/app.css"), "body{}")
    let health = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(try curl("http://127.0.0.1:\(port)/healthz").utf8)) as? [String: Any]
    )
    XCTAssertEqual(health["service"] as? String, "riela")
    XCTAssertEqual(health["status"] as? String, "ok")

    task.cancel()
    let result = await task.value
    XCTAssertEqual(result.exitCode, .success)
  }

  func testBareServeWithoutAssetsStaysAPIOnly() async throws {
    let port = try await availablePort()
    let command = ServeHTTPCommand(locateWebAssets: { nil })
    let box = ReadyOutputBox()
    let task = Task {
      await command.run(arguments: ["serve", "--host", "127.0.0.1", "--port", "\(port)"]) { box.store($0) }
    }
    defer {
      task.cancel()
    }

    let ready = try await readyRecords(box)
    XCTAssertTrue(ready.contains("webRoot=none"), "\(ready)")
    XCTAssertTrue(ready.contains(where: { $0.hasPrefix("webAssets=missing;") }), "\(ready)")

    // API-only mode keeps the pre-change behaviour: GET / is the overview JSON.
    let overview = try curl("http://127.0.0.1:\(port)/")
    let overviewObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(overview.utf8)) as? [String: Any]
    )
    XCTAssertEqual(overviewObject["route"] as? String, "/", overview)
    XCTAssertEqual(overviewObject["service"] as? String, "riela", overview)
    let health = try curl("http://127.0.0.1:\(port)/healthz")
    XCTAssertTrue(health.contains("\"status\":\"ok\""), health)

    task.cancel()
    let result = await task.value
    XCTAssertEqual(result.exitCode, .success)
  }

  /// Waits for the ready callback and returns its `key=value` records. Serve renders the
  /// ready payload with the requested `--output` format, whose default is JSON, so the raw
  /// string escapes slashes; the records themselves are the stable contract.
  private func readyRecords(
    _ box: ReadyOutputBox,
    timeout: TimeInterval = 5
  ) async throws -> [String] {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      let output = box.load()
      if !output.isEmpty {
        if let decoded = try? JSONDecoder().decode(ScopedParityCommandResult.self, from: Data(output.utf8)) {
          return decoded.records
        }
        return output.split(separator: "\n").map(String.init)
      }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTFail("serve did not report ready within \(timeout)s")
    return []
  }
#endif

  private func makeTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-serve-web-root-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    temporaryDirectories.append(directory)
    return directory
  }

  private func makeWebRoot(indexHTML: String = "<main>app</main>") throws -> URL {
    let root = try makeTempDirectory()
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("assets", isDirectory: true),
      withIntermediateDirectories: true
    )
    try Data(indexHTML.utf8).write(to: root.appendingPathComponent("index.html"))
    return root
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

private final class LocatorCallBox: @unchecked Sendable {
  private let lock = NSLock()
  private var called = false

  func markCalled() {
    lock.withLock { called = true }
  }

  func wasCalled() -> Bool {
    lock.withLock { called }
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
