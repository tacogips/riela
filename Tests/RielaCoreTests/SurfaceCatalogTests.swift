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

  /// Catalogs the shipped Work Runtime task and intent CLI and GraphQL surfaces.
  func testWorkRuntimeReadAndP1TaskCommandsAreCataloged() throws {
    let rows = SurfaceCatalog.operations(inFamily: "task") + SurfaceCatalog.operations(inFamily: "intent")
    XCTAssertEqual(
      Set(rows.map(\.id)),
      [
        "task.submit", "task.list", "task.show", "task.run", "task.decide", "task.serve",
        "task.handover", "task.takeover", "task.answer", "task.handovers", "task.reconcile",
        "task.handover-query", "task.awaiting-handover", "task.heartbeat", "task.report",
        "intent.create", "intent.list", "intent.show"
      ]
    )

    let implementedCommands = [
      "task.show": "task show", "task.list": "task list",
      "task.run": "task run", "task.decide": "task decide",
      "task.serve": "task serve", "task.handover": "task handover",
      "task.takeover": "task takeover", "task.answer": "task answer",
      "task.handovers": "task handovers", "task.reconcile": "task reconcile"
    ]
    for (id, command) in implementedCommands {
      let row = try XCTUnwrap(SurfaceCatalog.operation(id: id))
      XCTAssertEqual(row.availability(on: .cli), .implemented, "\(id) ships in P0 or P1")
      XCTAssertEqual(row.cli?.command, command)
      XCTAssertFalse(row.cli?.options.isEmpty ?? true, "\(id) must document its flags")
    }

    let serve = try XCTUnwrap(SurfaceCatalog.operation(id: "task.serve"))
    XCTAssertTrue(serve.cli?.options.contains("--takeover") == true)
    XCTAssertTrue(serve.cli?.options.contains("--traits") == true)

    for id in ["task.submit", "intent.create", "intent.list", "intent.show"] {
      let row = try XCTUnwrap(SurfaceCatalog.operation(id: id))
      guard case let .blocked(evidence)? = row.availability(on: .cli) else {
        return XCTFail("\(id) must declare the CLI surface blocked")
      }
      XCTAssertTrue(evidence.contains("work-runtime P1"), "\(id) must cite P1, got '\(evidence)'")
      XCTAssertNil(row.cli, "\(id) must not claim a CLI binding")
    }

    let graphQLFields = [
      "task.handover-query": (SurfaceGraphQLRoot.query, "taskHandover"),
      "task.awaiting-handover": (.query, "tasksAwaitingHandover"),
      "task.heartbeat": (.mutation, "heartbeatAttempt"),
      "task.report": (.mutation, "reportAttempt"),
      "task.handover": (.mutation, "requestTaskHandover"),
      "task.answer": (.mutation, "answerTask"),
      "task.takeover": (.mutation, "takeoverTask")
    ]
    for (id, field) in graphQLFields {
      let row = try XCTUnwrap(SurfaceCatalog.operation(id: id))
      XCTAssertEqual(row.graphql, SurfaceGraphQLBinding(root: field.0, field: field.1))
      XCTAssertEqual(row.availability(on: .graphql), .implemented)
      XCTAssertNil(row.library)
    }

    for id in ["task.handover-query", "task.awaiting-handover", "task.heartbeat", "task.report"] {
      let row = try XCTUnwrap(SurfaceCatalog.operation(id: id))
      XCTAssertNil(row.cli)
      XCTAssertNotEqual(row.availability(on: .cli), .implemented)
    }

    for row in rows {
      guard case let .blocked(evidence)? = row.availability(on: .library) else {
        return XCTFail("\(row.id) must keep its library surface blocked")
      }
      XCTAssertTrue(evidence.contains("work-runtime P5"), "\(row.id) must cite P5 for the library")
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
