import Foundation
import RielaAddonSupport
import RielaCore

enum BuiltinDataAddon: String {
  case compose = "riela/json-compose"
  case batch = "riela/array-batch"
  case transform = "riela/json-transform"
}

extension BuiltinWorkflowAddonResolver {
  /// Typed, deterministic wiring. Templates are rendered once: strings inside
  /// supplied application data are data, never a second template/program.
  func executeDataAddon(_ input: WorkflowAddonExecutionInput, operation: BuiltinDataAddon) throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(.invalidInput, "unsupported data add-on version")
    }
    // The contract schema stays literal (like agent output schemas) and is
    // checked before any work, so an unsupported schema is an input error.
    var templatedConfig = input.addon.config ?? [:]
    let schemaObject: JSONObject?
    switch templatedConfig.removeValue(forKey: "jsonSchema") {
    case nil:
      schemaObject = nil
    case let .object(schema)?:
      guard DefaultWorkflowOutputValidator().validateContractSchema(schema) == nil else {
        throw AdapterExecutionError(.invalidInput, "data add-on jsonSchema is not a supported output schema")
      }
      schemaObject = schema
    default:
      throw AdapterExecutionError(.invalidInput, "data add-on jsonSchema must be an object")
    }
    let variables = try addonVariables(for: input)
    guard case let .object(config) = try renderAddonConfig(.object(templatedConfig), variables: variables) else {
      throw AdapterExecutionError(.invalidInput, "data add-on requires an object config")
    }
    let payload: JSONObject
    switch operation {
    case .transform:
      guard Set(config.keys).isSubset(of: ["input", "steps", "jsonSchema"]),
            let value = config["input"], let steps = config["steps"] else {
        throw AdapterExecutionError(.invalidInput, "json-transform requires input and steps")
      }
      payload = ["value": try JSONDataTransform.run(value, steps: steps)]
    case .compose:
      guard Set(config.keys).isSubset(of: ["payload", "jsonSchema"]),
            case let .object(value)? = config["payload"] else {
        throw AdapterExecutionError(.invalidInput, "json-compose requires an object payload")
      }
      payload = value
    case .batch:
      guard Set(config.keys).isSubset(of: ["items", "size", "minItems", "maxItems", "uniqueBy", "jsonSchema"]),
            case let .array(items)? = config["items"] else {
        throw AdapterExecutionError(.invalidInput, "array-batch requires items")
      }
      let size = try dataInteger(config, "size", fallback: 1, range: 1...10_000)
      let minimum = try dataInteger(config, "minItems", fallback: 0, range: 0...10_000)
      let maximum = try dataInteger(config, "maxItems", fallback: 10_000, range: 0...10_000)
      guard minimum <= maximum, (minimum...maximum).contains(items.count) else {
        throw AdapterExecutionError(.invalidInput, "array-batch item count is outside the configured bounds")
      }
      if let field = config["uniqueBy"] {
        guard case let .string(key) = field, !key.isEmpty, key.utf8.count <= 256 else {
          throw AdapterExecutionError(.invalidInput, "array-batch uniqueBy must name an object field")
        }
        var seen = Set<String>()
        for item in items {
          guard case let .object(object) = item, let identity = object[key],
                case let .string(text) = identity, !text.isEmpty, seen.insert(text).inserted else {
            throw AdapterExecutionError(.invalidInput, "array-batch identities must be distinct nonempty strings")
          }
        }
      }
      let batches = stride(from: 0, to: items.count, by: size).map { start in
        JSONValue.array(Array(items[start..<min(start + size, items.count)]))
      }
      payload = ["items": .array(batches), "itemCount": .integer(Int64(items.count)),
                 "batchCount": .integer(Int64(batches.count))]
    }
    guard try JSONEncoder().encode(payload).count <= 8_000_000 else {
      throw AdapterExecutionError(.invalidOutput, "data add-on output exceeds the size limit")
    }
    if let schemaObject {
      let result = try DefaultWorkflowOutputValidator().validate(
        RuntimeOutputCandidate(source: .inlineCandidate, payload: payload, completionPassed: true),
        contract: .init(schema: schemaObject, requiredObject: true))
      guard result.status == .accepted else {
        // Validation paths are safe metadata; payload values never enter errors.
        throw AdapterExecutionError(.invalidOutput, "data add-on output contract rejected")
      }
    }
    return AdapterExecutionOutput(provider: "riela-builtin-addon", model: input.addon.name,
      promptText: "", completionPassed: true, payload: payload)
  }

  private func dataInteger(_ config: JSONObject, _ key: String, fallback: Int, range: ClosedRange<Int>) throws -> Int {
    guard let value = config[key] else { return fallback }
    guard case let .integer(raw) = value, let integer = Int(exactly: raw), range.contains(integer) else {
      throw AdapterExecutionError(.invalidInput, "data add-on \(key) must be an integer in \(range)")
    }
    return integer
  }
}
