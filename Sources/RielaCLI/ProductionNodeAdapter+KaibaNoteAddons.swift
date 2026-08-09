import Foundation
import RielaCore
import AppCore


private let noteAddonDefaultMaxAttachmentBytes = InlineWorkflowAddonAttachmentProjector.maxAttachmentBytes
private let noteAddonDefaultMaxPageCount = 500
extension BuiltinWorkflowAddonResolver {
  func executeNoteAddon(
    _ input: WorkflowAddonExecutionInput,
    operation: BuiltinNoteAddon
  ) async throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(.policyBlocked, "unsupported \(input.addon.name) version '\(input.addon.version ?? "")'")
    }
    let context = try NoteAddonContext(input: input, environment: environment)
    let candidate: JSONObject
    switch operation {
    case .create:
      candidate = try createNote(context)
    case .update:
      candidate = try updateNote(context)
    case .get:
      candidate = try getNote(context)
    case .search:
      candidate = try searchNotes(context)
    case .graphNeighbors:
      candidate = try graphNeighbors(context)
    case .tagApply:
      candidate = try applyNoteTags(context)
    case .attachFile:
      candidate = try attachNoteFile(context, input: input)
    case .graphQLDocument:
      candidate = try await executeNoteGraphQLDocument(context)
    case .commentAdd:
      candidate = try addNoteComment(context)
    case .notebookIngestPages:
      candidate = try ingestNotebookPages(context)
    case .conversationSave:
      candidate = try saveNoteConversation(context)
    case .kanbanTaskCreate:
      candidate = try kanbanTaskCreate(context)
    case .kanbanMove:
      candidate = try kanbanMove(context)
    case .kanbanBoard:
      candidate = try kanbanBoard(context)
    }

    var payload: JSONObject = [
      "status": .string("ok"),
      "addon": .string(input.addon.name),
      "operation": .string(operation.rawValue.replacingOccurrences(of: "kaiba/note-", with: "")
        .replacingOccurrences(of: "riela/notebook-", with: "notebook-")),
      "stepId": .string(input.stepId),
      "noteRoot": .string(context.noteRoot),
      "databasePath": .string(context.service.driver.databasePath)
    ]
    for (key, value) in candidate {
      payload[key] = value
    }
    let when: [String: Bool] = ["always": true]
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
struct NoteAddonContext {
  var input: WorkflowAddonExecutionInput
  var config: JSONObject
  var variables: JSONObject
  var noteRoot: String
  var service: NoteService
  var environment: [String: String]
  var maxAttachmentBytes: Int {
    max(0, int("maxAttachmentBytes", default: noteAddonDefaultMaxAttachmentBytes))
  }
  var maxPageCount: Int {
    max(1, int("maxPageCount", default: noteAddonDefaultMaxPageCount))
  }
  var localFileRoot: URL {
    let rawRoot = string("localFileRoot", "workingDirectory") ?? FileManager.default.currentDirectoryPath
    return URL(fileURLWithPath: rawRoot, isDirectory: true).standardizedFileURL
  }
  var allowsLocalFileReferencesOutsideRoot: Bool {
    bool("allowLocalFileReferencesOutsideWorkingDirectory", default: false)
  }

  init(input: WorkflowAddonExecutionInput, environment: [String: String]) throws {
    self.input = input
    self.environment = environment
    config = input.addon.config ?? [:]
    variables = addonVariables(for: input)
    let workflowInput = noteObject(variables["workflowInput"])
    noteRoot = noteString("noteRoot", config: config, variables: variables)
      ?? nonEmptyString(workflowInput["noteRoot"])
      ?? environment["KAIBA_NOTE_ROOT"].flatMap { $0.isEmpty ? nil : $0 }
      ?? environment["RIELA_NOTE_ROOT"].flatMap { $0.isEmpty ? nil : $0 }
      ?? "\(NSHomeDirectory())/.kaiba"
    noteRoot = (noteRoot as NSString).expandingTildeInPath
    // Kaiba owns the note store; riela does not dispatch auto-action
    // workflows here. Pending auto-action rows accumulate only for actions
    // the user explicitly enabled in kaiba.
    service = try NoteService(
      driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot)
    )
  }

  func string(_ keys: String...) -> String? {
    for key in keys {
      if let value = noteString(key, config: config, variables: variables) {
        return value
      }
    }
    return nil
  }

  func requiredString(_ keys: String..., fieldName: String) throws -> String {
    for key in keys {
      if let value = string(key) {
        return value
      }
    }
    throw noteAddonInvalidInput("\(input.addon.name) \(fieldName) is required")
  }

  func bool(_ key: String, default defaultValue: Bool) -> Bool {
    boolValue(config[key]) ?? boolValue(variables[key]) ?? defaultValue
  }

  func int(_ key: String, default defaultValue: Int) -> Int {
    noteIntValue(config[key], variables: variables)
      ?? noteIntValue(variables[key], variables: variables)
      ?? defaultValue
  }

  func value(_ key: String) -> JSONValue? {
    config[key] ?? variables[key]
  }
}

private func createNote(_ context: NoteAddonContext) throws -> JSONObject {
  let bodyMarkdown = try context.requiredString("bodyMarkdown", "body", "markdown", "text", fieldName: "bodyMarkdown")
  let notebookId = context.string("notebookId")
  let notebookKindTag = context.string("notebookKindTag", "kindTagName")
  let effectiveNotebookId: String?
  if notebookId == nil, let notebookKindTag {
    let notebook = try context.service.createNotebook(
      title: context.string("notebookTitle", "title") ?? noteTitleFallback(from: bodyMarkdown),
      kindTagName: notebookKindTag,
      metaJSON: noteMetaJSONString(context.value("notebookMeta"), context.value("notebookMetaJSON")),
      originatingActionId: context.string("originatingActionId", "actionId")
    )
    effectiveNotebookId = notebook.notebookId
  } else {
    effectiveNotebookId = notebookId
  }
  let note = try context.service.createNote(
    notebookId: effectiveNotebookId,
    notebookTitle: context.string("notebookTitle"),
    bodyMarkdown: bodyMarkdown,
    readOnly: context.bool("readOnly", default: false),
    tags: try noteTags(context.value("tags")),
    provenance: noteProvenance(context.string("provenance")) ?? .human,
    assignedBy: context.string("assignedBy"),
    metaJSON: noteMetaJSONString(context.value("meta"), context.value("metaJSON")),
    originatingActionId: context.string("originatingActionId", "actionId")
  )
  return [
    "noteId": .string(note.noteId),
    "notebookId": .string(note.notebookId),
    "note": noteJSON(note)
  ]
}

private func updateNote(_ context: NoteAddonContext) throws -> JSONObject {
  // kaiba/note-update re-derives the stored title from the new body.
  let note = try context.service.updateNoteBody(
    noteId: try context.requiredString("noteId", fieldName: "noteId"),
    bodyMarkdown: try context.requiredString("bodyMarkdown", "body", "markdown", "text", fieldName: "bodyMarkdown"),
    originatingActionId: context.string("originatingActionId", "actionId")
  )
  return [
    "noteId": .string(note.noteId),
    "notebookId": .string(note.notebookId),
    "note": noteJSON(note)
  ]
}

private func getNote(_ context: NoteAddonContext) throws -> JSONObject {
  // An explicit noteId keeps the original single-note response shape even when
  // upstream inputs (e.g. a forwarded kaiba/note-search payload) also carry a
  // top-level noteIds array; the batch shape applies only when no noteId is
  // addressed. Batch ids are deduplicated and capped so a hostile or buggy
  // workflow cannot drive unbounded sequential getNote round-trips.
  if context.string("noteId") == nil, let rawNoteIds = context.value("noteIds") {
    let requestedNoteIds = try noteStringArray(rawNoteIds, fieldName: "note noteIds") ?? []
    let noteIds = Array(orderedUniqueNoteIds(requestedNoteIds).prefix(NoteGraphPolicy.maximumSeedCount))
    let notes = try noteIds.map(context.service.getNote)
    var payload: JSONObject = [
      "notes": .array(notes.map(noteJSON)),
      "noteIds": .array(notes.map { .string($0.noteId) })
    ]
    if let graphEvidence = context.value("graphEvidence") {
      payload["graphEvidence"] = graphEvidence
    }
    return payload
  }
  let note = try context.service.getNote(try context.requiredString("noteId", fieldName: "noteId"))
  return [
    "noteId": .string(note.noteId),
    "notebookId": .string(note.notebookId),
    "note": noteJSON(note),
    "comments": .array(try context.service.listComments(noteId: note.noteId).map(noteCommentJSON)),
    "links": .array(try context.service.listLinks(noteId: note.noteId).map(noteLinkJSON)),
    "files": .array(try context.service.listFiles(noteId: note.noteId).map(noteFileAttachmentJSON))
  ]
}

private func searchNotes(_ context: NoteAddonContext) throws -> JSONObject {
  let includeLinked = context.bool("includeLinked", default: false)
  let results = try context.service.searchNotes(
    query: try context.requiredString("query", "match", fieldName: "query"),
    tagFilter: try noteStringArray(context.value("tagFilter") ?? context.value("tags"), fieldName: "note tagFilter") ?? [],
    classFilter: try noteStringArray(context.value("classFilter"), fieldName: "note classFilter") ?? [],
    includeLinked: includeLinked,
    depth: context.int("depth", default: 1),
    limit: context.int("limit", default: 20)
  )
  return [
    "results": .array(results.map(noteSearchResultJSON)),
    "resultCount": .number(Double(results.count)),
    "noteIds": .array(results.map { .string($0.note.noteId) })
  ]
}

private func graphNeighbors(_ context: NoteAddonContext) throws -> JSONObject {
  guard let rawNoteIds = context.value("noteIds") ?? context.value("noteId") else {
    throw noteAddonInvalidInput("\(context.input.addon.name) noteIds is required")
  }
  let requestedNoteIds = try noteStringArray(rawNoteIds, fieldName: "note noteIds") ?? []
  // Clamp to the service's 20-seed cap instead of surfacing invalidInput:
  // upstream nodes (e.g. kaiba/note-search with a caller-controlled limit) may
  // legitimately hand over more ids, and the search-side expansion path clamps
  // the same way (appendLinkedNeighborResults / prefix(maximumSeedCount)).
  let noteIds = Array(orderedUniqueNoteIds(requestedNoteIds).prefix(NoteGraphPolicy.maximumSeedCount))
  let results = try context.service.graphNeighbors(
    noteIds: noteIds,
    maxDepth: context.int("depth", default: NoteGraphPolicy.defaultMaxDepth),
    limit: context.int("limit", default: NoteGraphPolicy.defaultLimit)
  )
  return [
    "results": .array(results.map(noteGraphNeighborJSON)),
    "resultCount": .number(Double(results.count)),
    "noteIds": .array(results.map { .string($0.note.noteId) }),
    "seedNoteIds": .array(noteIds.map(JSONValue.string)),
    "retrievalNoteIds": .array(orderedUniqueNoteIds(noteIds + results.map(\.note.noteId)).map(JSONValue.string))
  ]
}

private func orderedUniqueNoteIds(_ noteIds: [String]) -> [String] {
  var seen = Set<String>()
  return noteIds.filter { seen.insert($0).inserted }
}

private func applyNoteTags(_ context: NoteAddonContext) throws -> JSONObject {
  let note = try context.service.applyTags(
    noteId: try context.requiredString("noteId", fieldName: "noteId"),
    tags: try noteTagsRequired(context.value("tags") ?? context.value("tag")),
    provenance: .ai,
    assignedBy: noteAddonWorkflowActor(context)
  )
  return [
    "noteId": .string(note.noteId),
    "notebookId": .string(note.notebookId),
    "note": noteJSON(note),
    "tags": .array(note.tags.map(tagAssignmentJSON))
  ]
}

private func attachNoteFile(
  _ context: NoteAddonContext,
  input: WorkflowAddonExecutionInput
) throws -> JSONObject {
  let attachment = try noteAttachmentData(context: context, input: input)
  let stored = try context.service.attachFile(
    noteId: try context.requiredString("noteId", fieldName: "noteId"),
    data: attachment.data,
    role: noteFileRole(context.string("role")) ?? .related,
    mediaType: attachment.mediaType,
    originalFilename: attachment.filename,
    position: context.int("position", default: 0)
  )
  return [
    "noteId": .string(stored.noteId),
    "fileId": .string(stored.file.fileId),
    "file": noteFileAttachmentJSON(stored)
  ]
}


private func addNoteComment(_ context: NoteAddonContext) throws -> JSONObject {
  let comment = try context.service.addComment(
    noteId: try context.requiredString("noteId", fieldName: "noteId"),
    bodyMarkdown: try context.requiredString("bodyMarkdown", "body", "comment", "text", fieldName: "bodyMarkdown"),
    author: context.string("author", "assignedBy") ?? "user"
  )
  return [
    "noteId": .string(comment.noteId),
    "commentId": .string(comment.commentId),
    "comment": noteCommentJSON(comment)
  ]
}

private func ingestNotebookPages(_ context: NoteAddonContext) throws -> JSONObject {
  let sourceDocumentRef = context.string("sourceDocumentRef")
  let pages = try notePageInputs(context)
  let result = try context.service.createNotebookWithNotes(
    title: context.string("notebookTitle", "title") ?? sourceDocumentRef ?? "Imported Material",
    kindTagName: context.string("notebookKindTag", "kindTagName") ?? "notebook-kind:imported-material",
    metaJSON: notebookIngestMetaJSON(context: context, sourceDocumentRef: sourceDocumentRef),
    pages: pages.map { page in
      NotePageDraft(
        bodyMarkdown: page.bodyMarkdown,
        readOnly: false,
        tags: page.tags,
        metaJSON: pageMetaJSON(page),
        noteNumber: page.number
      )
    },
    provenance: noteProvenance(context.string("provenance")) ?? .system,
    assignedBy: context.string("assignedBy") ?? "riela-note-ingest",
    originatingActionId: context.string("originatingActionId", "actionId")
  )
  do {
    let sourceDocument = try attachSourceDocument(context: context, notebookId: result.notebook.notebookId)
    let pageImages = try attachPageImages(context: context, pages: pages, notes: result.notes)
    let notes = try applyIngestedPageReadOnlyState(
      pages: pages,
      notes: result.notes,
      service: context.service
    )
    return [
      "notebookId": .string(result.notebook.notebookId),
      "notebook": notebookJSON(result.notebook),
      "notes": .array(notes.map(noteJSON)),
      "noteIds": .array(notes.map { JSONValue.string($0.noteId) }),
      "pageCount": .number(Double(notes.count)),
      "sourceDocument": sourceDocument.map(notebookFileAttachmentJSON) ?? .null,
      "pageImages": .array(pageImages.map(noteFileAttachmentJSON))
    ]
  } catch let ingestionError {
    do {
      _ = try applyIngestedPageReadOnlyState(pages: pages, notes: result.notes, service: context.service)
    } catch {
      throw noteAddonInvalidInput(
        "notebook ingestion failed and page read-only recovery failed: \(ingestionError); \(error)"
      )
    }
    throw ingestionError
  }
}

private func saveNoteConversation(_ context: NoteAddonContext) throws -> JSONObject {
  let saved = try context.service.saveConversation(
    title: try context.requiredString("title", "conversationTitle", fieldName: "title"),
    transcript: try noteConversationTurns(context),
    assignedBy: context.string("assignedBy"),
    originatingActionId: context.string("originatingActionId", "actionId")
  )
  return [
    "notebookId": .string(saved.notebook.notebookId),
    "notebook": notebookJSON(saved.notebook),
    "notes": .array(saved.notes.map(noteJSON)),
    "noteIds": .array(saved.notes.map { .string($0.noteId) })
  ]
}

private func attachSourceDocument(
  context: NoteAddonContext,
  notebookId: String
) throws -> NotebookFileAttachment? {
  guard let sourceDocumentRef = context.string("sourceDocumentRef") else {
    return nil
  }
  let attachment = try sourceAttachmentInput(ref: sourceDocumentRef, context: context)
  guard let attachment else {
    return nil
  }
  switch attachment {
  case let .inline(data):
    return try context.service.attachNotebookFile(
      notebookId: notebookId,
      data: data.data,
      role: .sourceDocument,
      mediaType: data.mediaType,
      originalFilename: data.filename
    )
  case let .localFile(url, mediaType, filename):
    return try context.service.attachNotebookFile(
      notebookId: notebookId,
      fileURL: url,
      role: .sourceDocument,
      mediaType: mediaType,
      originalFilename: filename
    )
  }
}

private func attachPageImages(
  context: NoteAddonContext,
  pages: [NotePageInput],
  notes: [Note]
) throws -> [NoteFileAttachment] {
  var attachments: [NoteFileAttachment] = []
  for (index, page) in pages.enumerated() {
    guard index < notes.count, let pageImageRef = page.pageImageRef else {
      continue
    }
    guard let attachment = try sourceAttachmentInput(ref: pageImageRef, context: context) else {
      continue
    }
    switch attachment {
    case let .inline(data):
      attachments.append(try context.service.attachFile(
        noteId: notes[index].noteId,
        data: data.data,
        role: .sourcePageImage,
        mediaType: data.mediaType,
        originalFilename: data.filename,
        position: page.number ?? index + 1
      ))
    case let .localFile(url, mediaType, filename):
      attachments.append(try context.service.attachFile(
        noteId: notes[index].noteId,
        fileURL: url,
        role: .sourcePageImage,
        mediaType: mediaType,
        originalFilename: filename,
        position: page.number ?? index + 1
      ))
    }
  }
  return attachments
}

private func noteConversationTurns(_ context: NoteAddonContext) throws -> [NoteConversationTurn] {
  if case let .array(values)? = context.value("transcript") ?? context.value("turns") {
    return try values.enumerated().map { index, value in
      guard case let .object(turn) = value else {
        throw noteAddonInvalidInput("\(context.input.addon.name) transcript[\(index)] must be an object")
      }
      return try noteConversationTurn(turn, path: "transcript[\(index)]")
    }
  }
  return [
    NoteConversationTurn(
      userMarkdown: try context.requiredString("userMarkdown", "user", "request", fieldName: "userMarkdown"),
      assistantMarkdown: try context.requiredString("assistantMarkdown", "assistant", "replyText", "text", fieldName: "assistantMarkdown"),
      sourceNoteIds: try noteStringArray(context.value("sourceNoteIds"), fieldName: "sourceNoteIds") ?? []
    )
  ]
}

private func noteConversationTurn(_ object: JSONObject, path: String) throws -> NoteConversationTurn {
  guard let userMarkdown = nonEmptyString(object["userMarkdown"]) ?? nonEmptyString(object["user"]) else {
    throw noteAddonInvalidInput("\(path).userMarkdown is required")
  }
  guard let assistantMarkdown = nonEmptyString(object["assistantMarkdown"])
    ?? nonEmptyString(object["assistant"])
    ?? nonEmptyString(object["replyText"]) else {
    throw noteAddonInvalidInput("\(path).assistantMarkdown is required")
  }
  return NoteConversationTurn(
    userMarkdown: userMarkdown,
    assistantMarkdown: assistantMarkdown,
    sourceNoteIds: try noteStringArray(object["sourceNoteIds"], fieldName: "\(path).sourceNoteIds") ?? []
  )
}

private func notebookIngestMetaJSON(context: NoteAddonContext, sourceDocumentRef: String?) -> String? {
  if let metaJSON = noteMetaJSONString(context.value("notebookMeta"), context.value("notebookMetaJSON")) {
    return metaJSON
  }
  guard let sourceDocumentRef else {
    return nil
  }
  return JSONValue.object(["sourceDocumentRef": .string(sourceDocumentRef)]).compactJSONStringOrEmpty()
}

private func noteTagsRequired(_ value: JSONValue?) throws -> [NoteTagInput] {
  let tags = try noteTags(value)
  guard !tags.isEmpty else {
    throw noteAddonInvalidInput("note tags must be a non-empty array or string")
  }
  return tags
}

func noteTags(_ value: JSONValue?) throws -> [NoteTagInput] {
  guard let value else {
    return []
  }
  switch value {
  case let .string(name):
    return name.isEmpty ? [] : [NoteTagInput(name: name)]
  case let .array(values):
    return try values.enumerated().compactMap { index, value in
      switch value {
      case let .string(name):
        return name.isEmpty ? nil : NoteTagInput(name: name)
      case let .object(object):
        guard let name = nonEmptyString(object["name"]) ?? nonEmptyString(object["tag"]) else {
          throw noteAddonInvalidInput("note tags[\(index)].name is required")
        }
        return NoteTagInput(name: name, classId: nonEmptyString(object["classId"]) ?? nonEmptyString(object["class"]))
      case .null:
        return nil
      case .bool, .integer, .number, .array:
        throw noteAddonInvalidInput("note tags[\(index)] must be a string or object")
      }
    }
  case .null:
    return []
  case .bool, .integer, .number, .object:
    throw noteAddonInvalidInput("note tags must be an array or string")
  }
}

private func noteStringArray(_ value: JSONValue?, fieldName: String) throws -> [String]? {
  guard let value else {
    return nil
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

func noteGraphQLVariables(_ context: NoteAddonContext) throws -> JSONObject {
  guard let rawVariables = context.value("variables") else {
    return [:]
  }
  let rendered = renderJSONTemplates(rawVariables, variables: context.variables)
  guard case let .object(variables) = rendered else {
    throw noteAddonInvalidInput("\(context.input.addon.name) variables must be an object")
  }
  return variables
}

func noteAddonInvalidInput(_ message: String) -> AdapterExecutionError {
  AdapterExecutionError(.invalidInput, message)
}
private func noteIntValue(_ value: JSONValue?, variables: JSONObject) -> Int? {
  if let int = intValue(value) {
    return int
  }
  guard let template = nonEmptyString(value) else {
    return nil
  }
  let rendered = renderPromptTemplate(template, variables: variables).trimmingCharacters(in: .whitespacesAndNewlines)
  return Int(rendered)
}

private func noteString(_ key: String, config: JSONObject, variables: JSONObject) -> String? {
  if let template = nonEmptyString(config[key]) {
    let rendered = renderPromptTemplate(template, variables: variables).trimmingCharacters(in: .whitespacesAndNewlines)
    return rendered.isEmpty ? nil : rendered
  }
  return nonEmptyString(variables[key])
}

func noteObject(_ value: JSONValue?) -> JSONObject {
  guard case let .object(object)? = value else {
    return [:]
  }
  return object
}

func noteMetaJSONString(_ values: JSONValue?...) -> String? {
  for value in values {
    guard let value else {
      continue
    }
    if let string = nonEmptyString(value) {
      return string
    }
    if case .null = value {
      continue
    }
    return value.compactJSONStringOrEmpty()
  }
  return nil
}

private func noteProvenance(_ value: String?) -> NoteProvenance? {
  value.flatMap(NoteProvenance.init(rawValue:))
}

private func noteAddonWorkflowActor(_ context: NoteAddonContext) -> String {
  "workflow:\(context.input.workflowId)/\(context.input.stepId)"
}

private func noteFileRole(_ value: String?) -> NoteFileRole? {
  value.flatMap(NoteFileRole.init(rawValue:))
}

private func noteTitleFallback(from bodyMarkdown: String) -> String {
  NoteTitleDerivation.fallbackTitle(from: bodyMarkdown)
}

private func notebookJSON(_ notebook: Notebook) -> JSONValue {
  .object([
    "notebookId": .string(notebook.notebookId),
    "title": .string(notebook.title),
    "progress": .string(notebook.progress),
    "createdAt": .string(notebook.createdAt),
    "updatedAt": .string(notebook.updatedAt),
    "metaJSON": notebook.metaJSON.map { .string($0) } ?? .null,
    "tags": .array(notebook.tags.map(tagAssignmentJSON)),
    "firstNotePreview": notebook.firstNotePreview.map { .string($0) } ?? .null,
    "noteCount": notebook.noteCount.map { .number(Double($0)) } ?? .null
  ])
}

func noteJSON(_ note: Note) -> JSONValue {
  .object([
    "noteId": .string(note.noteId),
    "notebookId": .string(note.notebookId),
    "noteNumber": .number(Double(note.noteNumber)),
    "title": note.title.map { .string($0) } ?? .null,
    "bodyMarkdown": .string(note.bodyMarkdown),
    "readOnly": .bool(note.readOnly),
    "createdAt": .string(note.createdAt),
    "updatedAt": .string(note.updatedAt),
    "metaJSON": note.metaJSON.map { .string($0) } ?? .null,
    "tags": .array(note.tags.map(tagAssignmentJSON))
  ])
}

private func noteSearchResultJSON(_ result: NoteSearchResult) -> JSONValue {
  .object([
    "note": noteJSON(result.note),
    "noteId": .string(result.note.noteId),
    "notebookId": .string(result.note.notebookId),
    "snippet": .string(result.snippet),
    "rank": .number(result.rank),
    "matchedTags": .array(result.matchedTags.map(tagJSON)),
    "isLinkedNeighbor": .bool(result.isLinkedNeighbor)
  ])
}

private func noteGraphNeighborJSON(_ result: NoteGraphNeighbor) -> JSONValue {
  .object([
    "seedNoteId": .string(result.seedNoteId),
    "note": noteJSON(result.note),
    "noteId": .string(result.note.noteId),
    "edgeKind": .string(result.edgeKind.rawValue),
    "weight": .number(result.weight),
    "hopCount": .number(Double(result.hopCount)),
    "pathNoteIds": .array(result.pathNoteIds.map(JSONValue.string))
  ])
}

private func tagAssignmentJSON(_ assignment: TagAssignment) -> JSONValue {
  .object([
    "tag": tagJSON(assignment.tag),
    "provenance": .string(assignment.provenance.rawValue),
    "assignedBy": assignment.assignedBy.map { .string($0) } ?? .null,
    "deletable": .bool(assignment.deletable),
    "createdAt": .string(assignment.createdAt)
  ])
}

private func tagJSON(_ tag: Tag) -> JSONValue {
  .object([
    "tagId": .string(tag.tagId),
    "name": .string(tag.name),
    "classId": tag.classId.map { .string($0) } ?? .null,
    "isSystem": .bool(tag.isSystem),
    "createdAt": .string(tag.createdAt)
  ])
}

private func noteCommentJSON(_ comment: NoteComment) -> JSONValue {
  .object([
    "commentId": .string(comment.commentId),
    "noteId": .string(comment.noteId),
    "bodyMarkdown": .string(comment.bodyMarkdown),
    "author": .string(comment.author),
    "createdAt": .string(comment.createdAt)
  ])
}

private func noteLinkJSON(_ link: NoteLink) -> JSONValue {
  .object([
    "fromNoteId": .string(link.fromNoteId),
    "toNoteId": .string(link.toNoteId),
    "linkKind": .string(link.linkKind),
    "provenance": .string(link.provenance.rawValue),
    "createdAt": .string(link.createdAt)
  ])
}

private func noteFileAttachmentJSON(_ attachment: NoteFileAttachment) -> JSONValue {
  .object([
    "noteId": .string(attachment.noteId),
    "role": .string(attachment.role.rawValue),
    "position": .number(Double(attachment.position)),
    "file": fileRecordJSON(attachment.file)
  ])
}

private func notebookFileAttachmentJSON(_ attachment: NotebookFileAttachment) -> JSONValue {
  .object([
    "notebookId": .string(attachment.notebookId),
    "role": .string(attachment.role.rawValue),
    "file": fileRecordJSON(attachment.file)
  ])
}

private func fileRecordJSON(_ file: FileRecord) -> JSONValue {
  .object([
    "fileId": .string(file.fileId),
    "storageKind": .string(file.storageKind.rawValue),
    "localPath": file.localPath.map { .string($0) } ?? .null,
    "s3Profile": file.s3Profile.map { .string($0) } ?? .null,
    "s3Bucket": file.s3Bucket.map { .string($0) } ?? .null,
    "s3Key": file.s3Key.map { .string($0) } ?? .null,
    "mediaType": .string(file.mediaType),
    "byteSize": .number(Double(file.byteSize)),
    "sha256": .string(file.sha256),
    "originalFilename": file.originalFilename.map { .string($0) } ?? .null,
    "createdAt": .string(file.createdAt),
    "migratedAt": file.migratedAt.map { .string($0) } ?? .null
  ])
}

// MARK: - Kanban orchestration add-ons

private func kanbanTaskCreate(_ context: NoteAddonContext) throws -> JSONObject {
  let folderTagPath = try context.requiredString("folderTagName", "folderTag", fieldName: "folderTagName")
  let initialProgress = context.string("initialProgress") ?? "pending"
  let runLabel = context.string("runLabel", "orchestration")
  guard case let .array(rawTasks)? = context.value("tasks"), !rawTasks.isEmpty else {
    throw noteAddonInvalidInput("\(context.input.addon.name) tasks must be a non-empty array")
  }

  // Folder path segments are plain tag names chained through parent_tag_id;
  // the leaf segment scopes the board.
  var parentTagId: String?
  var leafTagId: String?
  var leafTagName = folderTagPath
  for segment in folderTagPath.split(separator: "/").map(String.init) {
    let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { continue }
    let tag = try context.service.defineTag(name: trimmed, classId: "folder", parentTagId: parentTagId)
    parentTagId = tag.tagId
    leafTagId = tag.tagId
    leafTagName = tag.name
  }
  guard let leafTagId else {
    throw noteAddonInvalidInput("\(context.input.addon.name) folderTagName must contain a folder name")
  }

  var existingByTaskKey: [String: Notebook] = [:]
  for notebook in try context.service.listNotebooks(
    limit: 200,
    offset: 0,
    tagFilterIdGroups: [[leafTagId]]
  ) {
    guard notebook.progress != "done",
          let taskKey = kanbanTaskKey(fromMetaJSON: notebook.metaJSON) else {
      continue
    }
    if existingByTaskKey[taskKey] == nil {
      existingByTaskKey[taskKey] = notebook
    }
  }

  var taskRecords: [JSONValue] = []
  for (index, rawTask) in rawTasks.enumerated() {
    guard case let .object(task) = rawTask else {
      throw noteAddonInvalidInput("\(context.input.addon.name) tasks[\(index)] must be an object")
    }
    guard let taskKey = nonEmptyString(task["taskKey"]) else {
      throw noteAddonInvalidInput("\(context.input.addon.name) tasks[\(index)].taskKey is required")
    }
    guard let title = nonEmptyString(task["title"]) else {
      throw noteAddonInvalidInput("\(context.input.addon.name) tasks[\(index)].title is required")
    }
    guard let briefMarkdown = nonEmptyString(task["briefMarkdown"]) else {
      throw noteAddonInvalidInput("\(context.input.addon.name) tasks[\(index)].briefMarkdown is required")
    }
    let acceptanceMarkdown = nonEmptyString(task["acceptanceMarkdown"])

    let notebook: Notebook
    let reused: Bool
    if let existing = existingByTaskKey[taskKey] {
      notebook = existing
      reused = true
    } else {
      var meta: JSONObject = ["kanbanTaskKey": .string(taskKey)]
      if let runLabel {
        meta["orchestration"] = .string(runLabel)
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let metaData = try encoder.encode(JSONValue.object(meta))
      let created = try context.service.createNotebook(
        title: title,
        kindTagName: nil,
        metaJSON: String(data: metaData, encoding: .utf8),
        originatingActionId: nil
      )
      _ = try context.service.applyNotebookTagIds(
        notebookId: created.notebookId,
        tagIds: [leafTagId],
        provenance: .ai,
        assignedBy: context.input.addon.name
      )
      var body = briefMarkdown
      if let acceptanceMarkdown {
        body += "\n\n## Acceptance\n\n" + acceptanceMarkdown
      }
      _ = try context.service.createNote(
        notebookId: created.notebookId,
        bodyMarkdown: body,
        provenance: .ai,
        assignedBy: context.input.addon.name
      )
      notebook = try context.service.setNotebookProgress(
        notebookId: created.notebookId,
        progress: initialProgress
      )
      reused = false
    }
    var record: JSONObject = [
      "taskKey": .string(taskKey),
      "notebookId": .string(notebook.notebookId),
      "title": .string(title),
      "briefMarkdown": .string(briefMarkdown),
      "progress": .string(notebook.progress),
      "reused": .bool(reused)
    ]
    if let acceptanceMarkdown {
      record["acceptanceMarkdown"] = .string(acceptanceMarkdown)
    }
    if case let .object(taskObject) = rawTask {
      for (key, value) in taskObject where record[key] == nil {
        record[key] = value
      }
    }
    taskRecords.append(.object(record))
  }
  return [
    "folderTagId": .string(leafTagId),
    "folderTagName": .string(leafTagName),
    "initialProgress": .string(initialProgress),
    "tasks": .array(taskRecords)
  ]
}

private func kanbanMove(_ context: NoteAddonContext) throws -> JSONObject {
  let notebookId = try context.requiredString("notebookId", fieldName: "notebookId")
  let target = try context.requiredString("to", "progress", fieldName: "to")
  let expectedFrom = context.string("expectedFrom", "expectedProgress")
  let previousProgress = try context.service.getNotebook(notebookId).progress
  do {
    let notebook = try context.service.setNotebookProgress(
      notebookId: notebookId,
      progress: target,
      expectedProgress: expectedFrom
    )
    return [
      "conflict": .bool(false),
      "notebookId": .string(notebookId),
      "progress": .string(notebook.progress),
      "previousProgress": .string(previousProgress),
      "notebook": notebookJSON(notebook)
    ]
  } catch let NoteServiceError.progressConflict(expected, actual) {
    return [
      "conflict": .bool(true),
      "notebookId": .string(notebookId),
      "progress": .string(actual),
      "expectedProgress": .string(expected)
    ]
  }
}

private func kanbanTaskKey(fromMetaJSON metaJSON: String?) -> String? {
  guard let metaJSON,
        let data = metaJSON.data(using: .utf8),
        let value = try? JSONDecoder().decode(JSONValue.self, from: data),
        case let .object(object) = value,
        case let .string(taskKey)? = object["kanbanTaskKey"] else {
    return nil
  }
  return taskKey
}
