import Foundation
import RielaAddonSupport
import RielaCore
import RielaMemory

enum BuiltinKeyValueAddon: String {
  case set = "riela/kv-set"
  case get = "riela/kv-get"
  case delete = "riela/kv-delete"
  case list = "riela/kv-list"
}

func keyValueSetValue(config: JSONObject, variables: JSONObject) throws -> MemoryJSONValue {
  if let valueTemplate = config["valueTemplate"] ?? variables["valueTemplate"] {
    return try memoryJSONValue(from: renderJSONTemplates(valueTemplate, variables: variables))
  }
  if let value = config["value"] ?? variables["value"] {
    return try memoryJSONValue(from: value)
  }
  throw AdapterExecutionError(.policyBlocked, "kv value is required (config.value, config.valueTemplate, or inputs.value)")
}

func keyValueAddonOutput(
  input: WorkflowAddonExecutionInput,
  operation: BuiltinKeyValueAddon,
  storeId: String,
  scope: String,
  databasePath: String,
  payload extraPayload: JSONObject
) -> AdapterExecutionOutput {
  var payload: JSONObject = [
    "status": .string("ok"),
    "addon": .string(input.addon.name),
    "operation": .string(operation.rawValue.replacingOccurrences(of: "riela/kv-", with: "")),
    "stepId": .string(input.stepId),
    "storeId": .string(storeId),
    "scope": .string(scope),
    "databasePath": .string(databasePath)
  ]
  for (key, value) in extraPayload {
    payload[key] = value
  }
  return AdapterExecutionOutput(
    provider: "riela-builtin-addon",
    model: input.addon.name,
    promptText: "",
    completionPassed: true,
    payload: payload
  )
}

func keyValueEntryJSON(_ entry: KeyValueEntry) -> JSONValue {
  .object([
    "storeId": .string(entry.storeId),
    "scope": .string(entry.scope),
    "key": .string(entry.key),
    "value": jsonValue(from: entry.value),
    "createdAt": .string(entry.createdAt),
    "updatedAt": .string(entry.updatedAt)
  ])
}

extension BuiltinWorkflowAddonResolver {
  func executeKeyValueAddon(
    _ input: WorkflowAddonExecutionInput,
    operation: BuiltinKeyValueAddon
  ) throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(.policyBlocked, "unsupported \(input.addon.name) version '\(input.addon.version ?? "")'")
    }

    let config = input.addon.config ?? [:]
    let variables = addonVariables(for: input)
    let workflowInput = memoryAddonJSONObject(variables["workflowInput"])
    let kvRoot = memoryConfigString("kvRoot", config: config, variables: variables)
      ?? nonEmptyString(variables["kvRoot"])
      ?? nonEmptyString(workflowInput["kvRoot"])
      ?? RielaKeyValueStore.defaultRootDirectory(workingDirectory: workingDirectory.path)
    let storeId = memoryConfigString("storeId", config: config, variables: variables)
      ?? nonEmptyString(variables["storeId"]) ?? "workflow-kv"
    // Durable-object semantics: entries default to the workflow's own namespace
    // so successive runs of one workflow share state without leaking into other
    // workflows; an explicit scope opts into cross-workflow sharing.
    let scope = memoryConfigString("scope", config: config, variables: variables)
      ?? nonEmptyString(variables["scope"]) ?? input.workflowId
    let store = RielaKeyValueStore(rootDirectory: kvRoot)

    func requiredKey() throws -> String {
      guard let key = memoryConfigString("key", config: config, variables: variables)
        ?? nonEmptyString(variables["key"])
      else {
        throw AdapterExecutionError(.policyBlocked, "kv key is required (config.key or inputs.key)")
      }
      return key
    }

    do {
      switch operation {
      case .set:
        let key = try requiredKey()
        let value = try keyValueSetValue(config: config, variables: variables)
        let entry = try store.set(storeId: storeId, scope: scope, key: key, value: value)
        return keyValueAddonOutput(
          input: input,
          operation: operation,
          storeId: storeId,
          scope: scope,
          databasePath: try store.databasePath(storeId: storeId),
          payload: [
            "saved": .bool(true),
            "key": .string(key),
            "value": jsonValue(from: entry.value),
            "entry": keyValueEntryJSON(entry)
          ]
        )
      case .get:
        let key = try requiredKey()
        let entry = try store.get(storeId: storeId, scope: scope, key: key)
        let defaultValue = config["default"] ?? variables["default"]
        var payload: JSONObject = [
          "found": .bool(entry != nil),
          "key": .string(key),
          "value": entry.map { jsonValue(from: $0.value) } ?? defaultValue ?? .null
        ]
        if let entry {
          payload["entry"] = keyValueEntryJSON(entry)
        }
        return keyValueAddonOutput(
          input: input,
          operation: operation,
          storeId: storeId,
          scope: scope,
          databasePath: try store.databasePath(storeId: storeId),
          payload: payload
        )
      case .delete:
        let key = try requiredKey()
        let deleted = try store.delete(storeId: storeId, scope: scope, key: key)
        return keyValueAddonOutput(
          input: input,
          operation: operation,
          storeId: storeId,
          scope: scope,
          databasePath: try store.databasePath(storeId: storeId),
          payload: [
            "deleted": .bool(deleted),
            "key": .string(key)
          ]
        )
      case .list:
        let keyPrefix = memoryConfigString("keyPrefix", config: config, variables: variables)
          ?? nonEmptyString(variables["keyPrefix"])
        let limit = intValue(config["limit"]) ?? intValue(variables["limit"]) ?? 100
        let offset = intValue(config["offset"]) ?? intValue(variables["offset"]) ?? 0
        let entries = try store.list(
          storeId: storeId,
          scope: scope,
          options: KeyValueListOptions(keyPrefix: keyPrefix, limit: limit, offset: offset)
        )
        return keyValueAddonOutput(
          input: input,
          operation: operation,
          storeId: storeId,
          scope: scope,
          databasePath: try store.databasePath(storeId: storeId),
          payload: [
            "entries": .array(entries.map(keyValueEntryJSON)),
            "keys": .array(entries.map { .string($0.key) }),
            "count": .number(Double(entries.count)),
            "limit": .number(Double(limit)),
            "offset": .number(Double(offset))
          ]
        )
      }
    } catch let error as RielaMemoryError {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) failed: \(error)")
    }
  }
}
