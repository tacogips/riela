import Foundation

/// Keep dynamic finite-ID/enumeration schemas in data, instead of generating
/// temporary workflow files. A static schema, when present, remains mandatory.
public func resolveNodeOutputContract(_ output: NodeOutputContract?, variables: JSONObject) throws -> NodeOutputContract? {
  guard var output, let pointer = output.jsonSchemaFrom else { return output }
  guard validOutputSchemaPointer(pointer),
        case let .object(schema)? = fanoutJSONPointer(.object(variables), pointer),
        try JSONEncoder().encode(schema).count <= 1_000_000,
        DefaultWorkflowOutputValidator().validateContractSchema(schema) == nil else {
    throw AdapterExecutionError(.invalidInput, "output.jsonSchemaFrom must resolve to a supported object output schema")
  }
  if case let .object(properties)? = schema["properties"], properties["handover"] != nil {
    throw AdapterExecutionError(.invalidInput, "output schema must not declare the reserved handover key")
  }
  // Native structured output hands the schema to the vendor verbatim; a
  // composed root `allOf` is not an accepted strict-output root.
  guard output.nativeStructuredOutput != true || output.jsonSchema == nil else {
    throw AdapterExecutionError(.invalidInput, "output.nativeStructuredOutput cannot combine jsonSchema with jsonSchemaFrom")
  }
  output.jsonSchema = output.jsonSchema.map { ["allOf": .array([.object($0), .object(schema)])] } ?? schema
  output.jsonSchemaFrom = nil
  return output
}

func validOutputSchemaPointer(_ pointer: String) -> Bool {
  guard pointer.hasPrefix("/"), pointer.utf8.count <= 1024,
        !pointer.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return false }
  var index = pointer.startIndex
  while index < pointer.endIndex {
    if pointer[index] == "~" {
      index = pointer.index(after: index)
      guard index < pointer.endIndex, pointer[index] == "0" || pointer[index] == "1" else { return false }
    }
    index = pointer.index(after: index)
  }
  return true
}
