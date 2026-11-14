import XCTest
@testable import RielaCLI
@testable import RielaCore

/// CLI surface gate (CSP-2). The enumeration comes from the argument-parser
/// router plus the typed family enums, so a new command appears here the moment
/// it is registered.
final class SurfaceParityCLITests: XCTestCase {
  func testEveryRegisteredCommandHasACatalogRowAndViceVersa() {
    let violations = CLISurfaceEnumerator.violations(
      commands: CLISurfaceEnumerator.commands(),
      catalog: SurfaceCatalog.all
    )
    XCTAssertTrue(
      violations.isEmpty,
      "CLI surface parity violations:\n" + violations.map(\.description).joined(separator: "\n")
    )
  }

  /// Negative proof: registering a command without a catalog row must fail the
  /// gate. The descriptor is injected into the pure checker, so no production
  /// seam has to exist for the sake of the test.
  func testGateFailsForACommandWithoutACatalogRow() {
    let withDummy = CLISurfaceEnumerator.commands() + [CLICommandDescriptor(["dummy", "command"])]
    let violations = CLISurfaceEnumerator.violations(commands: withDummy, catalog: SurfaceCatalog.all)
    XCTAssertEqual(violations.count, 1)
    XCTAssertEqual(violations.first?.subject, "dummy command")
    XCTAssertEqual(violations.first?.surface, .cli)
    XCTAssertTrue(violations.first?.reason.contains("no catalog row") == true)
  }

  /// Negative proof in the other direction: a catalog row claiming a command
  /// the CLI does not register must fail too.
  func testGateFailsForACatalogRowWithoutACommand() {
    let phantom = SurfaceOperation(
      id: "phantom.command",
      family: "phantom",
      kind: .process,
      surfaces: [
        .cli: .implemented,
        .graphql: .excluded(reason: "test row", design: "test"),
        .webAPI: .excluded(reason: "test row", design: "test"),
        .library: .excluded(reason: "test row", design: "test")
      ],
      cli: SurfaceCLIBinding(path: ["phantom", "command"]),
      designSource: "test"
    )
    let violations = CLISurfaceEnumerator.violations(
      commands: CLISurfaceEnumerator.commands(),
      catalog: SurfaceCatalog.all + [phantom]
    )
    XCTAssertEqual(violations.count, 1)
    XCTAssertTrue(violations.first?.reason.contains("absent from the surface") == true)
  }

  /// A catalog row may not document an option no parser accepts. This is the
  /// same check the skill gate applies to documented flags.
  func testGateFailsForAnUnknownOptionOnACatalogRow() {
    let stale = SurfaceOperation(
      id: "phantom.option",
      family: "phantom",
      kind: .process,
      surfaces: [
        .cli: .excluded(reason: "test row", design: "test"),
        .graphql: .excluded(reason: "test row", design: "test"),
        .webAPI: .excluded(reason: "test row", design: "test"),
        .library: .excluded(reason: "test row", design: "test")
      ],
      designSource: "test"
    )
    var withStaleOption = stale
    withStaleOption.cli = nil
    var catalog = SurfaceCatalog.all
    var row = catalog.first { $0.id == "workflow.run" }!
    row.cli?.options.append("--supervisor-workflow")
    catalog.removeAll { $0.id == "workflow.run" }
    catalog.append(row)
    let violations = CLISurfaceEnumerator.violations(commands: CLISurfaceEnumerator.commands(), catalog: catalog)
    XCTAssertTrue(
      violations.contains { $0.subject.contains("--supervisor-workflow") },
      "a stale flag must be rejected: \(violations.map(\.description))"
    )
  }

  func testRouterAndPreParserCommandsAreBothEnumerated() {
    let commands = Set(CLISurfaceEnumerator.commands().map(\.command))
    for expected in [
      "workflow run", "workflow manifest validate", "session rerun", "session continue",
      "loop gates", "package install", "node run", "memory save", "instance list",
      "specialist submit", "graphql schema", "events schedules cancel", "routine create",
      "serve", "serve status", "hook codex", "kaiba instance list", "auth invite",
      "worker", "worker status", "call-step", "workflow-call", "rrun", "gql", "version"
    ] {
      XCTAssertTrue(commands.contains(expected), "CLI enumeration is missing '\(expected)'")
    }
  }

  /// R6: a top-level family registered on the router must be classified as a
  /// leaf or given an expansion case. Without this, a new family with nested
  /// actions would enumerate only its bare name and its subcommands could ship
  /// with no catalog row while the gate stayed green.
  func testEveryRouterRouteIsClassifiedAsALeafOrExpanded() {
    XCTAssertEqual(
      CLISurfaceEnumerator.unclassifiedRoutes(),
      [],
      "these router routes are neither declared leaves nor expanded; classify them in CLISurfaceEnumeration"
    )
  }

  func testAnUnclassifiedRouteWouldHideItsSubcommands() {
    // The classification sets are the gate: a family absent from both is the
    // failure mode this test names.
    XCTAssertFalse(CLISurfaceEnumerator.leafRoutes.contains("task"))
    XCTAssertFalse(CLISurfaceEnumerator.expandedRoutes.contains("task"))
    let classified = CLISurfaceEnumerator.leafRoutes.union(CLISurfaceEnumerator.expandedRoutes)
    XCTAssertTrue(
      Set(CLISurfaceEnumerator.routerCommandNames()).isSubset(of: classified),
      "router routes must all be classified"
    )
  }

  func testOptionUniverseContainsRealFlagsAndRejectsRetiredOnes() {
    let options = CLISurfaceEnumerator.optionNames()
    XCTAssertTrue(options.contains("--max-steps"))
    XCTAssertTrue(options.contains("--auto-improve"))
    XCTAssertTrue(options.contains("--mock-scenario"))
    XCTAssertFalse(options.contains("--supervisor-workflow"))
    XCTAssertFalse(options.contains("--no-allow-targeted-rerun"))
  }
}
