import Foundation
import RielaAppSupport
import RielaCore
import RielaServer
import XCTest
@testable import RielaCLI

/// Web API surface gate (CSP-4). The declared route table (delta D7) is the
/// enumeration; the catalog is the declaration; the gate is their bijection,
/// backed by owner-file checks and live dispatch spot tests.
final class SurfaceParityWebAPITests: XCTestCase {
  func testDeclaredRoutesMatchTheCatalog() {
    let violations = SurfaceCatalog.bijectionViolations(
      surface: .webAPI,
      actual: Set(RielaWebAPIRouteTable.all.map(\.route)),
      declared: SurfaceCatalog.declaredWebAPIRoutes
    )
    XCTAssertTrue(
      violations.isEmpty,
      "web API parity violations:\n" + violations.map(\.description).joined(separator: "\n")
    )
  }

  /// A declared route must be served by the file that claims it.
  func testEveryDeclaredRouteAppearsInItsOwnerFile() throws {
    for route in RielaWebAPIRouteTable.all {
      let url = Self.repositoryRoot().appendingPathComponent(route.owner)
      let contents = try String(contentsOf: url, encoding: .utf8)
      XCTAssertTrue(
        contents.contains(route.pathLiteralPrefix),
        "\(route.owner) does not mention \(route.pathLiteralPrefix) for \(route.route)"
      )
    }
    let desktop = try String(
      contentsOf: Self.repositoryRoot().appendingPathComponent(RielaWebAPIRouteTable.desktopInstanceWriteOwner),
      encoding: .utf8
    )
    XCTAssertTrue(desktop.contains("/api/v1/instances"), "the desktop host must serve the instance writes")
  }

  /// No owner may serve an `/api/v1` path the table omits. This is the
  /// direction a hand-kept table would otherwise miss.
  func testNoSourceServesAnUndeclaredAPIPath() throws {
    // The declaration files themselves list every path; skip them and scan the
    // files that actually dispatch.
    let declarationFiles: Set<String> = [
      "Sources/RielaAppSupport/RielaWebAPIRouteTable.swift",
      "Sources/RielaCore/SurfaceCatalog+RowsConsole.swift"
    ]
    let declared = Set(RielaWebAPIRouteTable.all.map(\.pathLiteralPrefix))
      .union(RielaWebAPIRouteTable.all.map(\.path))
      .union(RielaWebAPIRouteTable.prefixGuards)
    var undeclared: [String] = []
    for (path, contents) in try Self.swiftSources() where !declarationFiles.contains(path) {
      for literal in Self.apiPathLiterals(in: contents) where !declared.contains(literal) {
        undeclared.append("\(path): \(literal)")
      }
    }
    XCTAssertTrue(
      undeclared.isEmpty,
      "these /api/v1 paths are served but not declared in RielaWebAPIRouteTable:\n"
        + undeclared.sorted().joined(separator: "\n")
    )
  }

  /// Retired routes must be gone, not merely undocumented (design 2.4).
  func testRetiredConsoleReadRoutesAreDeleted() throws {
    let projection = try String(
      contentsOf: Self.repositoryRoot()
        .appendingPathComponent("Sources/RielaAppSupport/RielaWebAPIProjection.swift"),
      encoding: .utf8
    )
    for retired in ["\"/api/v1/instances\")", "/api/v1/ops/overview"] {
      XCTAssertFalse(projection.contains(retired), "retired route still served: \(retired)")
    }
  }

  /// Spot dispatch: the bootstrap route answers as declared.
  @MainActor
  func testBootstrapRouteDispatchesAsDeclared() throws {
    let response = Self.projection().response(
      for: RielaHTTPRequest(method: "GET", path: "/api/v1/bootstrap", percentEncodedPath: "/api/v1/bootstrap"),
      csrfToken: "token"
    )
    XCTAssertEqual(response.status, 200)
    let body = try XCTUnwrap(String(data: response.body, encoding: .utf8))
    XCTAssertTrue(body.contains("\"apiVersion\""))
    XCTAssertTrue(body.contains("\"csrfToken\""))
  }

  /// Spot dispatch: a retired route is a 404, and an auth route is answered by
  /// the Passkey service rather than the projection.
  @MainActor
  func testRetiredInstanceListIsNotFoundAndAuthStatusIsServedByPasskeys() async throws {
    let retired = Self.projection().response(
      for: RielaHTTPRequest(method: "GET", path: "/api/v1/instances", percentEncodedPath: "/api/v1/instances"),
      csrfToken: "token"
    )
    XCTAssertEqual(retired.status, 404)

    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("surface-parity-passkeys-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = try RielaPasskeyConfiguration(origin: "https://riela.example")
    let service = RielaPasskeyService(configuration: configuration, root: root)
    let response = await service.response(for: RielaHTTPRequest(
      method: "GET",
      path: "/api/v1/auth/status",
      percentEncodedPath: "/api/v1/auth/status",
      headers: ["host": configuration.authority]
    ))
    XCTAssertEqual(response.status, 200)
    XCTAssertTrue(String(data: response.body, encoding: .utf8)?.contains("passkey") == true)
  }

  // MARK: - Helpers

  @MainActor
  private static func projection() -> RielaWebAPIProjection {
    RielaWebAPIProjection(
      profile: .default,
      state: RielaAppDaemonWorkflowState(),
      instances: [],
      sources: [],
      revision: 1,
      sessionStoreRoot: NSTemporaryDirectory(),
      serverSettings: [:],
      hostKind: .server
    )
  }

  static func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  static func apiPathLiterals(in contents: String) -> [String] {
    var literals: [String] = []
    var remainder = Substring(contents)
    while let start = remainder.range(of: "\"/api/v1") {
      let afterQuote = remainder[start.lowerBound...].dropFirst()
      let literal = afterQuote.prefix { $0 != "\"" }
      literals.append(String(literal))
      remainder = remainder[start.upperBound...]
    }
    return literals
  }

  private static func swiftSources() throws -> [(String, String)] {
    let root = repositoryRoot()
    let sources = root.appendingPathComponent("Sources", isDirectory: true)
    guard let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
      return []
    }
    var result: [(String, String)] = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
      result.append((
        url.path.replacingOccurrences(of: root.path + "/", with: ""),
        try String(contentsOf: url, encoding: .utf8)
      ))
    }
    return result
  }
}
