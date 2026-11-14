import Foundation
import RielaCore
import AppCore

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
  let access = try authorizeNotePersonaAccess(context, targetPersonaId: personaId, operation: .read)
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
    "access": access.json,
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
    "handoffTrail": .array(visitedNotePersonaIds(
      context.variables,
      targets: try notePersonaConfiguredIds(context.config["teamPersonaIds"], field: "teamPersonaIds")
    ).map(JSONValue.string))
  ]
}

private enum NotePersonaAccessOperation: String {
  case read
  case write
}

private struct NotePersonaAccessDecision {
  var actorPersonaId: String
  var targetPersonaId: String
  var operation: NotePersonaAccessOperation
  var allowedReadPersonaIds: [String]

  var json: JSONValue {
    .object([
      "actorPersonaId": .string(actorPersonaId),
      "targetPersonaId": .string(targetPersonaId),
      "operation": .string(operation.rawValue),
      "allowed": .bool(true),
      "allowedReadPersonaIds": .array(allowedReadPersonaIds.map(JSONValue.string))
    ])
  }
}

private func authorizeNotePersonaAccess(
  _ context: NoteAddonContext,
  targetPersonaId: String,
  operation: NotePersonaAccessOperation
) throws -> NotePersonaAccessDecision {
  let actorPersonaId = context.string("actorPersonaId") ?? targetPersonaId
  let configuredReadIds = try notePersonaConfiguredIds(
    context.config["allowedReadPersonaIds"],
    field: "allowedReadPersonaIds"
  ) ?? []
  let allowedReadIds = Array(Set(configuredReadIds + [actorPersonaId])).sorted()
  let allowed = operation == .read
    ? allowedReadIds.contains(targetPersonaId)
    : actorPersonaId == targetPersonaId
  guard allowed else {
    throw AdapterExecutionError(
      .policyBlocked,
      "persona memory \(operation.rawValue) denied: actor '\(actorPersonaId)' cannot access target '\(targetPersonaId)'"
    )
  }
  return NotePersonaAccessDecision(
    actorPersonaId: actorPersonaId,
    targetPersonaId: targetPersonaId,
    operation: operation,
    allowedReadPersonaIds: allowedReadIds
  )
}

private func notePersonaConfiguredIds(_ value: JSONValue?, field: String) throws -> [String]? {
  guard let value else { return nil }
  guard case let .array(values) = value, !values.isEmpty else {
    throw noteAddonInvalidInput("\(field) must be a non-empty array")
  }
  var ids: [String] = []
  for (index, value) in values.enumerated() {
    guard let id = nonEmptyString(value)?.lowercased(), !id.isEmpty else {
      throw noteAddonInvalidInput("\(field)[\(index)] must be a non-empty string")
    }
    if !ids.contains(id) { ids.append(id) }
  }
  return ids
}

func writePersonaContext(_ context: NoteAddonContext) throws -> JSONObject {
  let personaId = try context.requiredString("personaId", fieldName: "personaId")
  let access = try authorizeNotePersonaAccess(context, targetPersonaId: personaId, operation: .write)
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
    teamPersonaIds: try notePersonaConfiguredIds(context.config["teamPersonaIds"], field: "teamPersonaIds")
      ?? inferredNotePersonaIds(payload: payload, currentPersonaId: personaId),
    maxTurns: context.int("maxHandoffTurns", default: 3)
  )
  var result = payload
  for (key, enabled) in handoff.values {
    result[key] = .bool(enabled)
  }
  let fallbackReply = notePersonaFallbackReply(personaName: personaName)
  let replyText = nonEmptyString(result["replyText"]) ?? fallbackReply
  result["replyText"] = .string(notePersonaSanitizedReplyText(
    replyText,
    decision: handoff,
    fallback: fallbackReply
  ))
  result["notebookId"] = .string(notebook.notebookId)
  result["personaId"] = .string(personaId)
  result["personaName"] = .string(personaName)
  result["access"] = access.json
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
  var recoveredFromTarget: String?
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
  teamPersonaIds: [String],
  maxTurns requestedMaxTurns: Int
) -> NotePersonaHandoffDecision {
  let targets = teamPersonaIds
  let maxTurns = max(1, min(requestedMaxTurns, 10))
  let visitedPersonas = visitedNotePersonaIds(variables, targets: targets)
  var trail = visitedPersonas
  var handoffs = Dictionary(uniqueKeysWithValues: targets.map { id in
    ("handoff_\(id)", boolValue(payload["handoff_\(id)"]) ?? false)
  })
  let priorities = targets.filter { $0 != personaId }
  let enabled = priorities.filter { handoffs["handoff_\($0)"] == true }
  if let selected = enabled.first {
    for key in handoffs.keys {
      handoffs[key] = key == "handoff_\(selected)"
    }
  }
  let originallySelected = targets.first { handoffs["handoff_\($0)"] == true }
  var selected = originallySelected
  var recoveredFromTarget: String?
  let selectedAlreadyReplied = selected == personaId || selected.map(visitedPersonas.contains) == true
  if selectedAlreadyReplied,
     let recoveryTarget = requestedNotePersonaIds(variables, targets: targets).first(where: {
       $0 != personaId && !visitedPersonas.contains($0)
     }),
     visitedPersonas.count + 1 < maxTurns {
    for key in handoffs.keys {
      handoffs[key] = key == "handoff_\(recoveryTarget)"
    }
    recoveredFromTarget = selected
    selected = recoveryTarget
  }
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
    recoveredFromTarget: recoveredFromTarget,
    maxTurns: maxTurns,
    blocked: reason != nil,
    reason: reason
  )
}

private let notePersonaHandoffContinuationCues = [
  "@", "次", "next", "ask", "聞", "伺", "お願い", "どう", "くれ", "ください", "教え", "view"
]

private func notePersonaSanitizedReplyText(
  _ text: String,
  decision: NotePersonaHandoffDecision,
  fallback: String
) -> String {
  let personasToRemove: [String]
  if let recoveredFromTarget = decision.recoveredFromTarget {
    personasToRemove = [recoveredFromTarget]
  } else if decision.blocked, let selectedTarget = decision.selectedTarget {
    personasToRemove = [selectedTarget]
  } else if decision.selectedTarget == nil, decision.trail.count >= decision.maxTurns {
    personasToRemove = decision.visitedPersonas
  } else {
    personasToRemove = []
  }
  let kept = notePersonaSentenceFragments(text).filter { fragment in
    !personasToRemove.contains { personaId in
      notePersonaContainsHandoffAddress(fragment, personaId: personaId)
        && notePersonaContainsContinuationCue(fragment)
    }
  }
  let sanitized = kept.joined().trimmingCharacters(in: .whitespacesAndNewlines)
  let base = sanitized.isEmpty ? fallback : sanitized
  guard decision.recoveredFromTarget != nil, let selectedTarget = decision.selectedTarget else {
    return base
  }
  return "\(base) @\(selectedTarget.capitalized)、あなたの観点をお願いします。"
}

private func requestedNotePersonaIds(_ variables: JSONObject, targets: [String]) -> [String] {
  let humanInput = notePersonaObject(variables["humanInput"])
  let workflowInput = notePersonaObject(variables["workflowInput"])
  let event = notePersonaObject(variables["event"])
  let eventInput = notePersonaObject(event["input"])
  let candidates = [humanInput, workflowInput, eventInput]
    .compactMap { nonEmptyString($0["request"]) ?? nonEmptyString($0["text"]) }
  let request = candidates.first ?? ""
  let normalized = request.lowercased()
  return targets.compactMap { target -> (String, String.Index)? in
    guard let range = normalized.range(of: target.lowercased()) else { return nil }
    return (target, range.lowerBound)
  }.sorted { lhs, rhs in
    if lhs.1 == rhs.1 { return lhs.0 < rhs.0 }
    return lhs.1 < rhs.1
  }.map(\.0)
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
  let aliases = ["@\(personaId)", personaId]
  return aliases.contains { lowered.contains($0.lowercased()) }
}

private func notePersonaContainsContinuationCue(_ text: String) -> Bool {
  let lowered = text.lowercased()
  return notePersonaHandoffContinuationCues.contains { lowered.contains($0) }
}

private func notePersonaFallbackReply(personaName: String) -> String {
  "\(personaName)です。今の話題を受けて、自然に続けます。"
}

private func visitedNotePersonaIds(
  _ variables: JSONObject,
  targets: [String]? = nil
) -> [String] {
  var visited: [String] = []
  func append(_ value: JSONValue?) {
    guard let id = nonEmptyString(value)?.lowercased(),
          targets?.contains(id) != false, !visited.contains(id) else { return }
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

private func inferredNotePersonaIds(payload: JSONObject, currentPersonaId: String) -> [String] {
  var ids = [currentPersonaId]
  for key in payload.keys.sorted() where key.hasPrefix("handoff_") {
    let id = String(key.dropFirst("handoff_".count)).lowercased()
    if !id.isEmpty, !ids.contains(id) { ids.append(id) }
  }
  return ids
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
