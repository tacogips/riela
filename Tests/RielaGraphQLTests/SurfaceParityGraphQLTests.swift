import Foundation
import RielaCore
import XCTest
@testable import RielaGraphQL

/// GraphQL surface gate and generated-SDL freshness (CSP-3).
final class SurfaceParityGraphQLTests: XCTestCase {
  /// Every root field the schema publishes has a catalog row, and every row that
  /// claims GraphQL is published. Fields are read from the assembled schema, so
  /// the registry, configuration and routine blocks are covered too.
  func testSchemaRootFieldsMatchTheCatalog() {
    let violations = SurfaceCatalog.bijectionViolations(
      surface: .graphql,
      actual: Self.schemaRootFields(),
      declared: SurfaceCatalog.declaredGraphQLFields
    )
    XCTAssertTrue(
      violations.isEmpty,
      "GraphQL surface parity violations:\n" + violations.map(\.description).joined(separator: "\n")
    )
  }

  func testGeneratorSignatureTableAndCatalogAgree() {
    let violations = GraphQLSchemaGenerator.rootFieldCoverageViolations()
    XCTAssertTrue(
      violations.isEmpty,
      "generator/catalog root-field mismatch:\n" + violations.map(\.description).joined(separator: "\n")
    )
  }

  /// The checked-in SDL is byte-identical to the generator's output. When it is
  /// not, the regenerated file is written under `tmp/surface-parity/` and its
  /// path is printed.
  func testCheckedInSDLIsByteIdenticalToTheGenerator() throws {
    let generated = GraphQLSchemaGenerator.render()
    if generated != GraphQLContractProjector.schemaContract {
      let url = try Self.writeRegeneratedSource()
      XCTFail("schemaContract is stale; regenerated source written to \(url.path)")
    }
  }

  func testCheckedInSourceFileIsByteIdenticalToTheGenerator() throws {
    let url = Self.generatedSchemaSourceURL()
    let onDisk = try String(contentsOf: url, encoding: .utf8)
    let expected = GraphQLSchemaGenerator.swiftSourceTemplate()
    if onDisk != expected {
      let scratch = try Self.writeRegeneratedSource()
      XCTFail(
        "\(url.lastPathComponent) is not the generator's output; "
          + "run scripts/surface-parity/generate-sdl.sh (preview at \(scratch.path))"
      )
    }
  }

  /// `scripts/surface-parity/generate-sdl.sh` sets this variable and reruns the
  /// suite; the regeneration therefore lives in the same code path the freshness
  /// test checks, with no separate tool target (delta D4).
  func testRegenerateGeneratedSDLWhenRequested() throws {
    guard ProcessInfo.processInfo.environment["RIELA_WRITE_GENERATED_SDL"] == "1" else {
      throw XCTSkip("regeneration runs only from scripts/surface-parity/generate-sdl.sh")
    }
    let url = Self.generatedSchemaSourceURL()
    try GraphQLSchemaGenerator.swiftSourceTemplate().write(to: url, atomically: true, encoding: .utf8)
    print("regenerated \(url.path)")
  }

  func testSchemaCarriesTheSessionMutationsAndConsoleReads() {
    let schema = GraphQLContractProjector.schemaContract
    for token in [
      "rerunSession(input: RerunSessionInput!): SessionMutationPayload!",
      "resumeSession(input: ResumeSessionInput!): SessionMutationPayload!",
      "stopSession(input: StopSessionInput!): SessionMutationPayload!",
      "consoleInstances: ConsoleInstanceListPayload!",
      "consoleInstance(identity: String!): ConsoleInstancePayload!",
      "opsOverview: OpsOverviewPayload!"
    ] {
      XCTAssertTrue(schema.contains(token), "schema is missing '\(token)'")
    }
  }

  // MARK: - Helpers

  static func schemaRootFields() -> Set<String> {
    var fields: Set<String> = []
    for root in ["Query", "Mutation"] {
      for name in rootFieldNames(in: GraphQLContractProjector.schemaContract, typeName: root) {
        fields.insert("\(root).\(name)")
      }
    }
    return fields
  }

  private static func rootFieldNames(in schema: String, typeName: String) -> [String] {
    let pattern = "type\\s+\(typeName)\\s*\\{(.*?)\\n\\s*\\}"
    guard let expression = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
      return []
    }
    let range = NSRange(schema.startIndex..<schema.endIndex, in: schema)
    guard let match = expression.firstMatch(in: schema, range: range),
          let bodyRange = Range(match.range(at: 1), in: schema) else {
      return []
    }
    let body = String(schema[bodyRange])
    return body.split(separator: "\n").compactMap { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else { return nil }
      let name = trimmed.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
      return name.isEmpty ? nil : String(name)
    }
  }

  static func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // RielaGraphQLTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // repository root
  }

  static func generatedSchemaSourceURL() -> URL {
    repositoryRoot()
      .appendingPathComponent("Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift")
  }

  private static func writeRegeneratedSource() throws -> URL {
    let directory = repositoryRoot().appendingPathComponent("tmp/surface-parity", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("GraphQLContractProjector+Schema.swift.generated")
    try GraphQLSchemaGenerator.swiftSourceTemplate().write(to: url, atomically: true, encoding: .utf8)
    return url
  }
}
