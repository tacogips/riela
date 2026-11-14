import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

/// Library surface gate (CSP-4/CSP-7). The facade file is read through
/// `#filePath` (delta D4) and its `public func` names are compared with the
/// catalog's `library` bindings.
final class SurfaceParityLibraryTests: XCTestCase {
  static let facadePath = "Sources/RielaCLI/RielaLibrary.swift"

  func testFacadeEntryPointsMatchTheCatalog() throws {
    let violations = SurfaceCatalog.bijectionViolations(
      surface: .library,
      actual: Set(try Self.facadeFunctionNames().map { "RielaLibrary.\($0)" }),
      declared: SurfaceCatalog.declaredLibraryFunctions
    )
    XCTAssertTrue(
      violations.isEmpty,
      "library surface parity violations:\n" + violations.map(\.description).joined(separator: "\n")
    )
  }

  func testFacadeIsTheSixDesignedEntryPointsInDesignOrder() throws {
    XCTAssertEqual(
      try Self.facadeFunctionNames(),
      ["executeWorkflow", "resumeSession", "rerunSession", "inspectWorkflow", "sessionView", "executeGraphQLDocument"]
    )
  }

  /// The deleted TypeScript runtime's names must not come back.
  func testRetiredTypeScriptEntryPointsAreAbsent() throws {
    let facade = try String(
      contentsOf: Self.repositoryRoot().appendingPathComponent(Self.facadePath),
      encoding: .utf8
    )
    for retired in [
      "createWorkflowExecutionClient", "resumeWorkflow", "rerunWorkflow",
      "getRuntimeSessionView", "callWorkflowStep", "executeGraphqlRequest", "createGraphqlSchema"
    ] {
      XCTAssertFalse(facade.contains("func \(retired)"), "retired entry point reappeared: \(retired)")
    }
  }

  /// Compiling proof that the documented snippet's calls exist with the
  /// documented argument labels.
  func testDocumentedFacadeCallsCompileAndReturnTheDocumentedTypes() async {
    let riela = RielaLibrary(workingDirectory: NSTemporaryDirectory(), scope: .direct)
    let run: CLICommandResult = await riela.executeWorkflow("missing-workflow", variables: "{}")
    XCTAssertNotEqual(run.exitCode, .success, "a missing workflow must not succeed")
    let inspected: CLICommandResult = await riela.inspectWorkflow("missing-workflow", structure: true)
    XCTAssertNotEqual(inspected.exitCode, .success)
    let view: CLICommandResult = await riela.sessionView("missing-session")
    XCTAssertNotEqual(view.exitCode, .success)
    let resumed: CLICommandResult = await riela.resumeSession("missing-session")
    XCTAssertNotEqual(resumed.exitCode, .success)
    let rerun: CLICommandResult = await riela.rerunSession("missing-session", fromStepId: "step")
    XCTAssertNotEqual(rerun.exitCode, .success)
    let response = await riela.executeGraphQLDocument("query Broken { unknownField }")
    XCTAssertNotNil(response.body["errors"] ?? response.body["data"])
  }

  // MARK: - Helpers

  static func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  /// Public function names declared on the facade, in declaration order.
  static func facadeFunctionNames() throws -> [String] {
    let contents = try String(
      contentsOf: repositoryRoot().appendingPathComponent(facadePath),
      encoding: .utf8
    )
    return contents.split(separator: "\n").compactMap { line -> String? in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("public func ") else { return nil }
      let name = trimmed.dropFirst("public func ".count).prefix { $0.isLetter || $0.isNumber || $0 == "_" }
      return name.isEmpty ? nil : String(name)
    }
  }
}
