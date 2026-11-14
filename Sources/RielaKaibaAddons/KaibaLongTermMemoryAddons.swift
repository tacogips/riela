import AppCore
import Crypto
import Foundation
import RielaAddonSupport
import RielaCore

/// Bridge add-ons between riela's short-term memory (SQLite records under the
/// memory root) and kaiba's long-term memory (the canonical notebook plus its
/// note graph). Short-term record ids are not kaiba notes, so they are carried
/// as metadata rather than as note links.
extension KaibaAddonCatalog {
  static func executeLongTermMemoryAddon(
    _ input: WorkflowAddonExecutionInput,
    environment: [String: String],
    operation: BuiltinKaibaLongTermMemoryAddon
  ) throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(
        .policyBlocked,
        "unsupported \(input.addon.name) version '\(input.addon.version ?? "")'"
      )
    }
    let context = try NoteAddonContext(input: input, environment: environment)
    let candidate: JSONObject
    switch operation {
    case .consolidate:
      candidate = try consolidateLongTermMemory(context)
    case .recall:
      candidate = try recallLongTermMemory(context)
    }

    var payload: JSONObject = [
      "status": .string("ok"),
      "addon": .string(input.addon.name),
      "operation": .string(operation.rawValue.replacingOccurrences(of: "kaiba/", with: "")),
      "stepId": .string(input.stepId),
      "noteRoot": .string(context.noteRoot),
      "databasePath": .string(context.service.driver.databasePath)
    ]
    // Consolidation and recall usually run as consecutive steps, and only the
    // last payload reaches an output projection; `passthrough` lets a workflow
    // carry the earlier step's real values forward instead of restating them.
    for (key, value) in longTermMemoryPassthrough(context) {
      payload[key] = value
    }
    for (key, value) in candidate {
      payload[key] = value
    }
    return AdapterExecutionOutput(
      provider: "riela-builtin-addon",
      model: input.addon.name,
      promptText: "",
      completionPassed: true,
      when: ["always": true],
      payload: payload
    )
  }
}

private let longTermMemoryDefaultAssociationLimit = 8
private let longTermMemoryMaximumAssociationLimit = 20
private let longTermMemoryDefaultRecallLimit = 10
private let longTermMemoryMaximumRecallLimit = 20
private let longTermMemoryRecallTextLimit = 600

private struct LongTermMemoryConsolidationEntry {
  var content: String
  var topicTags: [String]
  var relatedNoteIds: [String]
  var sourceMemoryRecordIds: [JSONValue]
  var periodStart: Date?
  var periodEnd: Date?
}

private func longTermMemoryPassthrough(_ context: NoteAddonContext) -> JSONObject {
  guard let raw = context.config["passthrough"],
        case let .object(rendered) = renderJSONTemplates(raw, variables: context.variables) else {
    return [:]
  }
  return rendered
}

private func consolidateLongTermMemory(_ context: NoteAddonContext) throws -> JSONObject {
  let defaultPeriodStart = try longTermMemoryDate(context.string("periodStart"), fieldName: "periodStart")
  let defaultPeriodEnd = try longTermMemoryDate(context.string("periodEnd"), fieldName: "periodEnd")
  let entries = try longTermMemoryEntries(
    context,
    defaultPeriodStart: defaultPeriodStart,
    defaultPeriodEnd: defaultPeriodEnd
  )
  guard !entries.isEmpty else {
    throw noteAddonInvalidInput(
      "\(context.input.addon.name) requires at least one entry in config.entries or upstream memoryEntries"
    )
  }
  let idempotencyKey = longTermMemoryIdempotencyKey(context)
  let result = try context.service.appendLongTermMemoryNotes(
    entries.map { entry in
      LongTermMemoryEntryInput(
        bodyMarkdown: entry.content,
        topicTags: entry.topicTags,
        // Riela short-term record ids never resolve to kaiba notes, so the
        // provenance they carry belongs in metadata, not in `sourceNoteIds`.
        sourceNoteIds: [],
        relatedNoteIds: entry.relatedNoteIds.map(NoteID.init),
        periodStart: entry.periodStart,
        periodEnd: entry.periodEnd,
        metaJSON: longTermMemoryEntryMetaJSON(entry)
      )
    },
    idempotencyKey: idempotencyKey
  )

  var associations: [JSONValue] = []
  if !result.idempotentReplay, context.bool("autoAssociate", default: true) {
    let associationLimit = max(
      1,
      min(
        context.int("associationLimit", default: longTermMemoryDefaultAssociationLimit),
        longTermMemoryMaximumAssociationLimit
      )
    )
    for note in result.notes {
      let links = try context.service.linkLongTermMemoryAssociations(
        noteId: note.noteId,
        limit: associationLimit
      )
      associations.append(.object([
        "noteId": .string(note.noteId.rawValue),
        "linkedNoteIds": .array(links.map { .string($0.toNoteId.rawValue) })
      ]))
    }
  }

  let notebookId = try result.notes.first?.notebookId
    ?? context.service.longTermMemoryNotebook().notebookId
  return [
    "notebookId": .string(notebookId.rawValue),
    "noteIds": .array(result.notes.map { .string($0.noteId.rawValue) }),
    "notes": .array(result.notes.map(noteJSON)),
    "entriesWritten": .number(Double(result.notes.count)),
    "idempotentReplay": .bool(result.idempotentReplay),
    "idempotencyKey": .string(idempotencyKey),
    "associations": .array(associations)
  ]
}

private func recallLongTermMemory(_ context: NoteAddonContext) throws -> JSONObject {
  let query = try context.requiredString("query", "match", fieldName: "query")
  let limit = max(
    1,
    min(context.int("limit", default: longTermMemoryDefaultRecallLimit), longTermMemoryMaximumRecallLimit)
  )
  let includeAssociations = context.bool("includeAssociations", default: true)
  let associationDepth = max(
    NoteGraphPolicy.associationMaxDepth,
    min(
      context.int("associationDepth", default: NoteGraphPolicy.associationMaxDepth),
      NoteGraphPolicy.maximumDepth
    )
  )
  let results = try context.service.recallLongTermMemories(
    query: query,
    limit: limit,
    includeAssociations: includeAssociations,
    associationDepth: associationDepth
  )
  return [
    "query": .string(query),
    "limit": .number(Double(limit)),
    "includeAssociations": .bool(includeAssociations),
    "associationDepth": .number(Double(associationDepth)),
    "results": .array(results.map(longTermMemoryRecallResultJSON)),
    "resultCount": .number(Double(results.count)),
    "noteIds": .array(results.map { .string($0.note.noteId.rawValue) }),
    "recallText": .string(longTermMemoryRecallText(results))
  ]
}

private func longTermMemoryEntries(
  _ context: NoteAddonContext,
  defaultPeriodStart: Date?,
  defaultPeriodEnd: Date?
) throws -> [LongTermMemoryConsolidationEntry] {
  let rawEntries = context.config["entries"].map { renderJSONTemplates($0, variables: context.variables) }
    ?? context.variables["entries"]
    ?? context.variables["memoryEntries"]
  guard let rawEntries else {
    return []
  }
  guard case let .array(values) = rawEntries else {
    if case .null = rawEntries {
      return []
    }
    throw noteAddonInvalidInput("\(context.input.addon.name) entries must be an array")
  }
  return try values.enumerated().map { index, value in
    guard case let .object(entry) = value else {
      throw noteAddonInvalidInput("\(context.input.addon.name) entries[\(index)] must be an object")
    }
    guard let content = nonEmptyString(entry["content"]) ?? nonEmptyString(entry["bodyMarkdown"]) else {
      throw noteAddonInvalidInput("\(context.input.addon.name) entries[\(index)].content is required")
    }
    return LongTermMemoryConsolidationEntry(
      content: content,
      topicTags: try longTermMemoryStringArray(entry["topicTags"], fieldName: "entries[\(index)].topicTags"),
      relatedNoteIds: try longTermMemoryStringArray(
        entry["relatedNoteIds"],
        fieldName: "entries[\(index)].relatedNoteIds"
      ),
      sourceMemoryRecordIds: longTermMemoryRecordIds(entry["sourceMemoryRecordIds"]),
      periodStart: try longTermMemoryDate(
        nonEmptyString(entry["periodStart"]),
        fieldName: "entries[\(index)].periodStart"
      ) ?? defaultPeriodStart,
      periodEnd: try longTermMemoryDate(
        nonEmptyString(entry["periodEnd"]),
        fieldName: "entries[\(index)].periodEnd"
      ) ?? defaultPeriodEnd
    )
  }
}

private func longTermMemoryEntryMetaJSON(_ entry: LongTermMemoryConsolidationEntry) -> String? {
  guard !entry.sourceMemoryRecordIds.isEmpty else {
    return nil
  }
  return JSONValue.object([
    "sourceMemoryRecordIds": .array(entry.sourceMemoryRecordIds)
  ]).compactJSONStringOrEmpty()
}

/// Short-term record ids arrive as numbers from `riela/memory-load` payloads and
/// as strings from hand-written configs; both are preserved verbatim so the
/// stored provenance still matches the riela memory store.
private func longTermMemoryRecordIds(_ value: JSONValue?) -> [JSONValue] {
  guard let value else {
    return []
  }
  switch value {
  case let .array(values):
    return values.compactMap(longTermMemoryRecordId)
  case .integer, .number, .string:
    return [longTermMemoryRecordId(value)].compactMap { $0 }
  case .null, .bool, .object:
    return []
  }
}

private func longTermMemoryRecordId(_ value: JSONValue) -> JSONValue? {
  switch value {
  case let .integer(number):
    return .integer(number)
  case let .number(number):
    return .number(number)
  case let .string(string):
    return string.isEmpty ? nil : .string(string)
  case .null, .bool, .array, .object:
    return nil
  }
}

private func longTermMemoryStringArray(_ value: JSONValue?, fieldName: String) throws -> [String] {
  guard let value else {
    return []
  }
  switch value {
  case let .string(string):
    return string.isEmpty ? [] : [string]
  case let .array(values):
    return try values.enumerated().map { index, value in
      guard let string = nonEmptyString(value) else {
        throw noteAddonInvalidInput("\(fieldName)[\(index)] must be a non-empty string")
      }
      return string
    }
  case .null:
    return []
  case .bool, .integer, .number, .object:
    throw noteAddonInvalidInput("\(fieldName) must be a string or array of strings")
  }
}

private func longTermMemoryDate(_ value: String?, fieldName: String) throws -> Date? {
  guard let value, !value.isEmpty else {
    return nil
  }
  guard let date = longTermMemoryISO8601Date(value) else {
    throw noteAddonInvalidInput("\(fieldName) must be an ISO8601 timestamp")
  }
  return date
}

private func longTermMemoryISO8601Date(_ value: String) -> Date? {
  let fractional = ISO8601DateFormatter()
  fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  if let date = fractional.date(from: value) {
    return date
  }
  return ISO8601DateFormatter().date(from: value)
}

// One append batch per step execution: the same runtime identity the persona
// memory writer uses, so a session resume or event redelivery replays the
// already-written memories instead of duplicating them. Callers that consolidate
// on a fixed period can pin the batch with an explicit `idempotencyKey`.
private func longTermMemoryIdempotencyKey(_ context: NoteAddonContext) -> String {
  if let configured = context.string("idempotencyKey") {
    return configured
  }
  let rielaInput = noteObject(context.variables["_rielaInput"])
  let latest = noteObject(rielaInput["latest"])
  let workflowExecutionId = nonEmptyString(rielaInput["workflowExecutionId"])
    ?? nonEmptyString(latest["workflowExecutionId"])
    ?? nonEmptyString(context.variables["workflowExecutionId"])
    ?? context.input.workflowId
  let sourceExecutionId = nonEmptyString(rielaInput["sourceStepExecutionId"])
    ?? nonEmptyString(latest["sourceStepExecutionId"])
    ?? nonEmptyString(rielaInput["communicationId"])
    ?? nonEmptyString(latest["communicationId"])
    ?? context.input.stepId
  let key = [
    workflowExecutionId,
    context.input.workflowId,
    context.input.stepId,
    context.input.nodeId,
    sourceExecutionId
  ].joined(separator: ":")
  let digest = SHA256.hash(data: Data(key.utf8))
  return "riela-consolidate-" + digest.map { String(format: "%02x", $0) }.joined().prefix(32)
}

private func longTermMemoryRecallResultJSON(_ result: LongTermMemoryRecallResult) -> JSONValue {
  .object([
    "noteId": .string(result.note.noteId.rawValue),
    "notebookId": .string(result.note.notebookId.rawValue),
    "title": result.note.title.map { .string($0) } ?? .null,
    "bodyMarkdown": .string(result.note.bodyMarkdown),
    "snippet": .string(result.snippet),
    "rank": .number(result.rank),
    "isAssociation": .bool(result.isAssociation),
    "edgeKind": result.edgeKind.map { .string($0.rawValue) } ?? .null,
    "weight": result.weight.map { .number($0) } ?? .null,
    "hopCount": result.hopCount.map { .number(Double($0)) } ?? .null,
    "pathNoteIds": .array(result.pathNoteIds.map { .string($0.rawValue) }),
    "createdAt": .string(result.note.createdAt),
    "metaJSON": result.note.metaJSON.map { .string($0) } ?? .null
  ])
}

private func longTermMemoryRecallText(_ results: [LongTermMemoryRecallResult]) -> String {
  results.map { result in
    let edge = result.isAssociation ? (result.edgeKind?.rawValue ?? "association") : "direct"
    let title = result.note.title ?? longTermMemoryFirstLine(result.note.bodyMarkdown)
    let body = result.snippet.isEmpty ? result.note.bodyMarkdown : result.snippet
    return "#\(result.note.noteId) [\(edge)] \(title): \(longTermMemoryTruncated(body))"
  }.joined(separator: "\n")
}

private func longTermMemoryFirstLine(_ bodyMarkdown: String) -> String {
  let line = bodyMarkdown
    .split(separator: "\n", omittingEmptySubsequences: true)
    .first
    .map(String.init)?
    .trimmingCharacters(in: .whitespaces) ?? ""
  return line.isEmpty ? "(untitled)" : line
}

private func longTermMemoryTruncated(_ value: String) -> String {
  let collapsed = value
    .replacingOccurrences(of: "\n", with: " ")
    .trimmingCharacters(in: .whitespacesAndNewlines)
  guard collapsed.count > longTermMemoryRecallTextLimit else {
    return collapsed
  }
  return String(collapsed.prefix(longTermMemoryRecallTextLimit)) + "…"
}
