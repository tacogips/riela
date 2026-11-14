import Foundation
import RielaCore
import RielaKaibaSupport
import XCTest
@testable import RielaCLI
@testable import RielaServer

final class BuiltinContainerEntryPointTests: XCTestCase {
  func testNodeCLIContainerFlagsAndNamedKaibaInstanceUseProductionResolver() async throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["RIELA_TEST_LIVE_BUILTIN_IMAGE"] == "1", "opt-in production CLI guest test")
    let root = try makeRielaCLITestTemporaryDirectory("container-cli-entry")
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = root.appendingPathComponent("workspace")
    let home = root.appendingPathComponent("home")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let server = RielaLocalHTTPServer(routeHandler: EntryPointKaibaFixture())
    let port = try await server.startForTesting()
    try KaibaInstanceStore(homeURL: home).save(.init(instances: [.init(name: "CLI fixture",
      endpoint: "http://127.0.0.1:\(port)/graphql", authentication: .unauthenticated, isDefault: true)]))
    let image = ProcessInfo.processInfo.environment["RIELA_TEST_BUILTIN_IMAGE"] ?? WorkflowAddonContainerExecution.defaultImage
    do {
      try await CLIRuntimeEnvironment.$overrides.withValue(["HOME": home.path]) {
        for (name, variables) in [("riela/time-signal", #"{"scheduledAt":"2026-10-15T00:00:00Z","timezone":"UTC"}"#),
          ("kaiba/note-graphql-document", #"{"query":"query { fixture }"}"#)] {
          let result = await RielaCLIApplication().run(["node", "run", name, "--container", "--container-image", image,
            "--container-options", #"{"runtime":"apple-container","networkPolicy":"denied"}"#,
            "--variables", variables, "--working-dir", workspace.path, "--output", "json"])
          XCTAssertEqual(result.exitCode, .success, result.stderr)
          if result.exitCode == .success {
            let decoded = try JSONDecoder().decode(NodeRunCommandResult.self, from: Data(result.stdout.utf8))
            XCTAssertEqual(decoded.target, name)
            XCTAssertEqual(decoded.payload["status"], .string("ok"))
          }
        }
      }
      let control = BuiltinAddonContainerTransportStore.defaultRoot(for: workspace, home: home)
      let state = BuiltinAddonContainerTransportStore.workerStateRoot(for: control)
      XCTAssertTrue(FileManager.default.fileExists(atPath: state.appendingPathComponent("home").path), "native execution cannot create guest state")
      await server.stop()
    } catch {
      await server.stop()
      throw error
    }
  }
}

private struct EntryPointKaibaFixture: RielaHTTPRouteHandling {
  func response(for request: RielaHTTPRequest) async -> RielaHTTPResponse {
    if case let .object(body)? = try? JSONDecoder().decode(JSONValue.self, from: request.body),
       case let .string(query)? = body["query"], query.contains("KaibaClientReadiness") {
      return .json(.object(["data": .object(["kaibaReadiness": .object([
        "result": .object(["accepted": .bool(true), "status": .string("ok")])])])]))
    }
    return .json(.object(["data": .object(["fixture": .string("CLI guest")])]))
  }
}
