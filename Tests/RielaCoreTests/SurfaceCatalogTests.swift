import XCTest
@testable import RielaCore

/// Structural gate for the operation catalog itself (CSP-1). The per-surface
/// gates live in the owning module tests; these assertions hold regardless of
/// any surface.
final class SurfaceCatalogTests: XCTestCase {
  func testCatalogInvariantsHold() {
    let violations = SurfaceCatalog.invariantViolations()
    XCTAssertTrue(
      violations.isEmpty,
      "catalog invariants violated:\n" + violations.map(\.description).joined(separator: "\n")
    )
  }

  func testCatalogIsNotEmptyAndCoversTheKnownFamilies() {
    XCTAssertGreaterThan(SurfaceCatalog.all.count, 100)
    let families = Set(SurfaceCatalog.all.map(\.family))
    for expected in [
      "workflow", "session", "loop", "package", "node", "memory", "instance", "specialist",
      "events", "routine", "serve", "graphql", "auth", "worker", "console", "configuration",
      "web-auth", "web-editor", "web-settings", "task", "intent"
    ] {
      XCTAssertTrue(families.contains(expected), "catalog has no rows for family '\(expected)'")
    }
  }

  func testIdsCLICommandsGraphQLFieldsAndRoutesAreUnique() {
    assertUnique(SurfaceCatalog.all.map(\.id), label: "operation id")
    assertUnique(SurfaceCatalog.all.compactMap { $0.cli?.command }, label: "cli command")
    assertUnique(SurfaceCatalog.all.compactMap { $0.graphql?.qualifiedField }, label: "graphql field")
    assertUnique(SurfaceCatalog.all.compactMap { $0.webAPI?.route }, label: "web api route")
    assertUnique(SurfaceCatalog.all.compactMap { $0.library?.qualifiedName }, label: "library function")
  }

  /// Design 2.6 fixes the embedding facade at exactly six entry points.
  func testLibraryFacadeIsExactlyTheSixDesignedEntryPoints() {
    XCTAssertEqual(
      SurfaceCatalog.declaredLibraryFunctions,
      Set([
        "RielaLibrary.executeWorkflow",
        "RielaLibrary.resumeSession",
        "RielaLibrary.rerunSession",
        "RielaLibrary.inspectWorkflow",
        "RielaLibrary.sessionView",
        "RielaLibrary.executeGraphQLDocument"
      ])
    )
  }

  /// Delta D6: the Work Runtime commands are cataloged before they exist, and
  /// they must stay `blocked` on the P0 plan until that plan ships.
  func testWorkRuntimeOperationsAreBlockedOnTheP0Plan() {
    let rows = SurfaceCatalog.operations(inFamily: "task") + SurfaceCatalog.operations(inFamily: "intent")
    XCTAssertFalse(rows.isEmpty)
    for row in rows {
      guard case let .blocked(evidence)? = row.availability(on: .cli) else {
        return XCTFail("\(row.id) must declare the CLI surface blocked")
      }
      XCTAssertTrue(evidence.contains("work-runtime-p0-model-and-store.md"), "\(row.id) must cite the P0 plan")
      XCTAssertNil(row.cli, "\(row.id) must not claim a CLI binding")
      XCTAssertNil(row.graphql, "\(row.id) must not claim a GraphQL binding")
    }
  }

  /// Design 2.6: supervision types never enter the schema.
  func testSupervisionIsExcludedEverywhere() {
    guard let row = SurfaceCatalog.operation(id: "session.supervision") else {
      return XCTFail("session.supervision row is missing")
    }
    for surface in SurfaceCatalog.requiredSurfaces {
      guard case let .excluded(reason, _)? = row.availability(on: surface) else {
        return XCTFail("session.supervision must be excluded on \(surface.rawValue)")
      }
      XCTAssertTrue(reason.contains("Work Runtime"), "exclusion reason must cite the Work Runtime design")
    }
  }

  func testBijectionViolationsReportBothDirections() {
    let violations = SurfaceCatalog.bijectionViolations(
      surface: .cli,
      actual: ["a", "b"],
      declared: ["b", "c"]
    )
    XCTAssertEqual(violations.count, 2)
    XCTAssertTrue(violations.contains { $0.subject == "a" && $0.reason.contains("no catalog row") })
    XCTAssertTrue(violations.contains { $0.subject == "c" && $0.reason.contains("absent from the surface") })
  }

  private func assertUnique(_ values: [String], label: String, file: StaticString = #filePath, line: UInt = #line) {
    var counts: [String: Int] = [:]
    for value in values { counts[value, default: 0] += 1 }
    let duplicates = counts.filter { $0.value > 1 }.keys.sorted()
    XCTAssertTrue(duplicates.isEmpty, "duplicate \(label): \(duplicates.joined(separator: ", "))", file: file, line: line)
  }
}
