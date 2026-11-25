import Foundation
import RielaCore

public enum GraphQLSelectionBuilder {
  public struct Document: Sendable {
    public let query: String
    public let field: GraphQLSchemaGenerator.FieldDescriptor
  }

  private static let objects = Dictionary(uniqueKeysWithValues: GraphQLSchemaGenerator.types
    .filter { $0.kind == .object }.map { ($0.name, $0) })

  public static func object(forType type: String) -> GraphQLSchemaGenerator.TypeDescriptor? {
    objects[type.trimmingCharacters(in: CharacterSet(charactersIn: "[]!"))]
  }

  public static func selection(forType type: String) -> String {
    selection(forType: type, ancestors: [])
  }

  public static func document(for root: String, arguments: Set<String>) throws -> Document {
    guard let field = GraphQLSchemaGenerator.rootFields[root],
      let rootKind = root.split(separator: ".").first else {
      throw invalidDocument(root)
    }
    let declared = field.arguments?.split(separator: ",") ?? []
    var variables: [String] = []
    var bindings: [String] = []
    for argument in declared {
      let pieces = argument.split(separator: ":", maxSplits: 1)
      guard pieces.count == 2 else { throw invalidDocument(root) }
      let name = pieces[0].trimmingCharacters(in: .whitespaces)
      guard arguments.contains(name) else { continue }
      let type = pieces[1].split(separator: "=", maxSplits: 1)[0].trimmingCharacters(in: .whitespaces)
      variables.append("$\(name): \(type)")
      bindings.append("\(name): $\(name)")
    }
    guard bindings.count == arguments.count else { throw invalidDocument(root) }
    let definitions = variables.isEmpty ? "" : "(\(variables.joined(separator: ", ")))"
    let passed = bindings.isEmpty ? "" : "(\(bindings.joined(separator: ", ")))"
    let values = selection(forType: field.type)
    let projection = values.isEmpty ? "" : " { \(values) }"
    return Document(
      query: "\(rootKind.lowercased())\(definitions) { \(field.name)\(passed)\(projection) }", field: field
    )
  }

  private static func selection(forType type: String, ancestors: Set<String>) -> String {
    guard let descriptor = object(forType: type), !ancestors.contains(descriptor.name) else { return "" }
    let children = ancestors.union([descriptor.name])
    return descriptor.fields.compactMap { field in
      guard object(forType: field.type) != nil else { return field.name }
      let nested = selection(forType: field.type, ancestors: children)
      return nested.isEmpty ? nil : "\(field.name) { \(nested) }"
    }.joined(separator: " ")
  }

  private static func invalidDocument(_ root: String) -> BotStoreError {
    BotStoreError(code: "remote_document_invalid", message: "Cannot build a document for \(root)")
  }
}
