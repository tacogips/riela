import Foundation
import RielaCore
import RielaMemory

extension BuiltinWorkflowAddonResolver {
  func executeChatPersonaMemoryRead(_ input: WorkflowAddonExecutionInput) throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(.policyBlocked, "unsupported \(input.addon.name) version '\(input.addon.version ?? "")'")
    }
    let context = personaMemoryContext(input)
    let store = RielaMemoryStore(rootDirectory: context.memoryRoot)
    let records = try store.search(
      memoryId: context.memoryId,
      options: MemorySearchOptions(
        workflowId: input.workflowId,
        includeAllWorkflows: true,
        tags: ["persona:\(context.personaId)"],
        limit: context.limit
      )
    )
    let chunks = records.map { personaMemoryMarkdown(record: $0) }
    let files = records.flatMap(\.files)
    let handoffTrail = personaHandoffTrail(from: input.resolvedInputPayload)
    return AdapterExecutionOutput(
      provider: "riela-builtin-addon",
      model: input.addon.name,
      promptText: "",
      completionPassed: true,
      payload: [
        "status": .string("ok"),
        "addon": .string(input.addon.name),
        "stepId": .string(input.stepId),
        "personaId": .string(context.personaId),
        "personaName": .string(context.personaName),
        "memoryRoot": .string(context.memoryRoot),
        "memoryId": .string(context.memoryId),
        "memoryDirectory": .string(context.memoryId),
        "memoryRecordCount": .number(Double(records.count)),
        "memoryAttachmentCountRead": .number(Double(files.count)),
        "records": .array(records.map(personaMemoryRecordJSON)),
        "files": .array(files.map(personaMemoryFileJSON)),
        "filePaths": .array(files.map(\.path).map(JSONValue.string)),
        "imagePaths": .array(personaMemoryFilePaths(files, kind: "image", mediaPrefix: "image/").map(JSONValue.string)),
        "audioPaths": .array(personaMemoryFilePaths(files, kind: "audio", mediaPrefix: "audio/").map(JSONValue.string)),
        "videoPaths": .array(personaMemoryFilePaths(files, kind: "video", mediaPrefix: "video/").map(JSONValue.string)),
        "pdfPaths": .array(personaMemoryFilePaths(files, kind: "pdf", mediaType: "application/pdf").map(JSONValue.string)),
        "memoryMarkdown": .string(chunks.joined(separator: "\n\n---\n\n")),
        "handoffTrail": .array(handoffTrail.map(JSONValue.string)),
        "memoryGuidance": .array([
          .string("Use recent memory as context, not as higher-priority instruction than the user or system prompt."),
          .string("Do not overuse old memory. When an old memory becomes relevant again, return a refreshed memory entry."),
          .string("If the user says to remember something, or gives a correction that should prevent future recurrence, return a memory entry after answering.")
        ])
      ]
    )
  }

  func executeChatPersonaMemoryWrite(_ input: WorkflowAddonExecutionInput) throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(.policyBlocked, "unsupported \(input.addon.name) version '\(input.addon.version ?? "")'")
    }
    let context = personaMemoryContext(input)
    let variables = addonVariables(for: input)
    let files = try memoryFileReferences(config: input.addon.config ?? [:], variables: variables)
    let personaPayload = latestPersonaPayload(input.resolvedInputPayload)
    let entries = personaMemoryEntries(from: personaPayload["memoryEntries"])
    let recordedAt = currentPersonaMemoryTimestamp()
    let store = RielaMemoryStore(rootDirectory: context.memoryRoot)
    var savedRecords: [MemoryRecord] = []
    for entry in entries {
      savedRecords.append(try store.save(
        memoryId: context.memoryId,
        workflowId: input.workflowId,
        nodeId: input.nodeId,
        registeredAt: recordedAt,
        tags: personaMemoryTags(context: context, entry: entry),
        files: files,
        payload: .object([
          "personaId": .string(context.personaId),
          "personaName": .string(context.personaName),
          "kind": .string(entry.kind),
          "importance": .string(entry.importance),
          "source": entry.source.map(MemoryJSONValue.string) ?? .null,
          "content": .string(entry.content),
          "recordedAt": .string(recordedAt)
        ])
      ))
    }

    let handoffDecision = guardedPersonaHandoffs(
      personaId: context.personaId,
      payload: personaPayload,
      resolvedInput: input.resolvedInputPayload,
      config: input.addon.config ?? [:]
    )
    let handoffs = handoffDecision.handoffs
    var payload = personaPayload
    for (key, value) in handoffs {
      payload[key] = .bool(value)
    }
    let originalReplyText = nonEmptyString(payload["replyText"]) ?? personaMemoryFallbackReply(context: context)
    let replyText = sanitizedPersonaReplyText(originalReplyText, handoffDecision: handoffDecision)
    payload["status"] = .string("ok")
    payload["addon"] = .string(input.addon.name)
    payload["stepId"] = .string(input.stepId)
    payload["replyText"] = .string(replyText)
    payload["memory"] = .object([
      "personaId": .string(context.personaId),
      "memoryRoot": .string(context.memoryRoot),
      "memoryId": .string(context.memoryId),
      "memoryDirectory": .string(context.memoryId),
      "memoryFile": .null,
      "filesWritten": .number(Double(files.count)),
      "entriesWritten": .number(Double(savedRecords.count)),
      "recordIds": .array(savedRecords.map { .number(Double($0.recordId)) }),
      "recordedAt": .string(recordedAt)
    ])
    payload["autonomousTurns"] = .number(Double(handoffDecision.turnCount))
    payload["handoffTrail"] = .array(handoffDecision.handoffTrail.map(JSONValue.string))
    payload["handoffGuard"] = .object([
      "blocked": .bool(handoffDecision.blocked),
      "reason": handoffDecision.reason.map(JSONValue.string) ?? .null,
      "selectedTarget": handoffDecision.selectedTarget.map(JSONValue.string) ?? .null,
      "visitedPersonas": .array(handoffDecision.visitedPersonas.map(JSONValue.string)),
      "maxTurns": .number(Double(handoffDecision.maxTurns))
    ])

    var when = handoffs
    when["always"] = true
    return AdapterExecutionOutput(
      provider: "riela-builtin-addon",
      model: input.addon.name,
      promptText: "",
      completionPassed: true,
      when: when,
      payload: payload
    )
  }
}

private struct PersonaMemoryContext {
  var personaId: String
  var personaName: String
  var memoryId: String
  var memoryRoot: String
  var limit: Int
}

private struct PersonaMemoryEntry {
  var kind: String
  var importance: String
  var source: String?
  var content: String
}

private struct PersonaHandoffDecision {
  var handoffs: [String: Bool]
  var visitedPersonas: [String]
  var handoffTrail: [String]
  var selectedTarget: String?
  var turnCount: Int
  var maxTurns: Int
  var blocked: Bool
  var reason: String?
}

private func personaMemoryContext(_ input: WorkflowAddonExecutionInput) -> PersonaMemoryContext {
  let config = input.addon.config ?? [:]
  let variables = addonVariables(for: input)
  let personaId = safePersonaMemorySegment(
    nonEmptyString(config["personaId"]) ?? nonEmptyString(variables["personaId"]) ?? "persona",
    fallback: "persona"
  )
  let personaName = nonEmptyString(config["personaName"]) ?? nonEmptyString(variables["personaName"]) ?? personaId
  let memoryId = nonEmptyString(config["memoryId"]) ?? nonEmptyString(variables["memoryId"]) ?? "persona-chat-memory"
  let workflowInput = personaMemoryJSONObject(variables["workflowInput"])
  let memoryRoot = nonEmptyString(config["memoryRoot"])
    ?? nonEmptyString(variables["memoryRoot"])
    ?? nonEmptyString(workflowInput["memoryRoot"])
    ?? RielaMemoryStore.defaultRootDirectory()
  let limit = personaMemoryInt(config["limit"]) ?? personaMemoryInt(variables["limit"]) ?? 3
  return PersonaMemoryContext(
    personaId: personaId,
    personaName: personaName,
    memoryId: memoryId,
    memoryRoot: memoryRoot,
    limit: max(1, min(limit, 30))
  )
}

private func personaMemoryJSONObject(_ value: JSONValue?) -> JSONObject {
  guard case let .object(object)? = value else {
    return [:]
  }
  return object
}

private func latestPersonaPayload(_ input: JSONObject) -> JSONObject {
  if nonEmptyString(input["replyText"]) != nil {
    return input
  }
  if case let .object(payload)? = input["payload"], nonEmptyString(payload["replyText"]) != nil {
    return payload
  }
  if case let .array(upstream)? = input["upstream"] {
    for value in upstream.reversed() {
      if case let .object(entry) = value,
        case let .object(output)? = entry["output"],
        case let .object(payload)? = output["payload"] {
        if nonEmptyString(payload["replyText"]) != nil {
          return payload
        }
        if case let .object(nested)? = payload["payload"], nonEmptyString(nested["replyText"]) != nil {
          return nested
        }
      }
    }
  }
  if case let .array(outputs)? = input["latestOutputs"] {
    for value in outputs.reversed() {
      if case let .object(output) = value,
        case let .object(payload)? = output["payload"],
        nonEmptyString(payload["replyText"]) != nil {
        return payload
      }
    }
  }
  return input
}

private func personaMemoryEntries(from value: JSONValue?) -> [PersonaMemoryEntry] {
  guard case let .array(values)? = value else {
    return []
  }
  return values.compactMap { value in
    if case let .string(content) = value {
      let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : PersonaMemoryEntry(kind: "note", importance: "normal", source: nil, content: trimmed)
    }
    guard case let .object(object) = value,
      let content = nonEmptyString(object["content"])?.trimmingCharacters(in: .whitespacesAndNewlines),
      !content.isEmpty
    else {
      return nil
    }
    return PersonaMemoryEntry(
      kind: nonEmptyString(object["kind"]) ?? "note",
      importance: nonEmptyString(object["importance"]) ?? "normal",
      source: nonEmptyString(object["source"]),
      content: content
    )
  }
}

private func personaMemoryTags(context: PersonaMemoryContext, entry: PersonaMemoryEntry) -> [String] {
  [
    "persona:\(context.personaId)",
    "kind:\(safePersonaMemorySegment(entry.kind, fallback: "note"))",
    "importance:\(safePersonaMemorySegment(entry.importance, fallback: "normal"))"
  ]
}

private func personaMemoryMarkdown(record: MemoryRecord) -> String {
  guard case let .object(object) = record.payload else {
    return "# record-\(record.recordId)\n\(record.registeredAt)"
  }
  let recordedAt = personaMemoryString(object["recordedAt"]) ?? record.registeredAt
  let kind = personaMemoryString(object["kind"]) ?? "note"
  let importance = personaMemoryString(object["importance"]) ?? "normal"
  let source = personaMemoryString(object["source"])
  let content = personaMemoryString(object["content"]) ?? ""
  var lines = [
    "# record-\(record.recordId)",
    "## \(recordedAt)",
    "",
    "- kind: \(kind)",
    "- importance: \(importance)"
  ]
  if let source {
    lines.append("- source: \(source)")
  }
  if !record.files.isEmpty {
    lines.append("- files: \(record.files.map(personaMemoryFileText).joined(separator: "; "))")
  }
  lines.append(contentsOf: ["", content])
  return lines.joined(separator: "\n")
}

private func personaMemoryRecordJSON(_ record: MemoryRecord) -> JSONValue {
  .object([
    "recordId": .number(Double(record.recordId)),
    "memoryId": .string(record.memoryId),
    "workflowId": .string(record.workflowId),
    "nodeId": record.nodeId.map { .string($0) } ?? .null,
    "registeredAt": .string(record.registeredAt),
    "tags": .array(record.tags.map { .string($0) }),
    "relatedRecordIds": .array(record.relatedRecordIds.map { .number(Double($0)) }),
    "files": .array(record.files.map(personaMemoryFileJSON)),
    "payload": personaJSONValue(from: record.payload)
  ])
}

private func personaMemoryFileJSON(_ file: MemoryFileReference) -> JSONValue {
  .object([
    "path": .string(file.path),
    "mediaType": file.mediaType.map { .string($0) } ?? .null,
    "kind": file.kind.map { .string($0) } ?? .null,
    "name": file.name.map { .string($0) } ?? .null,
    "sizeBytes": file.sizeBytes.map { .number(Double($0)) } ?? .null
  ])
}

private func personaMemoryFilePaths(
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

private func personaJSONValue(from value: MemoryJSONValue) -> JSONValue {
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
    return .array(values.map(personaJSONValue))
  case let .object(values):
    return .object(values.mapValues(personaJSONValue))
  }
}

private func personaMemoryFileText(_ file: MemoryFileReference) -> String {
  [
    file.kind,
    file.mediaType,
    file.name,
    file.path
  ].compactMap { $0 }.joined(separator: " ")
}

private func guardedPersonaHandoffs(
  personaId: String,
  payload: JSONObject,
  resolvedInput: JSONObject,
  config: JSONObject
) -> PersonaHandoffDecision {
  let maxTurns = max(1, min(personaMemoryInt(config["maxHandoffTurns"]) ?? 3, 10))
  let visitedPersonas = visitedPersonaReplyIds(from: resolvedInput)
  let handoffTrail = appendingPersona(personaId, to: visitedPersonas)
  var handoffs = normalizedPersonaHandoffs(personaId: personaId, payload: payload)
  let selectedTarget = selectedHandoffTarget(from: handoffs)
  var blockedReason: String?

  if visitedPersonas.contains(personaId) {
    blockedReason = "current-persona-already-replied"
  } else if let selectedTarget, visitedPersonas.contains(selectedTarget) {
    blockedReason = "target-persona-already-replied"
  } else if selectedTarget != nil, handoffTrail.count >= maxTurns {
    blockedReason = "max-handoff-turns-reached"
  }

  if blockedReason != nil {
    for key in handoffs.keys {
      handoffs[key] = false
    }
  }

  return PersonaHandoffDecision(
    handoffs: handoffs,
    visitedPersonas: visitedPersonas,
    handoffTrail: handoffTrail,
    selectedTarget: selectedTarget,
    turnCount: handoffTrail.count,
    maxTurns: maxTurns,
    blocked: blockedReason != nil,
    reason: blockedReason
  )
}

private func sanitizedPersonaReplyText(_ text: String, handoffDecision: PersonaHandoffDecision) -> String {
  let requireContinuationCue: Bool
  var personasToRemove: [String]
  if handoffDecision.blocked, let selectedTarget = handoffDecision.selectedTarget {
    personasToRemove = [selectedTarget]
    requireContinuationCue = false
  } else if selectedHandoffTarget(from: handoffDecision.handoffs) == nil,
    handoffDecision.turnCount >= handoffDecision.maxTurns {
    personasToRemove = handoffDecision.visitedPersonas
    requireContinuationCue = true
  } else {
    personasToRemove = []
    requireContinuationCue = true
  }
  guard !personasToRemove.isEmpty else {
    return text
  }
  let fragments = sentenceFragments(in: text)
  let kept = fragments.filter { fragment in
    !personasToRemove.contains { personaId in
      containsPersonaHandoffAddress(fragment, personaId: personaId)
        && (!requireContinuationCue || containsContinuationCue(fragment))
    }
  }
  let sanitized = kept.joined().trimmingCharacters(in: .whitespacesAndNewlines)
  return sanitized.isEmpty ? text : sanitized
}

private func sentenceFragments(in text: String) -> [String] {
  var fragments: [String] = []
  var current = ""
  for character in text {
    current.append(character)
    if ".。!?！？\n".contains(character) {
      fragments.append(current)
      current = ""
    }
  }
  if !current.isEmpty {
    fragments.append(current)
  }
  return fragments.isEmpty ? [text] : fragments
}

private func containsPersonaHandoffAddress(_ text: String, personaId: String) -> Bool {
  let lowered = text.lowercased()
  return personaHandoffAddressAliases(personaId: personaId).contains { alias in
    lowered.contains(alias.lowercased())
  }
}

private func containsContinuationCue(_ text: String) -> Bool {
  let lowered = text.lowercased()
  return [
    "@",
    "次",
    "next",
    "ask",
    "聞",
    "伺",
    "お願い",
    "どう",
    "view"
  ].contains { lowered.contains($0) }
}

private func personaHandoffAddressAliases(personaId: String) -> [String] {
  switch personaId {
  case "yui":
    return ["@yuicodexf0529bot", "@yui", "yui", "ゆい", "ユイ"]
  case "mika":
    return ["@mikatrend0529bot", "@mika", "mika", "ミカ"]
  case "rina":
    return ["@rinacursor0529bot", "@rina", "rina", "リナ"]
  default:
    return ["@\(personaId)", personaId]
  }
}

private func normalizedPersonaHandoffs(personaId: String, payload: JSONObject) -> [String: Bool] {
  var handoffs = [
    "handoff_yui": personaMemoryBool(payload["handoff_yui"]) ?? false,
    "handoff_mika": personaMemoryBool(payload["handoff_mika"]) ?? false,
    "handoff_rina": personaMemoryBool(payload["handoff_rina"]) ?? false
  ]
  let enabled = handoffs.filter(\.value).map(\.key)
  guard enabled.count > 1 else {
    return handoffs
  }
  let priorities = [
    "yui": ["handoff_mika", "handoff_rina"],
    "mika": ["handoff_rina", "handoff_yui"],
    "rina": ["handoff_mika", "handoff_yui"]
  ][personaId] ?? ["handoff_mika", "handoff_rina", "handoff_yui"]
  let selected = priorities.first { enabled.contains($0) } ?? enabled[0]
  for key in handoffs.keys {
    handoffs[key] = key == selected
  }
  return handoffs
}

private func selectedHandoffTarget(from handoffs: [String: Bool]) -> String? {
  if handoffs["handoff_yui"] == true {
    return "yui"
  }
  if handoffs["handoff_mika"] == true {
    return "mika"
  }
  if handoffs["handoff_rina"] == true {
    return "rina"
  }
  return nil
}

private func visitedPersonaReplyIds(from input: JSONObject) -> [String] {
  let trail = personaHandoffTrail(from: input)
  if !trail.isEmpty {
    return trail
  }
  let runtimeReplies = personaReplyIdsFromRuntime(from: input)
  if !runtimeReplies.isEmpty {
    return runtimeReplies
  }
  var visited: [String] = []
  for payload in personaMemoryUpstreamPayloads(input) {
    guard let replyAs = nonEmptyString(payload["replyAs"]).map({ safePersonaMemorySegment($0, fallback: "") }),
      !replyAs.isEmpty else {
      continue
    }
    if !visited.contains(replyAs) {
      visited.append(replyAs)
    }
  }
  return visited
}

private func personaReplyIdsFromRuntime(from input: JSONObject) -> [String] {
  guard case let .object(runtime)? = input["runtime"],
    case let .array(stepValues)? = runtime["executedStepIds"] else {
    return []
  }
  var personas: [String] = []
  for value in stepValues {
    guard case let .string(stepId) = value,
      let persona = personaIdFromReplyStepId(stepId),
      !personas.contains(persona) else {
      continue
    }
    personas.append(persona)
  }
  return personas
}

private func personaIdFromReplyStepId(_ stepId: String) -> String? {
  guard stepId.hasPrefix("send-"), stepId.hasSuffix("-reply") else {
    return nil
  }
  let withoutPrefix = stepId.dropFirst("send-".count)
  let rawPersona = withoutPrefix.dropLast("-reply".count)
  let personaId = safePersonaMemorySegment(String(rawPersona), fallback: "")
  return personaId.isEmpty ? nil : personaId
}

private func personaHandoffTrail(from input: JSONObject) -> [String] {
  guard case let .array(values)? = input["handoffTrail"] else {
    return []
  }
  var trail: [String] = []
  for value in values {
    guard let personaId = nonEmptyString(value).map({ safePersonaMemorySegment($0, fallback: "") }),
      !personaId.isEmpty,
      !trail.contains(personaId) else {
      continue
    }
    trail.append(personaId)
  }
  return trail
}

private func appendingPersona(_ personaId: String, to trail: [String]) -> [String] {
  if trail.contains(personaId) {
    return trail
  }
  return trail + [personaId]
}

private func personaMemoryUpstreamPayloads(_ input: JSONObject) -> [JSONObject] {
  var payloads: [JSONObject] = []
  appendPersonaMemoryPayloads(from: input, into: &payloads)
  if case let .object(payload)? = input["payload"] {
    appendPersonaMemoryPayloads(from: payload, into: &payloads)
  }
  if case let .array(upstream)? = input["upstream"] {
    for value in upstream {
      guard case let .object(entry) = value else {
        continue
      }
      if case let .object(output)? = entry["output"] {
        appendPersonaMemoryPayloads(from: output, into: &payloads)
        if case let .object(payload)? = output["payload"] {
          appendPersonaMemoryPayloads(from: payload, into: &payloads)
        }
      }
    }
  }
  if case let .array(outputs)? = input["latestOutputs"] {
    for value in outputs {
      guard case let .object(output) = value else {
        continue
      }
      appendPersonaMemoryPayloads(from: output, into: &payloads)
      if case let .object(payload)? = output["payload"] {
        appendPersonaMemoryPayloads(from: payload, into: &payloads)
      }
    }
  }
  return payloads
}

private func appendPersonaMemoryPayloads(from object: JSONObject, into payloads: inout [JSONObject]) {
  if nonEmptyString(object["replyText"]) != nil || nonEmptyString(object["replyAs"]) != nil {
    payloads.append(object)
  }
}

private func personaMemoryFallbackReply(context: PersonaMemoryContext) -> String {
  switch context.personaId {
  case "yui":
    return "では、肩の力を抜いて続けましょう。"
  case "mika":
    return "いいね、ゆるく続けよ。"
  case "rina":
    return "了解。ここまでで一度区切れる。"
  default:
    return "\(context.personaName)です。今の話題を受けて、自然に続けます。"
  }
}

private func safePersonaMemorySegment(_ value: String, fallback: String) -> String {
  let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-")
  let normalized = value.lowercased().unicodeScalars.map { scalar -> String in
    allowed.contains(scalar) ? String(scalar) : "-"
  }.joined()
  let trimmed = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
  return trimmed.isEmpty ? fallback : trimmed
}

private func personaMemoryString(_ value: MemoryJSONValue?) -> String? {
  guard case let .string(string)? = value, !string.isEmpty else {
    return nil
  }
  return string
}

private func personaMemoryBool(_ value: JSONValue?) -> Bool? {
  guard case let .bool(value)? = value else {
    return nil
  }
  return value
}

private func personaMemoryInt(_ value: JSONValue?) -> Int? {
  guard case let .number(number)? = value, number.rounded() == number else {
    return nil
  }
  return Int(number)
}

private func currentPersonaMemoryTimestamp() -> String {
  ISO8601DateFormatter().string(from: Date())
}
