import Foundation

extension GraphQLSchemaGenerator {
  /// The complete text of the checked-in `GraphQLContractProjector+Schema.swift`.
  /// The hand-written blocks are emitted as Swift interpolations so the checked-in
  /// literal and `render()` keep reading one source for them.
  static func swiftSourceTemplate() -> String {
    let body = renderTemplate(
      handWrittenBlocks: handWrittenSchemaBlockNames.map { "\\(\($0))" }, renderType: compactSwiftType
    )
    let indented = body
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { "  " + $0 }
      .joined(separator: "\n")
    return """
    // GENERATED FILE - do not edit by hand.
    //
    // Rendered by `GraphQLSchemaGenerator.render()` from the control-plane
    // contract descriptors in `GraphQLSchemaGenerator.swift` plus the GraphQL
    // bindings in `SurfaceCatalog`. Regenerate with
    // `scripts/surface-parity/generate-sdl.sh`; `SurfaceParityGraphQLTests`
    // fails if this file and the generator disagree by a single byte.
    extension GraphQLContractProjector {
      public static let schemaContract = \"\"\"
    \(indented)
      \"\"\"
    }

    """
  }

  private static func compactSwiftType(_ type: TypeDescriptor) -> String {
    let schema = renderType(type)
    guard type.fields.count <= 2, schema.utf8.count <= 160 else { return schema }
    // A Swift newline escape preserves the exact SDL produced by render().
    return schema.replacingOccurrences(of: "\n", with: "\\n")
  }
}
