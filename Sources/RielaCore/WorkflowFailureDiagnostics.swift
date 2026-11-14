import Foundation

/// Explicit, finite metadata policy. Failed stdout is never an accepted node output.
public struct WorkflowFailureDiagnostics: Codable, Equatable, Sendable {
  public var schema: JSONObject
  public var maxBytes: Int
  public var path: [String]
  public static let stdoutByteLimit = 65_536

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
