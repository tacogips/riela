import Foundation
import XCTest
@testable import RielaGraphQL

/// Pins every `GraphQL*DTO` struct to its schema type descriptor, so the SDL is
/// derived from the DTOs rather than maintained beside them (design 2.3). The
/// DTO declarations are read from source through `#filePath` (delta D4), so a
/// property added without a schema field fails here.
final class SurfaceParityDTOSchemaTests: XCTestCase {
  func testEveryDTOMatchesItsSchemaTypeFieldForField() throws {
    let declarations = try Self.dtoDeclarations()
    XCTAssertEqual(declarations.count, 27, "expected the 27 documented control-plane DTOs")
    let descriptors = Dictionary(
      uniqueKeysWithValues: GraphQLSchemaGenerator.types.map { ($0.name, $0) }
    )
    for declaration in declarations {
      guard let descriptor = descriptors[declaration.schemaTypeName] else {
        XCTFail("\(declaration.swiftName) has no schema type '\(declaration.schemaTypeName)'")
        continue
      }
      XCTAssertEqual(
        descriptor.fields.map(\.name),
        declaration.properties.map(\.name),
        "\(declaration.swiftName) and schema type \(declaration.schemaTypeName) disagree on field names"
      )
      for (property, field) in zip(declaration.properties, descriptor.fields) {
        XCTAssertEqual(
          Self.graphQLType(forSwiftType: property.type),
          field.type,
          "\(declaration.schemaTypeName).\(field.name) does not match \(declaration.swiftName).\(property.name)"
        )
      }
    }
  }

  func testUnknownSwiftTypesAreRejectedRatherThanGuessed() {
    XCTAssertNil(Self.graphQLType(forSwiftType: "SomeUnmappedType"))
    XCTAssertEqual(Self.graphQLType(forSwiftType: "String?"), "String")
    XCTAssertEqual(Self.graphQLType(forSwiftType: "[GraphQLStepExecutionDTO]"), "[StepExecution!]!")
    XCTAssertEqual(Self.graphQLType(forSwiftType: "JSONValue"), "JSON!")
  }

  // MARK: - Source reading

  struct DTOProperty {
    var name: String
    var type: String
  }

  struct DTODeclaration {
    var swiftName: String
    var properties: [DTOProperty]

    /// `GraphQLFooDTO` is the transport mirror of schema type `Foo`.
    var schemaTypeName: String {
      String(swiftName.dropFirst("GraphQL".count).dropLast("DTO".count))
    }
  }

  static func dtoDeclarations() throws -> [DTODeclaration] {
    var declarations: [DTODeclaration] = []
    for name in [
      "GraphQLContracts.swift",
      "GraphQLLoopAnalyticsContracts.swift",
      "GraphQLSessionObservabilityContracts.swift"
    ] {
      let url = SurfaceParityGraphQLTests.repositoryRoot()
        .appendingPathComponent("Sources/RielaGraphQL/\(name)")
      declarations.append(contentsOf: parseDTOs(in: try String(contentsOf: url, encoding: .utf8)))
    }
    return declarations
  }

  static func parseDTOs(in source: String) -> [DTODeclaration] {
    var declarations: [DTODeclaration] = []
    var current: DTODeclaration?
    for line in source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
      if let name = declaredDTOName(in: line) {
        if let current { declarations.append(current) }
        current = DTODeclaration(swiftName: name, properties: [])
        continue
      }
      guard current != nil else { continue }
      if line == "}" {
        declarations.append(current!)
        current = nil
        continue
      }
      // Only the stored properties at the type's own indentation count; the
      // initialiser parameters below them are indented further.
      guard line.hasPrefix("  public var "), !line.contains("{") else { continue }
      let declaration = line.dropFirst("  public var ".count)
      let parts = declaration.split(separator: ":", maxSplits: 1).map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      guard parts.count == 2 else { continue }
      current?.properties.append(DTOProperty(name: parts[0], type: parts[1]))
    }
    if let current { declarations.append(current) }
    return declarations
  }

  private static func declaredDTOName(in line: String) -> String? {
    guard line.hasPrefix("public struct GraphQL"), line.contains("DTO") else { return nil }
    let afterKeyword = line.dropFirst("public struct ".count)
    let name = afterKeyword.prefix { $0.isLetter || $0.isNumber }
    return name.hasSuffix("DTO") ? String(name) : nil
  }

  // MARK: - Type mapping

  static let scalarMapping: [String: String] = [
    "String": "String",
    "Int": "Int",
    "Bool": "Boolean",
    "Date": "String",
    "JSONObject": "JSONObject",
    "JSONValue": "JSON",
    "WorkflowStepBudgetDiagnostic": "StepBudgetDiagnostic"
  ]

  /// The single Swift-to-GraphQL mapping the schema descriptors follow.
  static func graphQLType(forSwiftType swiftType: String) -> String? {
    if swiftType.hasSuffix("?") {
      guard let inner = graphQLType(forSwiftType: String(swiftType.dropLast())) else { return nil }
      return inner.hasSuffix("!") ? String(inner.dropLast()) : inner
    }
    if swiftType.hasPrefix("["), swiftType.hasSuffix("]") {
      let element = String(swiftType.dropFirst().dropLast())
      guard let inner = graphQLType(forSwiftType: element) else { return nil }
      return "[\(inner.hasSuffix("!") ? inner : inner + "!")]!"
    }
    if let scalar = scalarMapping[swiftType] {
      return "\(scalar)!"
    }
    if swiftType.hasPrefix("GraphQL"), swiftType.hasSuffix("DTO") {
      return "\(swiftType.dropFirst("GraphQL".count).dropLast("DTO".count))!"
    }
    return nil
  }
}
