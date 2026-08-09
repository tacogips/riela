import Foundation
import RielaCore
import RielaMemory

enum BuiltinMemoryAddon: String {
  case save = "riela/memory-save"
  case update = "riela/memory-update"
  case load = "riela/memory-load"
  case search = "riela/memory-search"
}

func optionalNodeScope(config: JSONObject, variables: JSONObject) -> String? {
  if boolValue(config["workflowScopeOnly"]) == true || boolValue(variables["workflowScopeOnly"]) == true {
    return nil
  }
  return nonEmptyString(config["nodeScope"]) ?? nonEmptyString(variables["nodeScope"])
}

func memoryPayload(
  config: JSONObject,
  variables: JSONObject,
  input: WorkflowAddonExecutionInput
) throws -> MemoryJSONValue {
  if let payloadTemplate = config["payloadTemplate"] ?? variables["payloadTemplate"] {
    let rendered = renderJSONTemplates(payloadTemplate, variables: variables)
    return try memoryJSONValue(from: rendered)
  }

  if let payload = config["payload"] ?? variables["payload"] {
    return try memoryJSONValue(from: payload)
  }

  let payloadSource = nonEmptyString(config["payloadSource"]) ?? nonEmptyString(variables["payloadSource"]) ?? "input"
  switch payloadSource {
  case "event":
    if let event = variables["event"] {
      return try memoryJSONValue(from: event)
    }
    return .object([:])
  case "variables":
    return try memoryJSONValue(from: .object(variables))
  case "resolvedInput", "input":
    return try memoryJSONValue(from: .object(input.resolvedInputPayload))
  default:
    throw AdapterExecutionError(.policyBlocked, "unsupported memory payloadSource '\(payloadSource)'")
  }
}

func memoryAddonJSONObject(_ value: JSONValue?) -> JSONObject {
  guard case let .object(object)? = value else {
    return [:]
  }
  return object
}

func memoryMatchPatterns(config: JSONObject, variables: JSONObject) -> [String] {
  if let configured = stringArrayValue(config["matchPatterns"]) {
    return configured
  }
  if let variablePatterns = stringArrayValue(variables["matchPatterns"]) {
    return variablePatterns
  }
  if let singlePattern = nonEmptyString(config["match"]) ?? nonEmptyString(variables["match"]) {
    return [singlePattern]
  }
  return []
}

func memoryTags(config: JSONObject, variables: JSONObject) throws -> [String] {
  if let configured = try stringArrayValue(config["tags"], fieldName: "memory tags") {
    return configured
  }
  if let variableTags = try stringArrayValue(variables["tags"], fieldName: "memory tags") {
    return variableTags
  }
  if let singleTag = nonEmptyString(config["tag"]) ?? nonEmptyString(variables["tag"]) {
    return [singleTag]
  }
  return []
}

func memoryRelatedRecordIds(config: JSONObject, variables: JSONObject) throws -> [Int64] {
  if let configured = try int64ArrayValue(config["relatedRecordIds"], fieldName: "memory relatedRecordIds") {
    return configured
  }
  if let variableIds = try int64ArrayValue(variables["relatedRecordIds"], fieldName: "memory relatedRecordIds") {
    return variableIds
  }
  if let singleId = try int64Value(config["relatedRecordId"], fieldName: "memory relatedRecordId")
    ?? int64Value(variables["relatedRecordId"], fieldName: "memory relatedRecordId") {
    return [singleId]
  }
  return []
}

func memoryUpdateFileReferences(config: JSONObject, variables: JSONObject) throws -> [MemoryFileReference]? {
  if boolValue(config["clearFiles"]) == true || boolValue(variables["clearFiles"]) == true {
    return []
  }
  let files = try memoryFileReferences(config: config, variables: variables)
  return files.isEmpty ? nil : files
}

func requiredMemoryRecordId(config: JSONObject, variables: JSONObject) throws -> Int64 {
  if let recordId = try int64Value(config["recordId"], fieldName: "memory recordId")
    ?? int64Value(variables["recordId"], fieldName: "memory recordId") {
    return recordId
  }
  throw AdapterExecutionError(.policyBlocked, "memory recordId is required")
}

func stringArrayValue(_ value: JSONValue?, fieldName: String) throws -> [String]? {
  guard let value else {
    return nil
  }
  guard case let .array(values) = value else {
    throw AdapterExecutionError(.policyBlocked, "\(fieldName) must be an array of non-empty strings")
  }
  return try values.enumerated().map { index, value in
    guard let string = nonEmptyString(value) else {
      throw AdapterExecutionError(.policyBlocked, "\(fieldName)[\(index)] must be a non-empty string")
    }
    return string
  }
}

func stringArrayValue(_ value: JSONValue?) -> [String]? {
  guard case let .array(values) = value else {
    return nil
  }
  return values.compactMap(nonEmptyString)
}

func int64ArrayValue(_ value: JSONValue?, fieldName: String) throws -> [Int64]? {
  guard let value else {
    return nil
  }
  guard case let .array(values) = value else {
    throw AdapterExecutionError(.policyBlocked, "\(fieldName) must be an array of positive integer record ids")
  }
  return try values.enumerated().map { index, value in
    guard let id = try int64Value(value, fieldName: "\(fieldName)[\(index)]") else {
      throw AdapterExecutionError(.policyBlocked, "\(fieldName)[\(index)] must be a positive integer record id")
    }
    return id
  }
}

func int64Value(_ value: JSONValue?, fieldName: String) throws -> Int64? {
  guard let value else {
    return nil
  }
  guard let id = value.asInt64, id > 0 else {
    throw AdapterExecutionError(.policyBlocked, "\(fieldName) must be a positive integer record id")
  }
  return id
}

func memoryAddonOutput(
  input: WorkflowAddonExecutionInput,
  operation: BuiltinMemoryAddon,
  memoryId: String,
  databasePath: String,
  payload extraPayload: JSONObject
) -> AdapterExecutionOutput {
  var payload: JSONObject = [
    "status": .string("ok"),
    "addon": .string(input.addon.name),
    "operation": .string(operation.rawValue.replacingOccurrences(of: "riela/memory-", with: "")),
    "stepId": .string(input.stepId),
    "memoryId": .string(memoryId),
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

func memoryRecordJSON(_ record: MemoryRecord) -> JSONValue {
  .object([
    "recordId": .number(Double(record.recordId)),
    "memoryId": .string(record.memoryId),
    "workflowId": .string(record.workflowId),
    "nodeId": record.nodeId.map { .string($0) } ?? .null,
    "registeredAt": .string(record.registeredAt),
    "tags": .array(record.tags.map { .string($0) }),
    "relatedRecordIds": .array(record.relatedRecordIds.map { .number(Double($0)) }),
    "files": .array(record.files.map(memoryFileJSON)),
    "payload": jsonValue(from: record.payload)
  ])
}

func memoryFileJSON(_ file: MemoryFileReference) -> JSONValue {
  .object([
    "path": .string(file.path),
    "mediaType": file.mediaType.map { .string($0) } ?? .null,
    "kind": file.kind.map { .string($0) } ?? .null,
    "name": file.name.map { .string($0) } ?? .null,
    "sizeBytes": file.sizeBytes.map { .number(Double($0)) } ?? .null
  ])
}

func memoryRecordsPayload(records: [MemoryRecord]) -> JSONObject {
  let files = records.flatMap(\.files)
  return [
    "files": .array(files.map(memoryFileJSON)),
    "filePaths": .array(files.map(\.path).map(JSONValue.string)),
    "imagePaths": .array(memoryFilePaths(files, kind: "image", mediaPrefix: "image/").map(JSONValue.string)),
    "audioPaths": .array(memoryFilePaths(files, kind: "audio", mediaPrefix: "audio/").map(JSONValue.string)),
    "videoPaths": .array(memoryFilePaths(files, kind: "video", mediaPrefix: "video/").map(JSONValue.string)),
    "pdfPaths": .array(memoryFilePaths(files, kind: "pdf", mediaType: "application/pdf").map(JSONValue.string)),
    "memoryAttachmentCountRead": .number(Double(files.count))
  ]
}

func memoryFilePaths(
  _ files: [MemoryFileReference],
  kind: String,
  mediaPrefix: String? = nil,
  mediaType: String? = nil
) -> [String] {
  files.filter { file in
    if file.kind == kind {
      return true
    }
    if let mediaPrefix, file.mediaType?.hasPrefix(mediaPrefix) == true {
      return true
    }
    if let mediaType, file.mediaType == mediaType {
      return true
    }
    return false
  }.map(\.path)
}

func memoryRecordsText(_ records: [MemoryRecord]) -> String {
  records
    .map { record in
      let text = memoryPayloadText(record.payload, depth: 0).truncatedForMemoryPrompt()
      let fileText = memoryFilesText(record.files)
      let prefix = "#\(record.recordId) \(record.registeredAt)"
      if let nodeId = record.nodeId, !nodeId.isEmpty {
        return "\(prefix) [\(nodeId)] \(text)\(fileText)"
      }
      return "\(prefix) \(text)\(fileText)"
    }
    .joined(separator: "\n")
}

func memoryFilesText(_ files: [MemoryFileReference]) -> String {
  guard !files.isEmpty else {
    return ""
  }
  let rendered = files.prefix(10).map { file in
    [
      file.kind,
      file.mediaType,
      file.name,
      file.path
    ].compactMap { $0 }.joined(separator: " ")
  }.joined(separator: "; ")
  return " files: \(rendered)"
}

func memoryPayloadText(_ value: MemoryJSONValue, depth: Int) -> String {
  if depth >= 4 {
    return compactMemoryJSON(value, maxLength: 300)
  }
  switch value {
  case .null:
    return "null"
  case let .bool(value):
    return value ? "true" : "false"
  case let .number(value):
    return String(value)
  case let .string(value):
    return value
  case let .array(values):
    return values.prefix(5).map { memoryPayloadText($0, depth: depth + 1) }.joined(separator: "; ")
  case let .object(object):
    for path in preferredMemorySummaryPaths {
      if let value = memoryValue(at: path, in: object) {
        let text = memoryPayloadText(value, depth: depth + 1)
        if !text.isEmpty {
          return text
        }
      }
    }
    return compactMemoryJSON(.object(object), maxLength: 500)
  }
}

let preferredMemorySummaryPaths: [[String]] = [
  ["text"],
  ["replyText"],
  ["message"],
  ["input", "text"],
  ["payload", "text"],
  ["payload", "replyText"],
  ["payload", "event", "input", "text"],
  ["event", "input", "text"]
]

func memoryValue(at path: [String], in object: [String: MemoryJSONValue]) -> MemoryJSONValue? {
  guard let first = path.first, let value = object[first] else {
    return nil
  }
  if path.count == 1 {
    return value
  }
  guard case let .object(nested) = value else {
    return nil
  }
  return memoryValue(at: Array(path.dropFirst()), in: nested)
}

func compactMemoryJSON(_ value: MemoryJSONValue, maxLength: Int) -> String {
  jsonValue(from: value).compactJSONStringOrEmpty().truncatedForMemoryPrompt(maxLength)
}

func memoryJSONValue(from value: JSONValue) throws -> MemoryJSONValue {
  switch value {
  case .null:
    return .null
  case let .bool(value):
    return .bool(value)
  case let .integer(value):
    return .number(Double(value))
  case let .number(value):
    return .number(value)
  case let .string(value):
    return .string(value)
  case let .array(values):
    return .array(try values.map(memoryJSONValue))
  case let .object(values):
    return .object(try values.mapValues(memoryJSONValue))
  }
}

func jsonValue(from value: MemoryJSONValue) -> JSONValue {
  switch value {
  case .null:
    return .null
  case let .bool(value):
    return .bool(value)
  case let .number(value):
    return .number(value)
  case let .string(value):
    return .string(value)
  case let .array(values):
    return .array(values.map(jsonValue))
  case let .object(values):
    return .object(values.mapValues(jsonValue))
  }
}

extension String {
  func truncatedForMemoryPrompt(_ maxLength: Int = 500) -> String {
    guard count > maxLength else {
      return self
    }
    let endIndex = index(startIndex, offsetBy: maxLength)
    return String(self[..<endIndex]) + "..."
  }
}

/// Config values addressing the store itself are workflow-authored templates
/// (`"memoryRoot": "{{memoryRoot}}"`), so they must render before they are used
/// as paths; an unrendered template would create a literal `{{memoryRoot}}`
/// directory under the working directory.
func memoryConfigString(_ key: String, config: JSONObject, variables: JSONObject) -> String? {
  guard let template = nonEmptyString(config[key]) else {
    return nil
  }
  let rendered = renderPromptTemplate(template, variables: variables)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  return rendered.isEmpty ? nil : rendered
}

extension BuiltinWorkflowAddonResolver {
  func executeMemoryAddon(
    _ input: WorkflowAddonExecutionInput,
    operation: BuiltinMemoryAddon
  ) throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(.policyBlocked, "unsupported \(input.addon.name) version '\(input.addon.version ?? "")'")
    }

    let config = input.addon.config ?? [:]
    let variables = addonVariables(for: input)
    let memoryId = memoryConfigString("memoryId", config: config, variables: variables)
      ?? nonEmptyString(variables["memoryId"]) ?? "chat-memory"
    let nodeId = memoryConfigString("nodeId", config: config, variables: variables)
      ?? nonEmptyString(variables["memoryNodeId"]) ?? input.nodeId
    let limit = intValue(config["limit"]) ?? intValue(variables["limit"]) ?? 30
    let workflowInput = memoryAddonJSONObject(variables["workflowInput"])
    let memoryRoot = memoryConfigString("memoryRoot", config: config, variables: variables)
      ?? nonEmptyString(variables["memoryRoot"])
      ?? nonEmptyString(workflowInput["memoryRoot"])
    let store = RielaMemoryStore(
      rootDirectory: memoryRoot ?? RielaMemoryStore.defaultRootDirectory()
    )

    switch operation {
    case .save:
      let payload = try memoryPayload(config: config, variables: variables, input: input)
      let tags = try memoryTags(config: config, variables: variables)
      let relatedRecordIds = try memoryRelatedRecordIds(config: config, variables: variables)
      let files = try memoryFileReferences(config: config, variables: variables)
      let record = try store.save(
        memoryId: memoryId,
        workflowId: input.workflowId,
        nodeId: nodeId,
        tags: tags,
        relatedRecordIds: relatedRecordIds,
        files: files,
        payload: payload
      )
      return memoryAddonOutput(
        input: input,
        operation: operation,
        memoryId: memoryId,
        databasePath: try store.databasePath(memoryId: memoryId),
        payload: [
          "saved": .bool(true),
          "record": memoryRecordJSON(record)
        ]
      )
    case .update:
      let recordId = try requiredMemoryRecordId(config: config, variables: variables)
      let payload = try memoryPayload(config: config, variables: variables, input: input)
      let tags = try memoryTags(config: config, variables: variables)
      let relatedRecordIds = try memoryRelatedRecordIds(config: config, variables: variables)
      let files = try memoryUpdateFileReferences(config: config, variables: variables)
      let record = try store.update(
        memoryId: memoryId,
        recordId: recordId,
        workflowId: input.workflowId,
        nodeId: optionalNodeScope(config: config, variables: variables),
        tags: tags,
        relatedRecordIds: relatedRecordIds,
        files: files,
        payload: payload
      )
      return memoryAddonOutput(
        input: input,
        operation: operation,
        memoryId: memoryId,
        databasePath: try store.databasePath(memoryId: memoryId),
        payload: [
          "updated": .bool(true),
          "record": memoryRecordJSON(record)
        ]
      )
    case .load:
      let records = try store.load(
        memoryId: memoryId,
        workflowId: input.workflowId,
        nodeId: optionalNodeScope(config: config, variables: variables),
        limit: limit
      )
      return memoryAddonOutput(
        input: input,
        operation: operation,
        memoryId: memoryId,
        databasePath: try store.databasePath(memoryId: memoryId),
        payload: memoryRecordsPayload(records: records).merging([
          "records": .array(records.map(memoryRecordJSON)),
          "recordsText": .string(memoryRecordsText(records)),
          "limit": .number(Double(limit))
        ]) { _, new in new }
      )
    case .search:
      let patterns = memoryMatchPatterns(config: config, variables: variables)
      let tags = try memoryTags(config: config, variables: variables)
      let relatedRecordIds = try memoryRelatedRecordIds(config: config, variables: variables)
      let records = try store.search(
        memoryId: memoryId,
        options: MemorySearchOptions(
          workflowId: input.workflowId,
          nodeId: optionalNodeScope(config: config, variables: variables),
          matchPatterns: patterns,
          tags: tags,
          relatedRecordIds: relatedRecordIds,
          limit: limit
        )
      )
      return memoryAddonOutput(
        input: input,
        operation: operation,
        memoryId: memoryId,
        databasePath: try store.databasePath(memoryId: memoryId),
        payload: memoryRecordsPayload(records: records).merging([
          "records": .array(records.map(memoryRecordJSON)),
          "recordsText": .string(memoryRecordsText(records)),
          "matchPatterns": .array(patterns.map { .string($0) }),
          "tags": .array(tags.map { .string($0) }),
          "relatedRecordIds": .array(relatedRecordIds.map { .number(Double($0)) }),
          "limit": .number(Double(limit))
        ]) { _, new in new }
      )
    }
  }
}
