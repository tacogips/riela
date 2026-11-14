import Foundation
import RielaCore
import RielaMemory

extension BuiltinWorkflowAddonResolver {
  func executeChatMemoryRawDailySummary(_ input: WorkflowAddonExecutionInput) throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(.policyBlocked, "unsupported \(input.addon.name) version '\(input.addon.version ?? "")'")
    }
    let config = input.addon.config ?? [:]
    let variables = addonVariables(for: input)
    let workflowInput = jsonObject(variables["workflowInput"])
    let rawMemoryId = nonEmptyString(config["rawMemoryId"]) ?? "raw-chat-log"
    let summaryMemoryId = nonEmptyString(config["summaryMemoryId"]) ?? "daily-chat-summary"
    let memoryRoot = nonEmptyString(config["memoryRoot"])
      ?? nonEmptyString(variables["memoryRoot"])
      ?? nonEmptyString(workflowInput["memoryRoot"])
    let store = RielaMemoryStore(rootDirectory: memoryRoot ?? RielaMemoryStore.defaultRootDirectory())
    let event = chatMemoryEvent(config: config, variables: variables)
    let conversationTag = "conversation:\(safeMemoryTagSegment(event.conversationId, fallback: "default"))"
    let dateTag = "date:\(event.date)"
    let providerTag = "provider:\(safeMemoryTagSegment(event.provider, fallback: "chat"))"
    let summaryKey = [
      "summary",
      safeMemoryTagSegment(event.provider, fallback: "chat"),
      safeMemoryTagSegment(event.conversationId, fallback: "default"),
      event.date
    ].joined(separator: ":")
    let rawRecord = try store.save(
      memoryId: rawMemoryId,
      workflowId: input.workflowId,
      nodeId: nonEmptyString(config["rawNodeId"]) ?? "raw-log-writer",
      registeredAt: event.receivedAt,
      tags: rawMemoryTags(providerTag: providerTag, conversationTag: conversationTag, dateTag: dateTag, files: event.files),
      files: event.files,
      payload: event.memoryPayload
    )
    let existingSummaries = try store.search(
      memoryId: summaryMemoryId,
      options: MemorySearchOptions(workflowId: input.workflowId, tags: [summaryKey], limit: 1)
    )
    let existingSummary = existingSummaries.first
    let summaryPayload = chatDailySummaryPayload(
      existingPayload: existingSummary?.payload,
      event: event,
      rawMemoryId: rawMemoryId,
      rawRecordId: rawRecord.recordId
    )
    let summaryTags = ["daily-summary", summaryKey, conversationTag, dateTag]
    let summaryRecord: MemoryRecord
    let summaryAction: String
    if let existingSummary {
      summaryRecord = try store.update(
        memoryId: summaryMemoryId,
        recordId: existingSummary.recordId,
        workflowId: input.workflowId,
        tags: summaryTags,
        payload: summaryPayload
      )
      summaryAction = "updated"
    } else {
      summaryRecord = try store.save(
        memoryId: summaryMemoryId,
        workflowId: input.workflowId,
        nodeId: nonEmptyString(config["summaryNodeId"]) ?? "daily-summary-writer",
        registeredAt: event.receivedAt,
        tags: summaryTags,
        payload: summaryPayload
      )
      summaryAction = "created"
    }
    let rawRecordCount = memoryNumber(memoryObject(summaryPayload)["rawRecordCount"]) ?? 1
    return AdapterExecutionOutput(
      provider: "riela-builtin-addon",
      model: input.addon.name,
      promptText: "",
      completionPassed: true,
      payload: [
        "status": .string("ok"),
        "addon": .string(input.addon.name),
        "stepId": .string(input.stepId),
        "rawMemoryId": .string(rawMemoryId),
        "summaryMemoryId": .string(summaryMemoryId),
        "rawRecordId": .number(Double(rawRecord.recordId)),
        "summaryRecordId": .number(Double(summaryRecord.recordId)),
        "summaryAction": .string(summaryAction),
        "rawRecordCount": .number(Double(rawRecordCount)),
        "rawFileCount": .number(Double(event.files.count)),
        "memoryRoot": .string(store.rootDirectory),
        "date": .string(event.date),
        "conversationId": .string(event.conversationId)
      ]
    )
  }
}

private struct ChatMemoryEvent {
  var provider: String
  var conversationId: String
  var threadId: String
  var actorId: String
  var actorDisplayName: String
  var eventId: String
  var text: String
  var receivedAt: String
  var date: String
  var files: [MemoryFileReference]

  var memoryPayload: MemoryJSONValue {
    .object([
      "provider": .string(provider),
      "conversationId": .string(conversationId),
      "threadId": .string(threadId),
      "actorId": .string(actorId),
      "actorDisplayName": .string(actorDisplayName),
      "eventId": .string(eventId),
      "text": .string(text),
      "files": .array(files.map(chatMemoryFilePayload)),
      "receivedAt": .string(receivedAt),
      "date": .string(date)
    ])
  }
}

private func chatMemoryEvent(config: JSONObject, variables: JSONObject) -> ChatMemoryEvent {
  let workflowInput = jsonObject(variables["workflowInput"])
  let event = jsonObject(variables["event"])
  let eventInput = jsonObject(event["input"])
  let directInput = jsonObject(variables["input"])
  let payload = jsonObject(eventInput["payload"])
  let conversation = jsonObject(event["conversation"])
  let actor = jsonObject(event["actor"])
  let provider = nonEmptyString(config["provider"])
    ?? nonEmptyString(workflowInput["provider"])
    ?? nonEmptyString(event["provider"])
    ?? nonEmptyString(eventInput["provider"])
    ?? "chat"
  let receivedAt = nonEmptyString(config["receivedAt"])
    ?? nonEmptyString(workflowInput["receivedAt"])
    ?? nonEmptyString(event["receivedAt"])
    ?? nonEmptyString(event["timestamp"])
    ?? currentISO8601Timestamp()
  let text = nonEmptyString(config["text"])
    ?? nonEmptyString(workflowInput["text"])
    ?? nonEmptyString(eventInput["text"])
    ?? nonEmptyString(directInput["text"])
    ?? ""
  let conversationId = nonEmptyString(config["conversationId"])
    ?? nonEmptyString(workflowInput["conversationId"])
    ?? nonEmptyString(conversation["id"])
    ?? nonEmptyString(directInput["conversationId"])
    ?? "default"
  return ChatMemoryEvent(
    provider: provider,
    conversationId: conversationId,
    threadId: nonEmptyString(config["threadId"]) ?? nonEmptyString(conversation["threadId"]) ?? "",
    actorId: nonEmptyString(config["actorId"]) ?? nonEmptyString(actor["id"]) ?? "",
    actorDisplayName: nonEmptyString(config["actorDisplayName"]) ?? nonEmptyString(actor["displayName"]) ?? "",
    eventId: nonEmptyString(config["eventId"])
      ?? nonEmptyString(workflowInput["eventId"])
      ?? nonEmptyString(event["eventId"])
      ?? "\(provider)-\(receivedAt)",
    text: text,
    receivedAt: receivedAt,
    date: datePrefix(receivedAt),
    files: chatMemoryFiles(config: config, workflowInput: workflowInput, eventInput: eventInput, payload: payload, directInput: directInput)
  )
}

private func chatDailySummaryPayload(
  existingPayload: MemoryJSONValue?,
  event: ChatMemoryEvent,
  rawMemoryId: String,
  rawRecordId: Int64
) -> MemoryJSONValue {
  let existingObject = memoryObject(existingPayload)
  let previousRawRecordCount = memoryNumber(existingObject["rawRecordCount"]) ?? memoryInt64Array(existingObject["rawLogRecordIds"]).count
  let rawRecordIds = memoryInt64Array(existingObject["rawLogRecordIds"]) + [rawRecordId]
  let previousRawFileCount = memoryNumber(existingObject["rawFileCount"]) ?? 0
  let previousSummary = memoryString(existingObject["summary"]) ?? ""
  let actor = event.actorDisplayName.isEmpty ? (event.actorId.isEmpty ? "user" : event.actorId) : event.actorDisplayName
  let fileSuffix = event.files.isEmpty ? "" : " [files: \(event.files.map(\.path).joined(separator: ", "))]"
  let nextLine = "\(event.receivedAt) \(actor): \(event.text)\(fileSuffix)"
  let summary = previousSummary.isEmpty ? nextLine : "\(previousSummary)\n\(nextLine)"
  return .object([
    "date": .string(event.date),
    "conversationId": .string(event.conversationId),
    "provider": .string(event.provider),
    "summary": .string(summary),
    "rawRecordCount": .number(Double(previousRawRecordCount + 1)),
    "rawLogMemoryId": .string(rawMemoryId),
    "rawLogRecordIds": .array(rawRecordIds.suffix(10).map { .number(Double($0)) }),
    "lastRawRecordId": .number(Double(rawRecordId)),
    "rawFileCount": .number(Double(previousRawFileCount + event.files.count)),
    "lastRawFilePaths": .array(event.files.map { .string($0.path) }),
    "updatedAt": .string(currentISO8601Timestamp())
  ])
}

private func rawMemoryTags(
  providerTag: String,
  conversationTag: String,
  dateTag: String,
  files: [MemoryFileReference]
) -> [String] {
  var tags = ["raw-log", providerTag, conversationTag, dateTag]
  if !files.isEmpty {
    tags.append("has-files")
  }
  for kind in Array(Set(files.compactMap(\.kind))).sorted().prefix(5) {
    tags.append("file-kind:\(safeMemoryTagSegment(kind, fallback: "file"))")
  }
  return Array(tags.prefix(10))
}

private func chatMemoryFilePayload(_ file: MemoryFileReference) -> MemoryJSONValue {
  .object([
    "path": .string(file.path),
    "mediaType": file.mediaType.map { .string($0) } ?? .null,
    "kind": file.kind.map { .string($0) } ?? .null,
    "name": file.name.map { .string($0) } ?? .null,
    "sizeBytes": file.sizeBytes.map { .number(Double($0)) } ?? .null
  ])
}

private func chatMemoryFiles(
  config: JSONObject,
  workflowInput: JSONObject,
  eventInput: JSONObject,
  payload: JSONObject,
  directInput: JSONObject
) -> [MemoryFileReference] {
  let descriptorSources = [
    config["files"],
    workflowInput["files"],
    eventInput["files"],
    payload["files"],
    config["attachments"],
    workflowInput["attachments"],
    eventInput["attachments"],
    payload["attachments"],
    directInput["attachments"]
  ]
  for source in descriptorSources {
    let files = chatMemoryFileDescriptors(source)
    if !files.isEmpty {
      return files
    }
  }
  let imagePaths = stringArray(config["imagePaths"])
    + stringArray(workflowInput["imagePaths"])
    + stringArray(eventInput["imagePaths"])
    + stringArray(payload["imagePaths"])
    + stringArray(directInput["imagePaths"])
  return deduplicatedFileReferences(imagePaths.map { MemoryFileReference(path: $0, kind: "image") })
}

private func chatMemoryFileDescriptors(_ value: JSONValue?) -> [MemoryFileReference] {
  guard case let .array(entries)? = value else {
    return []
  }
  return deduplicatedFileReferences(entries.compactMap { entry in
    if case let .string(path) = entry, !path.isEmpty {
      return MemoryFileReference(path: path)
    }
    guard case let .object(object) = entry else {
      return nil
    }
    guard let path = nonEmptyString(object["path"])
      ?? nonEmptyString(object["localPath"])
      ?? nonEmptyString(object["imagePath"])
      ?? nonEmptyString(object["downloadPath"]) else {
      return nil
    }
    return MemoryFileReference(
      path: path,
      mediaType: nonEmptyString(object["mediaType"])
        ?? nonEmptyString(object["contentType"])
        ?? nonEmptyString(object["mimetype"])
        ?? nonEmptyString(object["mimeType"]),
      kind: nonEmptyString(object["kind"]),
      name: nonEmptyString(object["name"]) ?? nonEmptyString(object["fileName"]),
      sizeBytes: int64(object["sizeBytes"]) ?? int64(object["fileSize"])
    )
  })
}

private func deduplicatedFileReferences(_ files: [MemoryFileReference]) -> [MemoryFileReference] {
  var seen: Set<String> = []
  var result: [MemoryFileReference] = []
  for file in files where !file.path.isEmpty && !seen.contains(file.path) {
    seen.insert(file.path)
    result.append(file)
  }
  return Array(result.prefix(10))
}

private func stringArray(_ value: JSONValue?) -> [String] {
  guard case let .array(values)? = value else {
    return []
  }
  return values.compactMap(nonEmptyString)
}

private func int64(_ value: JSONValue?) -> Int64? {
  guard case let .number(number)? = value else {
    return nil
  }
  return Int64(exactly: number)
}

private func jsonObject(_ value: JSONValue?) -> JSONObject {
  guard case let .object(object)? = value else {
    return [:]
  }
  return object
}

private func memoryObject(_ value: MemoryJSONValue?) -> [String: MemoryJSONValue] {
  guard case let .object(object)? = value else {
    return [:]
  }
  return object
}

private func memoryString(_ value: MemoryJSONValue?) -> String? {
  guard case let .string(string)? = value else {
    return nil
  }
  return string
}

private func memoryNumber(_ value: MemoryJSONValue?) -> Int? {
  guard case let .number(number)? = value, number.rounded() == number else {
    return nil
  }
  return Int(number)
}

private func memoryInt64Array(_ value: MemoryJSONValue?) -> [Int64] {
  guard case let .array(values)? = value else {
    return []
  }
  return values.compactMap { value in
    guard case let .number(number) = value else {
      return nil
    }
    return Int64(exactly: number)
  }
}

private func safeMemoryTagSegment(_ value: String, fallback: String) -> String {
  let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-")
  let normalized = value.lowercased().unicodeScalars.map { scalar -> String in
    allowed.contains(scalar) ? String(scalar) : "-"
  }.joined()
  let trimmed = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
  return trimmed.isEmpty ? fallback : trimmed
}

private func datePrefix(_ timestamp: String) -> String {
  let pattern = #"^\d{4}-\d{2}-\d{2}"#
  if let range = timestamp.range(of: pattern, options: .regularExpression) {
    return String(timestamp[range])
  }
  return String(currentISO8601Timestamp().prefix(10))
}

private func currentISO8601Timestamp() -> String {
  ISO8601DateFormatter().string(from: Date())
}
