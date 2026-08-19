import Foundation
import RielaAddonSupport
import RielaCore
import RielaMemory

// Digest add-ons (riela/x-digest, riela/gmail-digest) historically persist
// their fetch cursor in an ad-hoc JSON state file. `stateBackend: "kv"` moves
// that state into the shared workflow key-value store so it lives alongside
// other durable workflow state and gets the same (scope, key) namespacing.
enum DigestStateStorage {
  case file
  case keyValue(DigestKeyValueStateStore)
}

struct DigestKeyValueStateStore {
  var store: RielaKeyValueStore
  var storeId: String
  var stateKey: String
  var scope: String
  var addonName: String

  func readState() throws -> JSONObject {
    do {
      guard let entry = try store.get(storeId: storeId, scope: scope, key: stateKey),
        case let .object(state) = jsonValue(from: entry.value)
      else {
        return [:]
      }
      return state
    } catch let error as RielaMemoryError {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) kv state read failed: \(error)")
    }
  }

  func writeState(_ state: JSONObject) throws {
    do {
      try store.set(storeId: storeId, scope: scope, key: stateKey, value: memoryJSONValue(from: .object(state)))
    } catch let error as RielaMemoryError {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) kv state write failed: \(error)")
    }
  }

  func payloadFields() -> JSONObject {
    [
      "stateBackend": .string("kv"),
      "stateFile": .string(""),
      "stateStoreId": .string(storeId),
      "stateKey": .string(stateKey),
      "stateScope": .string(scope),
      "stateStorePath": .string((try? store.databasePath(storeId: storeId)) ?? "")
    ]
  }
}

func resolveDigestStateStorage(
  addonConfig: JSONObject,
  workflowInput: JSONObject,
  workflowId: String,
  currentDirectory: URL,
  defaultStoreId: String,
  addonName: String
) throws -> DigestStateStorage {
  let backend = nonEmptyString(addonConfig["stateBackend"])
    ?? nonEmptyString(workflowInput["stateBackend"])
    ?? "file"
  switch backend {
  case "file":
    return .file
  case "kv":
    let configuredRoot = nonEmptyString(addonConfig["kvRoot"]) ?? nonEmptyString(workflowInput["kvRoot"])
    let kvRoot = configuredRoot.map {
      URL(fileURLWithPath: $0, relativeTo: currentDirectory).standardizedFileURL.path
    } ?? RielaKeyValueStore.defaultRootDirectory(workingDirectory: currentDirectory.path)
    return .keyValue(DigestKeyValueStateStore(
      store: RielaKeyValueStore(rootDirectory: kvRoot),
      storeId: nonEmptyString(addonConfig["stateStoreId"]) ?? nonEmptyString(workflowInput["stateStoreId"]) ?? defaultStoreId,
      stateKey: nonEmptyString(addonConfig["stateKey"]) ?? nonEmptyString(workflowInput["stateKey"]) ?? "digest-state",
      scope: nonEmptyString(addonConfig["stateScope"]) ?? nonEmptyString(workflowInput["stateScope"]) ?? workflowId,
      addonName: addonName
    ))
  default:
    throw AdapterExecutionError(.policyBlocked, "\(addonName) stateBackend must be \"file\" or \"kv\", got '\(backend)'")
  }
}
