import Foundation
import RielaCore
import RielaNote

private struct NotePersonaEntry {
  var content: String
  var kind: String
  var importance: String
  var source: String?
  var relatedNoteIds: [String]
  var attachmentRefs: [String]
}

private struct PreparedNotePersonaEntry {
  var content: String
  var tags: [NoteTagInput]
  var metaJSON: String?
  var relatedNoteIds: [String]
  var attachments: [SystemMemoryAttachmentInput]
}

func readPersonaContext(_ context: NoteAddonContext) throws -> JSONObject {
  let personaId = try context.requiredString("personaId", fieldName: "personaId")
  let personaName = context.string("personaName") ?? personaId
  let notes = try context.service.listSystemMemoryNotes(
    personaId: personaId,
    limit: context.int("limit", default: 3)
  )
  let notebook = try context.service.systemMemoryNotebook()
  let attachmentLimit = max(1, min(context.int("attachmentLimit", default: 12), 64))
  let attachments = Array(try notes.flatMap { try context.service.listFiles(noteId: $0.noteId) }.prefix(attachmentLimit))
  let materializedAttachments = try materializedPersonaAttachments(attachments, noteRoot: context.noteRoot)
  let paths = materializedAttachments.map(\.path)
  let imagePaths = attachmentPaths(materializedAttachments, mediaTypePrefix: "image/")
  let audioPaths = attachmentPaths(materializedAttachments, mediaTypePrefix: "audio/")
  let videoPaths = attachmentPaths(materializedAttachments, mediaTypePrefix: "video/")
  let pdfPaths = materializedAttachments.compactMap { attachment in
    attachment.mediaType == "application/pdf" ? attachment.path : nil
  }
  let contextMarkdown = notes.map { note in
    "## \(note.createdAt)\n\n\(note.bodyMarkdown)"
  }.joined(separator: "\n\n---\n\n")
  return [
    "notebookId": .string(notebook.notebookId),
    "personaId": .string(personaId),
    "personaName": .string(personaName),
    "noteCount": .number(Double(notes.count)),
    "notes": .array(notes.map(noteJSON)),
    "filePaths": .array(paths.map(JSONValue.string)),
    "imagePaths": .array(imagePaths.map(JSONValue.string)),
    "audioPaths": .array(audioPaths.map(JSONValue.string)),
    "videoPaths": .array(videoPaths.map(JSONValue.string)),
    "pdfPaths": .array(pdfPaths.map(JSONValue.string)),
    "contextMarkdown": .string(contextMarkdown),
    "contextGuidance": .array([
      .string("Use stored context only as background; user and system instructions remain higher priority."),
      .string("Prefer recent context and write a refreshed entry when older context becomes relevant again.")
    ]),
    "handoffTrail": .array(visitedNotePersonaIds(context.variables).map(JSONValue.string))
  ]
}

func writePersonaContext(_ context: NoteAddonContext) throws -> JSONObject {
  let personaId = try context.requiredString("personaId", fieldName: "personaId")
  let personaName = context.string("personaName") ?? personaId
  let payload = latestNotePersonaPayload(context.variables)
  let entries = try notePersonaEntries(payload["noteEntries"])
  let preparedEntries = try prepareNotePersonaEntries(
    entries,
    personaId: personaId,
    personaName: personaName,
    context: context
  )
  let notes = try context.service.appendSystemMemoryNotes(
    preparedEntries.map { entry in
      SystemMemoryNoteInput(
        bodyMarkdown: entry.content,
        tags: entry.tags,
        metaJSON: entry.metaJSON,
        relatedNoteIds: entry.relatedNoteIds,
        attachments: entry.attachments
      )
    },
    idempotencyKey: notePersonaWriteIdempotencyKey(context)
  )
  let noteIds = notes.map(\.noteId)
  let attachmentCount = preparedEntries.reduce(0) { $0 + $1.attachments.count }
  let notebook = try context.service.systemMemoryNotebook()
  let handoff = notePersonaHandoffDecision(
    personaId: personaId,
    payload: payload,
    variables: context.variables,
    maxTurns: context.int("maxHandoffTurns", default: 3)
  )
  var result = payload
  for (key, enabled) in handoff.values {
    result[key] = .bool(enabled)
  }
  let fallbackReply = notePersonaFallbackReply(personaId: personaId, personaName: personaName)
  let replyText = nonEmptyString(result["replyText"]) ?? fallbackReply
  result["replyText"] = .string(notePersonaSanitizedReplyText(
    replyText,
    decision: handoff,
    fallback: fallbackReply
  ))
  result["notebookId"] = .string(notebook.notebookId)
  result["personaId"] = .string(personaId)
  result["personaName"] = .string(personaName)
  result["entriesWritten"] = .number(Double(noteIds.count))
  result["noteIds"] = .array(noteIds.map(JSONValue.string))
  result["attachmentsWritten"] = .number(Double(attachmentCount))
  result["recordedAt"] = .string(currentNotePersonaTimestamp())
  result["autonomousTurns"] = .number(Double(handoff.trail.count))
  result["handoffTrail"] = .array(handoff.trail.map(JSONValue.string))
  result["handoffGuard"] = .object([
    "blocked": .bool(handoff.blocked),
    "reason": handoff.reason.map(\.rawValue).map(JSONValue.string) ?? .null,
    "selectedTarget": handoff.selectedTarget.map(JSONValue.string) ?? .null,
    "visitedPersonas": .array(handoff.visitedPersonas.map(JSONValue.string)),
    "maxTurns": .number(Double(handoff.maxTurns))
  ])
  return result
}

private func prepareNotePersonaEntries(
  _ entries: [NotePersonaEntry],
  personaId: String,
  personaName: String,
  context: NoteAddonContext
) throws -> [PreparedNotePersonaEntry] {
  try entries.map { entry in
    var resolvedRelatedNoteIds: [String] = []
    var unresolvedRelatedRecordIds: [String] = []
    for relatedNoteId in entry.relatedNoteIds {
      do {
        _ = try context.service.getNote(relatedNoteId)
        resolvedRelatedNoteIds.append(relatedNoteId)
      } catch let error as NoteServiceError {
        guard case .notFound = error else {
          throw error
        }
        unresolvedRelatedRecordIds.append(relatedNoteId)
      }
    }
    let metadata: JSONValue = .object([
      "systemMemoryVersion": .number(1),
      "personaId": .string(personaId),
      "personaName": .string(personaName),
      "kind": .string(entry.kind),
      "importance": .string(entry.importance),
      "source": entry.source.map(JSONValue.string) ?? .null,
      "workflowId": .string(context.input.workflowId),
      "nodeId": .string(context.input.nodeId),
      "relatedRecordIds": .array(unresolvedRelatedRecordIds.map(JSONValue.string)),
      "recordedAt": .string(currentNotePersonaTimestamp())
    ])
    let attachments = try prepareNotePersonaAttachments(entry.attachmentRefs, context: context)
    return PreparedNotePersonaEntry(
      content: entry.content,
      tags: [
        NoteTagInput(name: "persona:\(personaId)"),
        NoteTagInput(name: "kind:\(entry.kind)"),
        NoteTagInput(name: "importance:\(entry.importance)")
      ],
      metaJSON: noteMetaJSONString(metadata),
      relatedNoteIds: resolvedRelatedNoteIds,
      attachments: attachments
    )
  }
}

private func notePersonaWriteIdempotencyKey(_ context: NoteAddonContext) -> String? {
  let rielaInput = notePersonaObject(context.variables["_rielaInput"])
  let latest = notePersonaObject(rielaInput["latest"])
  guard let workflowExecutionId = nonEmptyString(rielaInput["workflowExecutionId"]),
        let sourceExecutionId = nonEmptyString(rielaInput["sourceStepExecutionId"])
          ?? nonEmptyString(latest["sourceStepExecutionId"])
          ?? nonEmptyString(rielaInput["communicationId"])
          ?? nonEmptyString(latest["communicationId"]) else {
    return nil
  }
  return [
    workflowExecutionId,
    context.input.workflowId,
    context.input.stepId,
    context.input.nodeId,
    sourceExecutionId
  ].joined(separator: ":")
}

private func notePersonaObject(_ value: JSONValue?) -> JSONObject {
  guard case let .object(object)? = value else {
    return [:]
  }
  return object
}

private func prepareNotePersonaAttachments(
  _ refs: [String],
  context: NoteAddonContext
) throws -> [SystemMemoryAttachmentInput] {
  try refs.enumerated().map { position, ref in
    guard let attachment = try sourceAttachmentInput(ref: ref, context: context) else {
      throw noteAddonInvalidInput("\(context.input.addon.name) attachment cannot be resolved: \(ref)")
    }
    switch attachment {
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

private struct NotePersonaHandoffDecision {
  var values: [String: Bool]
  var visitedPersonas: [String]
  var trail: [String]
  var selectedTarget: String?
  var maxTurns: Int
  var blocked: Bool
  var reason: NotePersonaHandoffBlockReason?
}

private enum NotePersonaHandoffBlockReason: String {
  case currentPersonaAlreadyReplied = "current-persona-already-replied"
  case targetPersonaAlreadyReplied = "target-persona-already-replied"
  case maxHandoffTurnsReached = "max-handoff-turns-reached"
}

private func notePersonaHandoffDecision(
  personaId: String,
  payload: JSONObject,
  variables: JSONObject,
  maxTurns requestedMaxTurns: Int
) -> NotePersonaHandoffDecision {
  let targets = ["yui", "mika", "rina"]
  let maxTurns = max(1, min(requestedMaxTurns, 10))
  let visitedPersonas = visitedNotePersonaIds(variables)
  var trail = visitedPersonas
  var handoffs = Dictionary(uniqueKeysWithValues: targets.map { id in
    ("handoff_\(id)", boolValue(payload["handoff_\(id)"]) ?? false)
  })
  let priorities = notePersonaHandoffPriorities[personaId] ?? targets
  let enabled = priorities.filter { handoffs["handoff_\($0)"] == true }
  if let selected = enabled.first {
    for key in handoffs.keys {
      handoffs[key] = key == "handoff_\(selected)"
    }
  }
  let selected = targets.first { handoffs["handoff_\($0)"] == true }
  let reason: NotePersonaHandoffBlockReason?
  if selected == personaId || visitedPersonas.contains(personaId) {
    reason = .currentPersonaAlreadyReplied
  } else if let selected, visitedPersonas.contains(selected) {
    reason = .targetPersonaAlreadyReplied
  } else if selected != nil, visitedPersonas.count + 1 >= maxTurns {
    reason = .maxHandoffTurnsReached
  } else {
    reason = nil
  }
  if reason != nil {
    for key in handoffs.keys { handoffs[key] = false }
  }
  if !trail.contains(personaId) { trail.append(personaId) }
  return NotePersonaHandoffDecision(
    values: handoffs,
    visitedPersonas: visitedPersonas,
    trail: trail,
    selectedTarget: selected,
    maxTurns: maxTurns,
    blocked: reason != nil,
    reason: reason
  )
}

private let notePersonaHandoffPriorities = [
  "yui": ["mika", "rina"],
  "mika": ["rina", "yui"],
  "rina": ["mika", "yui"]
]

private let notePersonaHandoffAliases = [
  "yui": ["@yuicodexf0529bot", "@yui", "yui", "ゆい", "ユイ"],
  "mika": ["@mikatrend0529bot", "@mika", "mika", "ミカ"],
  "rina": ["@rinacursor0529bot", "@rina", "rina", "リナ"]
]

private let notePersonaHandoffContinuationCues = [
  "@", "次", "next", "ask", "聞", "伺", "お願い", "どう", "くれ", "ください", "教え", "view"
]

private func notePersonaSanitizedReplyText(
  _ text: String,
  decision: NotePersonaHandoffDecision,
  fallback: String
) -> String {
  let personasToRemove: [String]
  if decision.blocked, let selectedTarget = decision.selectedTarget {
    personasToRemove = [selectedTarget]
  } else if decision.selectedTarget == nil, decision.trail.count >= decision.maxTurns {
    personasToRemove = decision.visitedPersonas
  } else {
    personasToRemove = []
  }
  guard !personasToRemove.isEmpty else { return text }
  let kept = notePersonaSentenceFragments(text).filter { fragment in
    !personasToRemove.contains { personaId in
      notePersonaContainsHandoffAddress(fragment, personaId: personaId)
        && notePersonaContainsContinuationCue(fragment)
    }
  }
  let sanitized = kept.joined().trimmingCharacters(in: .whitespacesAndNewlines)
  return sanitized.isEmpty ? fallback : sanitized
}

private func notePersonaSentenceFragments(_ text: String) -> [String] {
  var fragments: [String] = []
  var current = ""
  for character in text {
    current.append(character)
    if ".。!?！？\n".contains(character) {
      fragments.append(current)
      current = ""
    }
  }
  if !current.isEmpty { fragments.append(current) }
  return fragments.isEmpty ? [text] : fragments
}

private func notePersonaContainsHandoffAddress(_ text: String, personaId: String) -> Bool {
  let lowered = text.lowercased()
  let aliases = notePersonaHandoffAliases[personaId] ?? ["@\(personaId)", personaId]
  return aliases.contains { lowered.contains($0.lowercased()) }
}

private func notePersonaContainsContinuationCue(_ text: String) -> Bool {
  let lowered = text.lowercased()
  return notePersonaHandoffContinuationCues.contains { lowered.contains($0) }
}

private func notePersonaFallbackReply(personaId: String, personaName: String) -> String {
  switch personaId {
  case "yui":
    return "では、肩の力を抜いて続けましょう。"
  case "mika":
    return "いいね、ゆるく続けよ。"
  case "rina":
    return "了解。ここまでで一度区切れる。"
  default:
    return "\(personaName)です。今の話題を受けて、自然に続けます。"
  }
}

private func visitedNotePersonaIds(_ variables: JSONObject) -> [String] {
  let targets = ["yui", "mika", "rina"]
  var visited: [String] = []
  func append(_ value: JSONValue?) {
    guard let id = nonEmptyString(value)?.lowercased(),
          targets.contains(id), !visited.contains(id) else { return }
    visited.append(id)
  }
  if case let .array(values)? = variables["handoffTrail"] {
    values.forEach(append)
  }
  if !visited.isEmpty { return visited }
  if case let .object(runtime)? = variables["runtime"],
     case let .array(stepValues)? = runtime["executedStepIds"] {
    for value in stepValues {
      guard let stepId = nonEmptyString(value),
            stepId.hasPrefix("send-"), stepId.hasSuffix("-reply") else { continue }
      let start = stepId.index(stepId.startIndex, offsetBy: "send-".count)
      let end = stepId.index(stepId.endIndex, offsetBy: -"-reply".count)
      append(.string(String(stepId[start..<end])))
    }
  }
  if !visited.isEmpty { return visited }
  if case let .array(upstream)? = variables["upstream"] {
    for value in upstream {
      guard case let .object(entry) = value,
            case let .object(output)? = entry["output"] else { continue }
      append(output["replyAs"])
      if case let .object(payload)? = output["payload"] {
        append(payload["replyAs"])
        if case let .array(trail)? = payload["handoffTrail"] {
          trail.forEach(append)
        }
      }
    }
  }
  return visited
}

private func latestNotePersonaPayload(_ variables: JSONObject) -> JSONObject {
  if case let .object(payload)? = variables["payload"], payload["noteEntries"] != nil {
    return payload
  }
  if case let .array(upstream)? = variables["upstream"] {
    for value in upstream.reversed() {
      if case let .object(entry) = value,
         case let .object(output)? = entry["output"],
         case let .object(payload)? = output["payload"] {
        if case let .object(nested)? = payload["payload"], nested["noteEntries"] != nil {
          return nested
        }
        if payload["noteEntries"] != nil || payload["replyText"] != nil {
          return payload
        }
      }
    }
  }
  return variables
}

private func notePersonaEntries(_ value: JSONValue?) throws -> [NotePersonaEntry] {
  guard let value else { return [] }
  guard case let .array(values) = value else {
    throw noteAddonInvalidInput("noteEntries must be an array")
  }
  return try values.enumerated().map { index, value in
    if case let .string(content) = value {
      let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        throw noteAddonInvalidInput("noteEntries[\(index)].content must not be empty")
      }
      return NotePersonaEntry(
        content: trimmed,
        kind: "note",
        importance: "normal",
        source: nil,
        relatedNoteIds: [],
        attachmentRefs: []
      )
    }
    guard case let .object(object) = value,
          let content = nonEmptyString(object["content"]),
          !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw noteAddonInvalidInput("noteEntries[\(index)] must contain non-empty content")
    }
    return NotePersonaEntry(
      content: content,
      kind: nonEmptyString(object["kind"]) ?? "note",
      importance: nonEmptyString(object["importance"]) ?? "normal",
      source: nonEmptyString(object["source"]),
      relatedNoteIds: try notePersonaStringArray(
        object["relatedNoteIds"] ?? object["relatedRecordIds"],
        field: "noteEntries[\(index)].relatedNoteIds"
      ),
      attachmentRefs: try notePersonaStringArray(
        object["attachments"] ?? object["files"],
        field: "noteEntries[\(index)].attachments"
      )
    )
  }
}

private func notePersonaStringArray(_ value: JSONValue?, field: String) throws -> [String] {
  guard let value else { return [] }
  guard case let .array(values) = value else {
    throw noteAddonInvalidInput("\(field) must be an array")
  }
  return try values.enumerated().map { index, value in
    guard let string = nonEmptyString(value) else {
      throw noteAddonInvalidInput("\(field)[\(index)] must be a non-empty string")
    }
    return string
  }
}

private struct MaterializedPersonaAttachment {
  var mediaType: String
  var path: String
}

private func materializedPersonaAttachments(
  _ attachments: [NoteFileAttachment],
  noteRoot: String
) throws -> [MaterializedPersonaAttachment] {
  let fileStore = LocalNoteFileStore(noteRoot: noteRoot)
  return try attachments.compactMap { attachment in
    guard attachment.file.storageKind == .local else { return nil }
    return MaterializedPersonaAttachment(
      mediaType: attachment.file.mediaType,
      path: try fileStore.fileURL(record: attachment.file).path
    )
  }
}

private func attachmentPaths(
  _ attachments: [MaterializedPersonaAttachment],
  mediaTypePrefix: String
) -> [String] {
  attachments.compactMap { attachment in
    attachment.mediaType.hasPrefix(mediaTypePrefix) ? attachment.path : nil
  }
}

private func currentNotePersonaTimestamp() -> String {
  ISO8601DateFormatter().string(from: Date())
}
