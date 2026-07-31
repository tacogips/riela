import Foundation
import RielaCore
import RielaNote

func executeNoteMemoryAddon(
  _ input: WorkflowAddonExecutionInput,
  operation: BuiltinNoteAddon,
  environment: [String: String]
) throws -> JSONObject {
  let context = try NoteMemoryAddonContext(input: input, environment: environment)
  switch operation {
  case .memorySave:
    return try saveNoteMemory(context)
  case .memoryUpdate:
    return try updateNoteMemory(context)
  case .memoryLoad:
    return try loadNoteMemory(context)
  case .memorySearch:
    return try searchNoteMemory(context)
  case .personaMemoryRead:
    return try readPersonaNoteMemory(context)
  case .personaMemoryWrite:
    return try writePersonaNoteMemory(context)
  default:
    throw AdapterExecutionError(.providerError, "unsupported Note memory operation")
  }
}

private struct NoteMemoryAddonContext {
  var input: WorkflowAddonExecutionInput
  var config: JSONObject
  var variables: JSONObject
  var service: NoteService

  init(input: WorkflowAddonExecutionInput, environment: [String: String]) throws {
    self.input = input
    config = input.addon.config ?? [:]
    variables = addonVariables(for: input)
    let workflowInput = Self.object(variables["workflowInput"])
    let root = Self.string("noteRoot", in: config)
      ?? Self.string("noteRoot", in: variables)
      ?? Self.string("noteRoot", in: workflowInput)
      ?? environment["RIELA_NOTE_ROOT"]
      ?? "\(NSHomeDirectory())/.riela/note"
    service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: (root as NSString).expandingTildeInPath))
  }

  func value(_ key: String) -> JSONValue? {
    config[key] ?? variables[key]
  }

  func string(_ keys: String...) -> String? {
    for key in keys {
      if let value = Self.string(key, in: config) ?? Self.string(key, in: variables) {
        return value
      }
    }
    return nil
  }

  func requiredString(_ keys: String...) throws -> String {
    for key in keys {
      if let value = string(key) { return value }
    }
    throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) requires \(keys.first ?? "value")")
  }

  func int(_ key: String, default defaultValue: Int) -> Int {
    if case let .integer(value)? = value(key) { return Int(value) }
    if case let .number(value)? = value(key) { return Int(value) }
    return defaultValue
  }

  private static func string(_ key: String, in object: JSONObject) -> String? {
    guard case let .string(value)? = object[key] else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func object(_ value: JSONValue?) -> JSONObject {
    guard case let .object(object)? = value else { return [:] }
    return object
  }
}

private func saveNoteMemory(_ context: NoteMemoryAddonContext) throws -> JSONObject {
  let renderedPayloadTemplate = context.value("payloadTemplate").map {
    renderJSONTemplates($0, variables: context.variables)
  }
  let body = context.string("bodyMarkdown", "body", "text", "content")
    ?? markdown(from: context.value("payload"))
    ?? markdown(from: renderedPayloadTemplate)
  guard let body, !body.isEmpty else {
    throw AdapterExecutionError(.policyBlocked, "\(context.input.addon.name) requires bodyMarkdown or payload")
  }
  let namespace = context.string("memoryNamespace", "memoryId") ?? "system"
  let tags = noteMemoryTags(context.value("tags"), required: ["memory-namespace:\(namespace)"])
  let metadata = metadataJSON(context: context, extra: ["memoryNamespace": .string(namespace)])
  let note = try context.service.saveSystemMemoryNote(
    title: context.string("title"),
    bodyMarkdown: body,
    tags: tags,
    metaJSON: metadata
  )
  let relatedNoteIds = try noteMemoryStringArray(context.value("relatedNoteIds"), field: "relatedNoteIds")
  for relatedNoteId in relatedNoteIds {
    _ = try context.service.linkNotes(from: note.noteId, to: relatedNoteId, provenance: .ai)
  }
  let attachments = try attachNoteMemoryFiles(context: context, noteId: note.noteId)
  var payload = noteMemoryPayload(note: note, operation: "save")
  payload["relatedNoteIds"] = .array(relatedNoteIds.map(JSONValue.string))
  payload["fileIds"] = .array(attachments.map { .string($0.file.fileId) })
  return payload
}

private func updateNoteMemory(_ context: NoteMemoryAddonContext) throws -> JSONObject {
  let note = try context.service.updateSystemMemoryNote(
    noteId: try context.requiredString("noteId"),
    bodyMarkdown: try context.requiredString("bodyMarkdown", "body", "text", "content"),
    metaJSON: metadataJSON(context: context)
  )
  return noteMemoryPayload(note: note, operation: "update")
}

private func loadNoteMemory(_ context: NoteMemoryAddonContext) throws -> JSONObject {
  if let noteId = context.string("noteId") {
    let note = try context.service.getNote(noteId)
    guard note.notebookId == NoteStoreSchema.systemMemoryNotebookId else {
      throw NoteServiceError.invalidInput("memory load target is outside the reserved notebook")
    }
    return noteMemoryPayload(note: note, operation: "load")
  }
  return try memoryNotesPayload(context: context)
}

private func searchNoteMemory(_ context: NoteMemoryAddonContext) throws -> JSONObject {
  try memoryNotesPayload(context: context)
}

private func memoryNotesPayload(context: NoteMemoryAddonContext) throws -> JSONObject {
  let limit = max(1, min(context.int("limit", default: 20), 100))
  let query = context.string("query", "match") ?? ""
  let namespace = context.string("memoryNamespace", "memoryId")
  let notes: [Note]
  if query.isEmpty {
    notes = Array(try context.service.listNotes(
      notebookId: NoteStoreSchema.systemMemoryNotebookId,
      limit: 10_000
    ).reversed()).filter { note in
      guard let namespace else { return true }
      return note.tags.contains { $0.tag.name == "memory-namespace:\(namespace)" }
    }.prefix(limit).map { $0 }
  } else {
    notes = try context.service.searchNotes(query: query, limit: limit * 2)
      .map(\.note)
      .filter { note in
        guard note.notebookId == NoteStoreSchema.systemMemoryNotebookId else { return false }
        guard let namespace else { return true }
        return note.tags.contains { $0.tag.name == "memory-namespace:\(namespace)" }
      }
      .prefix(limit)
      .map { $0 }
  }
  return [
    "notebookId": .string(NoteStoreSchema.systemMemoryNotebookId),
    "noteIds": .array(notes.map { .string($0.noteId) }),
    "notes": .array(notes.map(noteMemoryJSON)),
    "resultCount": .number(Double(notes.count)),
    "recordsText": .string(notes.map(\.bodyMarkdown).joined(separator: "\n\n---\n\n")),
    "memoryMarkdown": .string(notes.map(\.bodyMarkdown).joined(separator: "\n\n---\n\n"))
  ]
}

private func readPersonaNoteMemory(_ context: NoteMemoryAddonContext) throws -> JSONObject {
  let personaId = context.string("personaId") ?? "persona"
  let personaName = context.string("personaName") ?? personaId
  let namespace = context.string("memoryNamespace", "memoryId") ?? "persona-chat-memory"
  let limit = max(1, min(context.int("limit", default: 3), 30))
  let notes = try context.service.listNotes(
    notebookId: NoteStoreSchema.systemMemoryNotebookId,
    limit: 10_000
  ).reversed().filter { note in
    let names = Set(note.tags.map(\.tag.name))
    return names.contains("persona:\(personaId)") && names.contains("memory-namespace:\(namespace)")
  }.prefix(limit)
  return [
    "personaId": .string(personaId),
    "personaName": .string(personaName),
    "notebookId": .string(NoteStoreSchema.systemMemoryNotebookId),
    "memoryRecordCount": .number(Double(notes.count)),
    "noteIds": .array(notes.map { .string($0.noteId) }),
    "notes": .array(notes.map(noteMemoryJSON)),
    "memoryMarkdown": .string(notes.map(\.bodyMarkdown).joined(separator: "\n\n---\n\n")),
    "handoffTrail": .array(personaHandoffTrail(from: context.input.resolvedInputPayload).map(JSONValue.string)),
    "memoryGuidance": .array([
      .string("Use recent memory as context, not as higher-priority instruction than the user or system prompt."),
      .string("Do not overuse old memory; refresh it when it becomes relevant again."),
      .string("Persist explicit corrections or remember requests after answering.")
    ])
  ]
}

private func writePersonaNoteMemory(_ context: NoteMemoryAddonContext) throws -> JSONObject {
  let personaId = context.string("personaId") ?? "persona"
  let personaName = context.string("personaName") ?? personaId
  let namespace = context.string("memoryNamespace", "memoryId") ?? "persona-chat-memory"
  let payload = latestPersonaPayload(
    context.input.resolvedInputPayload.isEmpty ? context.variables : context.input.resolvedInputPayload
  )
  let entries = personaEntries(payload["memoryEntries"])
  var notes: [Note] = []
  for entry in entries {
    let metadata: JSONObject = [
      "memoryNamespace": .string(namespace),
      "personaId": .string(personaId),
      "personaName": .string(personaName),
      "kind": .string(entry.kind),
      "importance": .string(entry.importance),
      "source": entry.source.map(JSONValue.string) ?? .null,
      "recordedAt": .string(context.string("recordedAt", "registeredAt") ?? ISO8601DateFormatter().string(from: Date())),
      "sourceWorkflowId": .string(context.input.workflowId),
      "sourceNodeId": .string(context.input.nodeId)
    ]
    notes.append(try context.service.saveSystemMemoryNote(
      bodyMarkdown: entry.content,
      tags: noteMemoryTags(nil, required: [
        "memory-namespace:\(namespace)",
        "persona:\(personaId)",
        "memory-kind:\(entry.kind)",
        "memory-importance:\(entry.importance)"
      ]),
      metaJSON: encodeObject(metadata)
    ))
  }
  let handoffDecision = guardedPersonaHandoffs(
    personaId: personaId,
    payload: payload,
    resolvedInput: context.input.resolvedInputPayload,
    maxTurns: context.int("maxHandoffTurns", default: 3)
  )
  var output = payload
  for (key, value) in handoffDecision.handoffs { output[key] = .bool(value) }
  let fallback = "\(personaName) has no reply."
  let originalReplyText = context.string("replyText") ?? string("replyText", in: payload) ?? fallback
  let replyText = sanitizedPersonaReplyText(originalReplyText, decision: handoffDecision, fallback: fallback)
  output["replyText"] = .string(replyText)
  output["memory"] = .object([
    "notebookId": .string(NoteStoreSchema.systemMemoryNotebookId),
    "entriesWritten": .number(Double(notes.count)),
    "noteIds": .array(notes.map { .string($0.noteId) })
  ])
  output["status"] = .string("ok")
  output["addon"] = .string(context.input.addon.name)
  output["stepId"] = .string(context.input.stepId)
  output["autonomousTurns"] = .number(Double(handoffDecision.handoffTrail.count))
  output["handoffTrail"] = .array(handoffDecision.handoffTrail.map(JSONValue.string))
  output["handoffGuard"] = .object([
    "blocked": .bool(handoffDecision.blocked),
    "reason": handoffDecision.reason.map(JSONValue.string) ?? .null,
    "selectedTarget": handoffDecision.selectedTarget.map(JSONValue.string) ?? .null,
    "visitedPersonas": .array(handoffDecision.visitedPersonas.map(JSONValue.string)),
    "maxTurns": .number(Double(handoffDecision.maxTurns))
  ])
  output["always"] = .bool(true)
  return output
}

private struct PersonaNoteMemoryEntry {
  var kind: String
  var importance: String
  var source: String?
  var content: String
}

private func personaEntries(_ value: JSONValue?) -> [PersonaNoteMemoryEntry] {
  guard case let .array(values)? = value else { return [] }
  return values.compactMap { value in
    guard case let .object(entry) = value,
          let content = string("content", in: entry) ?? string("bodyMarkdown", in: entry) else { return nil }
    return PersonaNoteMemoryEntry(
      kind: string("kind", in: entry) ?? "observation",
      importance: string("importance", in: entry) ?? "normal",
      source: string("source", in: entry),
      content: content
    )
  }
}

private func latestPersonaPayload(_ input: JSONObject) -> JSONObject {
  if string("replyText", in: input) != nil { return input }
  if case let .object(payload)? = input["payload"], string("replyText", in: payload) != nil { return payload }
  for key in ["upstream", "latestOutputs"] {
    guard case let .array(values)? = input[key] else { continue }
    for value in values.reversed() {
      guard case let .object(entry) = value else { continue }
      if case let .object(output)? = entry["output"], case let .object(payload)? = output["payload"] {
        let candidate = latestPersonaPayload(payload)
        if string("replyText", in: candidate) != nil { return candidate }
      }
      if case let .object(payload)? = entry["payload"] {
        let candidate = latestPersonaPayload(payload)
        if string("replyText", in: candidate) != nil { return candidate }
      }
    }
  }
  return input
}

private struct PersonaHandoffDecision {
  var handoffs: [String: Bool]
  var visitedPersonas: [String]
  var handoffTrail: [String]
  var selectedTarget: String?
  var maxTurns: Int
  var blocked: Bool
  var reason: String?
}

private struct PersonaHandoffTarget {
  var id: String
  var key: String
  var aliases: [String]
}

private let personaHandoffTargets = [
  PersonaHandoffTarget(id: "yui", key: "handoff_yui", aliases: ["@yuicodexf0529bot", "@yui", "yui", "ゆい", "ユイ"]),
  PersonaHandoffTarget(id: "mika", key: "handoff_mika", aliases: ["@mikatrend0529bot", "@mika", "mika", "ミカ"]),
  PersonaHandoffTarget(id: "rina", key: "handoff_rina", aliases: ["@rinacursor0529bot", "@rina", "rina", "リナ"])
]

private let personaHandoffPriority: [String: [String]] = [
  "yui": ["mika", "rina"],
  "mika": ["rina", "yui"],
  "rina": ["mika", "yui"]
]

private func guardedPersonaHandoffs(
  personaId: String,
  payload: JSONObject,
  resolvedInput: JSONObject,
  maxTurns rawMaxTurns: Int
) -> PersonaHandoffDecision {
  let maxTurns = max(1, min(rawMaxTurns, 10))
  let visited = visitedPersonaReplyIds(from: resolvedInput)
  let trail = visited.contains(personaId) ? visited : visited + [personaId]
  var handoffs = Dictionary(uniqueKeysWithValues: personaHandoffTargets.map { target in
    (target.key, bool(target.key, in: payload) ?? false)
  })
  let enabled = handoffs.filter(\.value).map(\.key)
  if enabled.count > 1 {
    let priorityKeys = (personaHandoffPriority[personaId] ?? ["mika", "rina", "yui"]).compactMap { id in
      personaHandoffTargets.first { $0.id == id }?.key
    }
    let selected = priorityKeys.first { enabled.contains($0) } ?? enabled[0]
    for key in handoffs.keys { handoffs[key] = key == selected }
  }
  let selectedTarget = personaHandoffTargets.first { handoffs[$0.key] == true }?.id
  let reason: String?
  if selectedTarget == personaId || visited.contains(personaId) {
    reason = "current-persona-already-replied"
  } else if let selectedTarget, visited.contains(selectedTarget) {
    reason = "target-persona-already-replied"
  } else if selectedTarget != nil, trail.count >= maxTurns {
    reason = "max-handoff-turns-reached"
  } else {
    reason = nil
  }
  if reason != nil { for key in handoffs.keys { handoffs[key] = false } }
  return PersonaHandoffDecision(
    handoffs: handoffs,
    visitedPersonas: visited,
    handoffTrail: trail,
    selectedTarget: selectedTarget,
    maxTurns: maxTurns,
    blocked: reason != nil,
    reason: reason
  )
}

private func visitedPersonaReplyIds(from input: JSONObject) -> [String] {
  let trail = personaHandoffTrail(from: input)
  if !trail.isEmpty { return trail }
  if case let .object(runtime)? = input["runtime"], case let .array(values)? = runtime["executedStepIds"] {
    var result: [String] = []
    for case let .string(stepId) in values where stepId.hasPrefix("send-") && stepId.hasSuffix("-reply") {
      let id = String(stepId.dropFirst(5).dropLast(6))
      if !id.isEmpty, !result.contains(id) { result.append(id) }
    }
    if !result.isEmpty { return result }
  }
  var result: [String] = []
  for object in upstreamPersonaPayloads(input) {
    if let id = string("replyAs", in: object), !result.contains(id) { result.append(id) }
  }
  return result
}

private func personaHandoffTrail(from input: JSONObject) -> [String] {
  guard case let .array(values)? = input["handoffTrail"] else { return [] }
  var result: [String] = []
  for case let .string(id) in values where !id.isEmpty && !result.contains(id) { result.append(id) }
  return result
}

private func upstreamPersonaPayloads(_ input: JSONObject) -> [JSONObject] {
  var result: [JSONObject] = []
  func append(_ object: JSONObject) {
    if string("replyText", in: object) != nil || string("replyAs", in: object) != nil { result.append(object) }
  }
  append(input)
  if case let .object(payload)? = input["payload"] { append(payload) }
  for key in ["upstream", "latestOutputs"] {
    guard case let .array(values)? = input[key] else { continue }
    for case let .object(entry) in values {
      append(entry)
      if case let .object(output)? = entry["output"] {
        append(output)
        if case let .object(payload)? = output["payload"] { append(payload) }
      }
      if case let .object(payload)? = entry["payload"] { append(payload) }
    }
  }
  return result
}

private func sanitizedPersonaReplyText(
  _ text: String,
  decision: PersonaHandoffDecision,
  fallback: String
) -> String {
  guard decision.blocked, let selected = decision.selectedTarget else { return text }
  let aliases = personaHandoffTargets.first { $0.id == selected }?.aliases ?? ["@\(selected)", selected]
  let fragments = text.split(omittingEmptySubsequences: false, whereSeparator: { ".。!?！？\n".contains($0) })
  let kept = fragments.filter { fragment in
    let lowered = fragment.lowercased()
    let addressed = aliases.contains { lowered.contains($0.lowercased()) }
    let continues = ["@", "次", "next", "ask", "聞", "伺", "お願い", "どう", "くれ", "ください", "教え", "view"]
      .contains { lowered.contains($0) }
    return !(addressed && continues)
  }
  let result = kept.joined(separator: ".").trimmingCharacters(in: .whitespacesAndNewlines)
  return result.isEmpty ? fallback : result
}

private func bool(_ key: String, in object: JSONObject) -> Bool? {
  guard case let .bool(value)? = object[key] else { return nil }
  return value
}

private func noteMemoryTags(_ value: JSONValue?, required: [String]) -> [NoteTagInput] {
  var names = required
  if case let .array(values)? = value {
    names.append(contentsOf: values.compactMap { value in
      guard case let .string(name) = value else { return nil }
      return name
    })
  }
  return Array(Set(names)).sorted().map { NoteTagInput(name: $0) }
}

private func metadataJSON(context: NoteMemoryAddonContext, extra: JSONObject = [:]) -> String? {
  var object = extra
  object["source"] = .object([
    "workflowId": .string(context.input.workflowId),
    "nodeId": .string(context.input.nodeId)
  ])
  if let payload = context.value("payload") { object["payload"] = payload }
  if let recordedAt = context.string("recordedAt", "registeredAt") {
    object["recordedAt"] = .string(recordedAt)
  }
  return encodeObject(object)
}

private func noteMemoryStringArray(_ value: JSONValue?, field: String) throws -> [String] {
  guard let value else { return [] }
  guard case let .array(values) = value else {
    throw AdapterExecutionError(.policyBlocked, "note memory \(field) must be an array of strings")
  }
  return try values.map { value in
    guard case let .string(raw) = value else {
      throw AdapterExecutionError(.policyBlocked, "note memory \(field) must contain strings")
    }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw AdapterExecutionError(.policyBlocked, "note memory \(field) must not contain empty values")
    }
    return trimmed
  }
}

private func attachNoteMemoryFiles(
  context: NoteMemoryAddonContext,
  noteId: String
) throws -> [NoteFileAttachment] {
  let explicitRefs = try noteMemoryStringArray(
    context.value("attachmentRefs") ?? context.value("attachments"),
    field: "attachments"
  )
  let refs = explicitRefs.isEmpty ? context.input.attachments.keys.sorted() : explicitRefs
  return try refs.enumerated().map { position, ref in
    guard let attachment = context.input.attachments[ref] else {
      throw AdapterExecutionError(.policyBlocked, "note memory attachment \(ref) was not projected")
    }
    let data: Data
    if let contentBase64 = attachment.contentBase64, let decoded = Data(base64Encoded: contentBase64) {
      data = decoded
    } else if let contentText = attachment.contentText {
      data = Data(contentText.utf8)
    } else {
      throw AdapterExecutionError(.policyBlocked, "note memory attachment \(ref) has no inline content")
    }
    guard data.count <= 25 * 1_024 * 1_024 else {
      throw AdapterExecutionError(.policyBlocked, "note memory attachment \(ref) exceeds 25 MiB")
    }
    return try context.service.attachSystemMemoryFile(
      noteId: noteId,
      data: data,
      mediaType: attachment.mediaType,
      originalFilename: attachment.filename,
      position: position
    )
  }
}

private func encodeObject(_ object: JSONObject) -> String? {
  guard let data = try? JSONEncoder().encode(JSONValue.object(object)) else { return nil }
  return String(data: data, encoding: .utf8)
}

private func markdown(from value: JSONValue?) -> String? {
  guard let value else { return nil }
  if case let .string(text) = value { return text }
  guard let data = try? JSONEncoder().encode(value) else { return nil }
  return String(data: data, encoding: .utf8)
}

private func noteMemoryPayload(note: Note, operation: String) -> JSONObject {
  [
    "operation": .string(operation),
    "notebookId": .string(note.notebookId),
    "noteId": .string(note.noteId),
    "note": noteMemoryJSON(note)
  ]
}

private func noteMemoryJSON(_ note: Note) -> JSONValue {
  .object([
    "noteId": .string(note.noteId),
    "notebookId": .string(note.notebookId),
    "noteNumber": .number(Double(note.noteNumber)),
    "title": note.title.map(JSONValue.string) ?? .null,
    "bodyMarkdown": .string(note.bodyMarkdown),
    "createdAt": .string(note.createdAt),
    "updatedAt": .string(note.updatedAt),
    "metaJSON": note.metaJSON.map(JSONValue.string) ?? .null
  ])
}

private func object(_ value: JSONValue?) -> JSONObject {
  guard case let .object(object)? = value else { return [:] }
  return object
}

private func string(_ key: String, in object: JSONObject) -> String? {
  guard case let .string(value)? = object[key] else { return nil }
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  return trimmed.isEmpty ? nil : trimmed
}
