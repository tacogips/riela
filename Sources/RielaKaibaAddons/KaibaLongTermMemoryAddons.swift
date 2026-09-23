import Foundation
import KaibaClient
import RielaAddonSupport
import RielaCore

extension KaibaAddonCatalog {
  static func executeLongTermMemoryAddon(
    _ input: WorkflowAddonExecutionInput,
    client: KaibaClient,
    operation: BuiltinKaibaLongTermMemoryAddon
  ) async throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(.policyBlocked, "unsupported \(input.addon.name) version '\(input.addon.version ?? "")'")
    }
    let values = KaibaAddonInputs(input: input, environment: [:])
    do {
      let payload: JSONObject
      switch operation {
      case .consolidate:
        payload = try await consolidateLongTermMemory(input, values: values, client: client)
      case .recall:
        payload = try await recallLongTermMemory(values: values, client: client)
      }
      return addonOutput(
        input: input,
        operation: operation.rawValue.replacingOccurrences(of: "kaiba/", with: ""),
        payload: payload,
        values: values
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as AdapterExecutionError {
      throw error
    } catch {
      throw AdapterExecutionError(.providerError, "Kaiba HTTP operation failed")
    }
  }
}

private func consolidateLongTermMemory(
  _ input: WorkflowAddonExecutionInput,
  values: KaibaAddonInputs,
  client: KaibaClient
) async throws -> JSONObject {
  let entries = try memoryEntries(values.value("entries") ?? values.value("memoryEntries"))
  let key = try idempotencyKey(input, values: values, discriminator: "memory-consolidate:append")
  guard !entries.isEmpty || values.bool("allowEmptyEntries", default: false) else {
    throw noteAddonInvalidInput("\(input.addon.name) requires at least one entry in config.entries or upstream memoryEntries")
  }
  guard !entries.isEmpty else {
    let notebook = try await client.longTermMemoryNotebook()
    try requireAccepted(notebook.result)
    return [
      "notebookId": notebook.value.map { .string($0.notebookId.rawValue) } ?? .null,
      "noteIds": .array([]), "notes": .array([]), "entriesWritten": .number(0),
      "idempotentReplay": .bool(false), "idempotencyKey": .string(key), "associations": .array([])
    ]
  }
  let result = try await client.appendLongTermMemory(entries: entries, idempotencyKey: key)
  try requireAccepted(result.result)
  var associations: [JSONValue] = []
  if !result.idempotentReplay, values.bool("autoAssociate", default: true) {
    let limit = bounded(values.int("associationLimit", default: 8), upper: 20)
    for note in result.notes {
      let links = try await client.linkLongTermMemoryAssociations(noteId: note.noteId, limit: limit)
      try requireAccepted(links.result)
      associations.append(.object([
        "noteId": .string(note.noteId.rawValue),
        "linkedNoteIds": .array((links.value ?? []).map { .string($0.toNoteId.rawValue) })
      ]))
    }
  }
  let notebookID = result.notes.first?.notebookId.rawValue
  return [
    "notebookId": notebookID.map(JSONValue.string) ?? .null,
    "noteIds": .array(result.notes.map { .string($0.noteId.rawValue) }),
    "notes": .array(result.notes.map(kaibaNoteJSON)),
    "entriesWritten": .number(Double(result.notes.count)),
    "idempotentReplay": .bool(result.idempotentReplay),
    "idempotencyKey": .string(key), "associations": .array(associations)
  ]
}

private func recallLongTermMemory(values: KaibaAddonInputs, client: KaibaClient) async throws -> JSONObject {
  let query = try values.requiredString(["query", "match"], fieldName: "query")
  let limit = bounded(values.int("limit", default: 10), upper: 20)
  let includeAssociations = values.bool("includeAssociations", default: true)
  let depth = bounded(values.int("associationDepth", default: 2), upper: 8)
  let result = try await client.recallLongTermMemory(
    query: query,
    limit: limit,
    includeAssociations: includeAssociations,
    associationDepth: depth,
    recencyWeight: values.value("recencyWeight")?.asDouble ?? 0.5
  )
  try requireAccepted(result.result)
  let hits = result.value ?? []
  return [
    "query": .string(query), "limit": .number(Double(limit)),
    "includeAssociations": .bool(includeAssociations), "associationDepth": .number(Double(depth)),
    "results": .array(hits.map(memoryRecallJSON)),
    "resultCount": .number(Double(hits.count)),
    "noteIds": .array(hits.map { .string($0.note.noteId.rawValue) }),
    "recallText": .string(memoryRecallText(hits))
  ]
}

private func memoryEntries(_ value: JSONValue?) throws -> [KaibaLongTermMemoryEntry] {
  guard let value else { return [] }
  guard case let .array(entries) = value else { throw noteAddonInvalidInput("entries must be an array") }
  return try entries.enumerated().map { index, value in
    guard case let .object(entry) = value,
          let body = entry["content"].flatMap(nonEmptyString) ?? entry["bodyMarkdown"].flatMap(nonEmptyString) else {
      throw noteAddonInvalidInput("entries[\(index)].content is required")
    }
    let recordIDs = memoryRecordIDs(entry["sourceMemoryRecordIds"])
    let metaJSON = recordIDs.isEmpty ? entry["metaJSON"].flatMap(nonEmptyString) : JSONValue.object([
      "sourceMemoryRecordIds": .array(recordIDs)
    ]).compactJSONStringOrEmpty()
    return .init(
      bodyMarkdown: body,
      topicTags: try stringArray(entry["topicTags"], field: "topicTags"),
      relatedNoteIds: try stringArray(entry["relatedNoteIds"], field: "relatedNoteIds").map(KaibaNoteID.init(rawValue:)),
      periodStart: entry["periodStart"].flatMap(nonEmptyString),
      periodEnd: entry["periodEnd"].flatMap(nonEmptyString),
      metaJSON: metaJSON
    )
  }
}

private func memoryRecordIDs(_ value: JSONValue?) -> [JSONValue] {
  guard let value else { return [] }
  switch value {
  case let .array(values): return values.filter(memoryRecordID)
  case .integer, .number, .string: return memoryRecordID(value) ? [value] : []
  case .null, .bool, .object: return []
  }
}

private func memoryRecordID(_ value: JSONValue) -> Bool {
  switch value {
  case let .string(value): return !value.isEmpty
  case .integer, .number: return true
  case .null, .bool, .array, .object: return false
  }
}

private func memoryRecallJSON(_ hit: KaibaLongTermMemoryRecallHit) -> JSONValue {
  .object([
    "noteId": .string(hit.note.noteId.rawValue), "notebookId": .string(hit.note.notebookId.rawValue),
    "title": hit.note.title.map(JSONValue.string) ?? .null,
    "bodyMarkdown": .string(hit.note.bodyMarkdown), "snippet": .string(hit.snippet),
    "rank": .number(hit.rank), "isAssociation": .bool(hit.isAssociation),
    "edgeKind": hit.edgeKind.map(JSONValue.string) ?? .null,
    "weight": hit.weight.map(JSONValue.number) ?? .null,
    "hopCount": hit.hopCount.map { .number(Double($0)) } ?? .null,
    "pathNoteIds": .array(hit.pathNoteIds.map { .string($0.rawValue) }),
    "createdAt": .string(hit.note.createdAt), "metaJSON": hit.note.metaJSON.map(JSONValue.string) ?? .null
  ])
}

private func memoryRecallText(_ hits: [KaibaLongTermMemoryRecallHit]) -> String {
  hits.map { hit in
    let relation = hit.isAssociation ? (hit.edgeKind ?? "association") : "direct"
    let title = hit.note.title ?? firstLine(hit.note.bodyMarkdown)
    let body = hit.snippet.isEmpty ? hit.note.bodyMarkdown : hit.snippet
    return "#\(hit.note.noteId.rawValue) [\(relation)] \(title): \(truncatedRecallText(body))"
  }.joined(separator: "\n")
}

private func firstLine(_ body: String) -> String {
  let line = body.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
  return line.isEmpty ? "(untitled)" : line
}

private func truncatedRecallText(_ value: String) -> String {
  let collapsed = value.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
  return collapsed.count > 600 ? String(collapsed.prefix(600)) + "…" : collapsed
}
