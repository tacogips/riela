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
        "memoryFileCountRead": .number(Double(records.count)),
        "memoryMarkdown": .string(chunks.joined(separator: "\n\n---\n\n")),
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

    let handoffs = normalizedPersonaHandoffs(personaId: context.personaId, payload: personaPayload)
    var payload = personaPayload
    for (key, value) in handoffs {
      payload[key] = .bool(value)
    }
    let replyText = nonEmptyString(payload["replyText"]) ?? personaMemoryFallbackReply(context: context)
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
      "entriesWritten": .number(Double(savedRecords.count)),
      "recordIds": .array(savedRecords.map { .number(Double($0.recordId)) }),
      "recordedAt": .string(recordedAt)
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
  lines.append(contentsOf: ["", content])
  return lines.joined(separator: "\n")
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
