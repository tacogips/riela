import Foundation
import RielaCore
import AppCore

private let noteMemoryMaximumAttachmentsRead = 64
private let noteMemoryMaximumAttachmentsWrite = 64
private let noteMemoryReservedTagPrefixes = [
  "persona:",
  "system-memory-stream:",
  "system-memory-workflow:",
  "system-memory-node:"
]

func saveNoteMemory(_ context: NoteAddonContext) throws -> JSONObject {
  let streamId = try noteMemoryStreamId(context)
  let nodeId = context.string("nodeId", "memoryNodeId") ?? context.input.nodeId
  let payload = try noteMemoryPayload(context)
  let attachments = try noteMemoryAttachments(context)
  var tags = [
    NoteTagInput(name: NoteService.systemMemoryStreamTag(streamId)),
    NoteTagInput(name: NoteService.systemMemoryWorkflowTag(context.input.workflowId)),
    NoteTagInput(name: NoteService.systemMemoryNodeTag(nodeId))
  ]
  tags.append(contentsOf: try noteMemoryUserTags(context).map { NoteTagInput(name: $0) })
  let meta: JSONValue = .object([
    "systemMemoryVersion": .number(1),
    "entryKind": .string("workflow-memory"),
    "streamId": .string(streamId),
    "workflowId": .string(context.input.workflowId),
    "nodeId": .string(nodeId),
    "payload": payload
  ])
  let note = try context.service.appendSystemMemoryNote(
    bodyMarkdown: noteMemorySummary(payload),
    tags: tags,
    metaJSON: meta.compactJSONStringOrEmpty(),
    attachments: attachments
  )
  return [
    "saved": .bool(true),
    "streamId": .string(streamId),
    "notebookId": .string(note.notebookId),
    "noteId": .string(note.noteId),
    "record": try noteMemoryRecordJSON(note, context: context)
  ]
}

func loadNoteMemory(_ context: NoteAddonContext) throws -> JSONObject {
  let streamId = try noteMemoryStreamId(context)
  let requestedLimit = context.int("limit", default: 30)
  let limit = max(1, min(requestedLimit, 100))
  let nodeId = context.bool("workflowScopeOnly", default: true)
    ? nil
    : context.string("nodeScope")
  let notes = try context.service.listSystemMemoryNotes(
    streamId: streamId,
    workflowId: context.input.workflowId,
    nodeId: nodeId,
    limit: limit
  )
  let records = try notes.map { try noteMemoryRecord($0, context: context) }
  let files = Array(records.flatMap(\.files).prefix(noteMemoryMaximumAttachmentsRead))
  return [
    "streamId": .string(streamId),
    "notebookId": .string(try context.service.systemMemoryNotebook().notebookId),
    "records": .array(records.map(\.json)),
    "recordsText": .string(records.map(\.text).joined(separator: "\n")),
    "files": .array(files.map(\.json)),
    "filePaths": .array(files.map(\.path).map(JSONValue.string)),
    "imagePaths": .array(files.filter { $0.mediaType.hasPrefix("image/") }.map(\.path).map(JSONValue.string)),
    "audioPaths": .array(files.filter { $0.mediaType.hasPrefix("audio/") }.map(\.path).map(JSONValue.string)),
    "videoPaths": .array(files.filter { $0.mediaType.hasPrefix("video/") }.map(\.path).map(JSONValue.string)),
    "pdfPaths": .array(files.filter { $0.mediaType == "application/pdf" }.map(\.path).map(JSONValue.string)),
    "memoryAttachmentCountRead": .number(Double(files.count)),
    "limit": .number(Double(limit))
  ]
}

private struct NoteMemoryLoadedFile {
  var path: String
  var mediaType: String
  var name: String?
  var sizeBytes: Int64

  var json: JSONValue {
    .object([
      "path": .string(path),
      "mediaType": .string(mediaType),
      "kind": .string(noteMemoryFileKind(mediaType)),
      "name": name.map(JSONValue.string) ?? .null,
      "sizeBytes": .number(Double(sizeBytes))
    ])
  }
}

private struct NoteMemoryLoadedRecord {
  var json: JSONValue
  var text: String
  var files: [NoteMemoryLoadedFile]
}

private func noteMemoryRecord(_ note: Note, context: NoteAddonContext) throws -> NoteMemoryLoadedRecord {
  let metadata = try noteMemoryMetadata(note)
  let nodeId = nonEmptyString(metadata["nodeId"])
  let fileStore = LocalNoteFileStore(noteRoot: context.noteRoot)
  let files = try context.service.listFiles(noteId: note.noteId).compactMap { attachment -> NoteMemoryLoadedFile? in
    guard attachment.file.storageKind == .local else { return nil }
    return NoteMemoryLoadedFile(
      path: try fileStore.fileURL(record: attachment.file).path,
      mediaType: attachment.file.mediaType,
      name: attachment.file.originalFilename,
      sizeBytes: attachment.file.byteSize
    )
  }
  let fileText = files.isEmpty ? "" : " files: " + files.prefix(10).map { file in
    [noteMemoryFileKind(file.mediaType), file.mediaType, file.name, file.path]
      .compactMap { $0 }
      .joined(separator: " ")
  }.joined(separator: "; ")
  let prefix = "#\(note.noteId) \(note.createdAt)"
  let nodeText = nodeId.map { " [\($0)]" } ?? ""
  return NoteMemoryLoadedRecord(
    json: try noteMemoryRecordJSON(note, context: context),
    text: "\(prefix)\(nodeText) \(note.bodyMarkdown)\(fileText)",
    files: files
  )
}

private func noteMemoryRecordJSON(_ note: Note, context: NoteAddonContext) throws -> JSONValue {
  let metadata = try noteMemoryMetadata(note)
  let fileStore = LocalNoteFileStore(noteRoot: context.noteRoot)
  let files = try context.service.listFiles(noteId: note.noteId).compactMap { attachment -> NoteMemoryLoadedFile? in
    guard attachment.file.storageKind == .local else { return nil }
    return NoteMemoryLoadedFile(
      path: try fileStore.fileURL(record: attachment.file).path,
      mediaType: attachment.file.mediaType,
      name: attachment.file.originalFilename,
      sizeBytes: attachment.file.byteSize
    )
  }
  let tags = note.tags.map(\.tag.name).filter { name in
    !noteMemoryReservedTagPrefixes.contains { name.hasPrefix($0) }
  }
  return .object([
    "noteId": .string(note.noteId),
    "streamId": metadata["streamId"] ?? .null,
    "workflowId": metadata["workflowId"] ?? .null,
    "nodeId": metadata["nodeId"] ?? .null,
    "registeredAt": .string(note.createdAt),
    "tags": .array(tags.map(JSONValue.string)),
    "files": .array(files.map(\.json)),
    "payload": metadata["payload"] ?? .string(note.bodyMarkdown)
  ])
}

private func noteMemoryMetadata(_ note: Note) throws -> JSONObject {
  guard let metaJSON = note.metaJSON,
        let data = metaJSON.data(using: .utf8),
        case let .object(metadata) = try JSONDecoder().decode(JSONValue.self, from: data),
        metadata["entryKind"] == .string("workflow-memory") else {
    throw noteAddonInvalidInput("system-memory note \(note.noteId) has invalid workflow-memory metadata")
  }
  return metadata
}

private func noteMemoryStreamId(_ context: NoteAddonContext) throws -> String {
  let streamId = try context.requiredString("streamId", "memoryId", fieldName: "streamId")
  guard streamId.count <= 128 else {
    throw noteAddonInvalidInput("\(context.input.addon.name) streamId exceeds 128 characters")
  }
  return streamId
}

private func noteMemoryPayload(_ context: NoteAddonContext) throws -> JSONValue {
  if let template = context.value("payloadTemplate") {
    return renderJSONTemplates(template, variables: context.variables)
  }
  if let payload = context.value("payload") {
    return payload
  }
  let source = context.string("payloadSource") ?? "input"
  switch source {
  case "event":
    return context.variables["event"] ?? .object([:])
  case "variables":
    return .object(context.variables)
  case "resolvedInput", "input":
    return .object(context.input.resolvedInputPayload)
  default:
    throw noteAddonInvalidInput("unsupported note-memory payloadSource '\(source)'")
  }
}

private func noteMemorySummary(_ value: JSONValue, depth: Int = 0) -> String {
  if depth >= 4 {
    return noteMemoryTruncated(value.compactJSONStringOrEmpty(), limit: 300)
  }
  switch value {
  case .null:
    return "null"
  case let .bool(value):
    return value ? "true" : "false"
  case let .integer(value):
    return String(value)
  case let .number(value):
    return String(value)
  case let .string(value):
    return noteMemoryTruncated(value, limit: 500)
  case let .array(values):
    return values.prefix(5).map { noteMemorySummary($0, depth: depth + 1) }.joined(separator: "; ")
  case let .object(object):
    for path in noteMemoryPreferredSummaryPaths {
      if let child = noteMemoryValue(at: path, in: object) {
        let summary = noteMemorySummary(child, depth: depth + 1)
        if !summary.isEmpty { return summary }
      }
    }
    return noteMemoryTruncated(value.compactJSONStringOrEmpty(), limit: 500)
  }
}

private let noteMemoryPreferredSummaryPaths = [
  ["text"], ["replyText"], ["message"], ["input", "text"],
  ["payload", "text"], ["payload", "replyText"],
  ["payload", "event", "input", "text"], ["event", "input", "text"]
]

private func noteMemoryValue(at path: [String], in object: JSONObject) -> JSONValue? {
  guard let first = path.first, let value = object[first] else { return nil }
  if path.count == 1 { return value }
  guard case let .object(nested) = value else { return nil }
  return noteMemoryValue(at: Array(path.dropFirst()), in: nested)
}

private func noteMemoryTruncated(_ value: String, limit: Int) -> String {
  guard value.count > limit else { return value }
  return String(value.prefix(limit)) + "..."
}

private func noteMemoryUserTags(_ context: NoteAddonContext) throws -> [String] {
  guard let value = context.value("tags") else { return [] }
  switch value {
  case let .string(tag):
    guard !tag.isEmpty else { return [] }
    return [try noteMemoryValidatedUserTag(tag, field: "tags")]
  case let .array(values):
    return try values.enumerated().map { index, value in
      guard let tag = nonEmptyString(value) else {
        throw noteAddonInvalidInput("note-memory tags[\(index)] must be a non-empty string")
      }
      return try noteMemoryValidatedUserTag(tag, field: "tags[\(index)]")
    }
  case .null:
    return []
  case .bool, .integer, .number, .object:
    throw noteAddonInvalidInput("note-memory tags must be a string or array of strings")
  }
}

private func noteMemoryValidatedUserTag(_ tag: String, field: String) throws -> String {
  if let reservedPrefix = noteMemoryReservedTagPrefixes.first(where: { tag.hasPrefix($0) }) {
    throw noteAddonInvalidInput("note-memory \(field) uses reserved prefix '\(reservedPrefix)'")
  }
  return tag
}

private func noteMemoryAttachments(_ context: NoteAddonContext) throws -> [SystemMemoryAttachmentInput] {
  var refs: [String] = []
  let workflowInput = noteMemoryObject(context.variables["workflowInput"])
  let event = noteMemoryObject(context.variables["event"])
  let eventInput = noteMemoryObject(event["input"])
  let eventPayload = noteMemoryObject(eventInput["payload"])
  let directInput = noteMemoryObject(context.variables["input"])
  let candidates = [
    context.value("attachments"), context.value("files"),
    workflowInput["attachments"], workflowInput["files"],
    eventInput["attachments"], eventInput["files"],
    eventPayload["attachments"], eventPayload["files"],
    directInput["attachments"], directInput["files"],
    context.value("imagePaths"), workflowInput["imagePaths"],
    eventInput["imagePaths"], eventPayload["imagePaths"], directInput["imagePaths"]
  ]
  for candidate in candidates {
    refs.append(contentsOf: try noteMemoryAttachmentReferences(candidate))
  }
  refs.append(contentsOf: context.input.attachments.keys.sorted())
  var seen: Set<String> = []
  let uniqueRefs = refs.filter { seen.insert($0).inserted }
  guard uniqueRefs.count <= noteMemoryMaximumAttachmentsWrite else {
    throw noteAddonInvalidInput(
      "note-memory attachments exceed maximum of \(noteMemoryMaximumAttachmentsWrite)"
    )
  }
  return try uniqueRefs.enumerated().map { position, ref in
    guard let source = try sourceAttachmentInput(ref: ref, context: context) else {
      throw noteAddonInvalidInput(
        "\(context.input.addon.name) attachment cannot be resolved: \(ref)"
      )
    }
    switch source {
    case let .inline(value):
      return SystemMemoryAttachmentInput(
        source: .data(value.data),
        mediaType: value.mediaType,
        originalFilename: value.filename,
        position: position
      )
    case let .localFile(url, mediaType, filename):
      return SystemMemoryAttachmentInput(
        source: .data(try boundedLocalFileData(url: url, context: context)),
        mediaType: mediaType,
        originalFilename: filename,
        position: position
      )
    }
  }
}

private func noteMemoryAttachmentReferences(_ value: JSONValue?) throws -> [String] {
  guard let value else { return [] }
  guard case let .array(values) = value else {
    throw noteAddonInvalidInput("note-memory attachments must be an array")
  }
  return try values.enumerated().compactMap { index, value in
    if let string = nonEmptyString(value) { return string }
    if case let .object(object) = value {
      guard let reference = nonEmptyString(object["path"])
        ?? nonEmptyString(object["localPath"])
        ?? nonEmptyString(object["imagePath"])
        ?? nonEmptyString(object["downloadPath"])
        ?? nonEmptyString(object["id"]) else {
        throw noteAddonInvalidInput(
          "note-memory attachments[\(index)] does not contain a supported reference"
        )
      }
      return reference
    }
    if case .null = value { return nil }
    throw noteAddonInvalidInput("note-memory attachments[\(index)] must be a string or object")
  }
}

private func noteMemoryObject(_ value: JSONValue?) -> JSONObject {
  guard case let .object(object)? = value else { return [:] }
  return object
}

private func noteMemoryFileKind(_ mediaType: String) -> String {
  if mediaType.hasPrefix("image/") { return "image" }
  if mediaType.hasPrefix("audio/") { return "audio" }
  if mediaType.hasPrefix("video/") { return "video" }
  if mediaType == "application/pdf" { return "pdf" }
  return "file"
}
