import Foundation

/// Explicit, finite metadata policy. Failed stdout is never an accepted node output.
public struct WorkflowFailureDiagnostics: Codable, Equatable, Sendable {
  public var schema: JSONObject
  public var maxBytes: Int
  public var path: [String]
  public static let stdoutByteLimit = 65_536
  /// Backend event type of the non-authoritative failure receipt.
  public static let eventType = "command_failure_diagnostics"
  /// Backend event provider of the failure receipt.
  public static let eventProvider = "command"
  /// Encoded size bound of a retained receipt: the selected diagnostics are
  /// at most `stdoutByteLimit` bytes, plus the fixed envelope keys.
  public static let eventMetadataByteLimit = stdoutByteLimit + 256

  public init(schema: JSONObject, maxBytes: Int = 16_384, path: [String] = []) {
    self.schema = schema
    self.maxBytes = maxBytes
    self.path = path
  }

  enum CodingKeys: String, CodingKey { case schema, maxBytes, path }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schema = try container.decode(JSONObject.self, forKey: .schema)
    maxBytes = try container.decodeIfPresent(Int.self, forKey: .maxBytes) ?? 16_384
    path = try container.decodeIfPresent([String].self, forKey: .path) ?? []
  }

  public func metadata(from stdout: String) -> JSONObject? {
    guard (1...Self.stdoutByteLimit).contains(maxBytes), stdout.utf8.count <= Self.stdoutByteLimit,
      path.count <= 8, path.allSatisfy({ key in
        !key.isEmpty && key.utf8.count <= 64 && key.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
      }), let data = stdout.data(using: .utf8),
      var value = try? JSONDecoder().decode(JSONValue.self, from: data)
    else { return nil }
    for key in path {
      guard case .object(let object) = value, let child = object[key] else { return nil }
      value = child
    }
    guard case .object(let object) = value, Self.accepts(value, schema: schema, depth: 0),
      let selected = try? JSONEncoder().encode(value), selected.count <= maxBytes else { return nil }
    return object
  }

  /// Static checks of this policy, without any command output: `maxBytes`,
  /// `path`, and the restricted schema (`schemaDiagnostics`) with an object
  /// root, which `metadata(from:)` requires. Empty means the policy can
  /// validate output; each string names the offending field. A non-empty
  /// result means every capture would be `rejected`.
  public func validationDiagnostics() -> [String] {
    var diagnostics: [String] = []
    if !(1...Self.stdoutByteLimit).contains(maxBytes) {
      diagnostics.append("maxBytes must be between 1 and \(Self.stdoutByteLimit)")
    }
    if path.count > 8 {
      diagnostics.append("path must have at most 8 keys")
    }
    for (index, key) in path.enumerated() where !Self.isBoundedKey(key) {
      diagnostics.append("path[\(index)] must be a non-empty key of at most 64 bytes without control characters")
    }
    if schema["type"] != .string("object") {
      diagnostics.append("schema: root type must be object")
    }
    diagnostics.append(contentsOf: Self.schemaDiagnostics(schema))
    return diagnostics
  }

  /// Checks a restricted diagnostics schema without a value. It applies the
  /// same structural rules `metadata(from:)` enforces while matching output:
  /// closed objects, bounded arrays, enum-only strings, bounded integers,
  /// booleans and nulls, at most 8 levels deep. Each diagnostic is prefixed
  /// with a JSON-pointer-style location (`schema/properties/status: ...`).
  public static func schemaDiagnostics(_ schema: JSONObject) -> [String] {
    schemaDiagnostics(schema, location: "schema", depth: 0)
  }

  private static func schemaDiagnostics(_ schema: JSONObject, location: String, depth: Int) -> [String] {
    guard depth <= 8 else { return ["\(location): schema nesting exceeds 8 levels"] }
    guard case .string(let type)? = schema["type"] else { return ["\(location): type must be a string"] }
    func keys(_ expected: Set<String>) -> [String] {
      Set(schema.keys) == expected ? [] : ["\(location): \(type) schema must have exactly the keys \(expected.sorted().joined(separator: ", "))"]
    }
    switch type {
    case "object":
      var diagnostics = keys(["type", "properties", "required", "additionalProperties"])
      if schema["additionalProperties"] != .bool(false) {
        diagnostics.append("\(location): additionalProperties must be false")
      }
      guard case .object(let properties)? = schema["properties"], properties.count <= 64 else {
        return diagnostics + ["\(location): properties must be an object with at most 64 entries"]
      }
      if case .array(let required)? = schema["required"], required.count <= 64 {
        let requiredKeys = required.compactMap { item -> String? in
          if case .string(let key) = item { return key }; return nil
        }
        if requiredKeys.count != required.count || Set(requiredKeys).count != requiredKeys.count
          || !Set(requiredKeys).isSubset(of: Set(properties.keys)) {
          diagnostics.append("\(location): required must list unique declared property names")
        }
      } else {
        diagnostics.append("\(location): required must be an array with at most 64 entries")
      }
      for key in properties.keys.sorted() {
        guard key.utf8.count <= 64 else {
          diagnostics.append("\(location)/properties: property name exceeds 64 bytes")
          continue
        }
        guard case .object(let child)? = properties[key] else {
          diagnostics.append("\(location)/properties/\(key): must be a schema object")
          continue
        }
        diagnostics += schemaDiagnostics(child, location: "\(location)/properties/\(key)", depth: depth + 1)
      }
      return diagnostics
    case "array":
      var diagnostics = keys(["type", "items", "maxItems"])
      if !(schema["maxItems"]?.asInt64.map { (0...256).contains($0) } ?? false) {
        diagnostics.append("\(location): maxItems must be an integer between 0 and 256")
      }
      guard case .object(let items)? = schema["items"] else {
        return diagnostics + ["\(location): items must be a schema object"]
      }
      return diagnostics + schemaDiagnostics(items, location: "\(location)/items", depth: depth + 1)
    case "string":
      var diagnostics = keys(["type", "enum"])
      let validChoices: Bool
      if case .array(let choices)? = schema["enum"], (1...64).contains(choices.count) {
        validChoices = choices.allSatisfy { choice in
          if case .string(let text) = choice { return isBoundedKey(text) }
          return false
        }
      } else {
        validChoices = false
      }
      if !validChoices {
        diagnostics.append("\(location): enum must list 1 to 64 non-empty strings of at most 64 bytes without control characters")
      }
      return diagnostics
    case "integer":
      var diagnostics = keys(["type", "minimum", "maximum"])
      if let low = schema["minimum"]?.asInt64, let high = schema["maximum"]?.asInt64 {
        if low < -1_000_000_000 || high > 1_000_000_000 || low > high {
          diagnostics.append("\(location): minimum and maximum must satisfy -1000000000 <= minimum <= maximum <= 1000000000")
        }
      } else {
        diagnostics.append("\(location): minimum and maximum must be integers")
      }
      return diagnostics
    case "boolean", "null":
      return keys(["type"])
    default:
      return ["\(location): unsupported type \(type); use object, array, string (enum), integer, boolean or null"]
    }
  }

  private static func isBoundedKey(_ key: String) -> Bool {
    !key.isEmpty && key.utf8.count <= 64 && key.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
  }

  /// The receipt metadata the command executor emits for a failed command.
  public static func eventMetadata(exitCode: Int32, diagnostics: JSONObject?) -> JSONObject {
    var metadata: JSONObject = [
      "authoritative": .bool(false), "exitCode": .integer(Int64(exitCode)),
      "captureStatus": .string(diagnostics == nil ? "rejected" : "validated")
    ]
    if let diagnostics { metadata["diagnostics"] = .object(diagnostics) }
    return metadata
  }

  /// The backend-event metadata a runtime store may retain. Only a
  /// `command_failure_diagnostics` event keeps metadata, and only when it has
  /// exactly the receipt shape `eventMetadata` produces and fits
  /// `eventMetadataByteLimit`; anything else (including a remote worker's
  /// arbitrary object under that event name) is dropped.
  public static func retainedEventMetadata(eventType: String, metadata: JSONObject?) -> JSONObject? {
    guard eventType == Self.eventType, let metadata,
      metadata["authoritative"] == .bool(false),
      case .integer(let exitCode)? = metadata["exitCode"], (Int64(Int32.min)...Int64(Int32.max)).contains(exitCode),
      case .string(let captureStatus)? = metadata["captureStatus"]
    else { return nil }
    switch (captureStatus, metadata["diagnostics"]) {
    case ("validated", .object?):
      guard Set(metadata.keys) == ["authoritative", "exitCode", "captureStatus", "diagnostics"] else { return nil }
    case ("rejected", nil):
      guard Set(metadata.keys) == ["authoritative", "exitCode", "captureStatus"] else { return nil }
    default:
      return nil
    }
    guard let encoded = try? JSONEncoder().encode(metadata), encoded.count <= eventMetadataByteLimit else { return nil }
    return metadata
  }

  // Deliberately smaller than JSON Schema: no free strings, open objects,
  // references, coercion, regex, arbitrary annotations or unbounded collections.
  private static func accepts(_ value: JSONValue, schema: JSONObject, depth: Int) -> Bool {
    guard depth <= 8, case .string(let type)? = schema["type"] else { return false }
    switch (type, value) {
    case ("object", .object(let object)):
      guard Set(schema.keys) == ["type", "properties", "required", "additionalProperties"],
        schema["additionalProperties"] == .bool(false),
        case .object(let properties)? = schema["properties"], properties.count <= 64,
        case .array(let required)? = schema["required"], required.count <= 64,
        Set(object.keys).isSubset(of: Set(properties.keys))
      else { return false }
      let requiredKeys = required.compactMap { item -> String? in
        if case .string(let key) = item { return key }; return nil
      }
      guard requiredKeys.count == required.count, Set(requiredKeys).count == requiredKeys.count,
        Set(requiredKeys).isSubset(of: Set(properties.keys)), Set(requiredKeys).isSubset(of: Set(object.keys))
      else { return false }
      return object.allSatisfy { key, child in
        guard key.utf8.count <= 64, case .object(let childSchema)? = properties[key] else { return false }
        return accepts(child, schema: childSchema, depth: depth + 1)
      }
    case ("array", .array(let items)):
      guard Set(schema.keys) == ["type", "items", "maxItems"],
        let limit = schema["maxItems"]?.asInt64, (0...256).contains(limit), items.count <= limit,
        case .object(let childSchema)? = schema["items"] else { return false }
      return items.allSatisfy { accepts($0, schema: childSchema, depth: depth + 1) }
    case ("string", .string(let string)):
      guard Set(schema.keys) == ["type", "enum"], case .array(let choices)? = schema["enum"],
        (1...64).contains(choices.count), string.utf8.count <= 64,
        choices.allSatisfy({ choice in
          if case .string(let text) = choice {
            return !text.isEmpty && text.utf8.count <= 64 && text.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
          }
          return false
        }) else { return false }
      return choices.contains(value)
    case ("integer", .integer(let integer)):
      guard Set(schema.keys) == ["type", "minimum", "maximum"],
        let low = schema["minimum"]?.asInt64, let high = schema["maximum"]?.asInt64,
        low >= -1_000_000_000, high <= 1_000_000_000, low <= high else { return false }
      return (low...high).contains(integer)
    case ("boolean", .bool): return Set(schema.keys) == ["type"]
    case ("null", .null): return Set(schema.keys) == ["type"]
    default: return false
    }
  }
}
