import AppCore
import Foundation
import RielaAddonSupport
import RielaCore

private let noteAddonDefaultMaxAttachmentBytes = InlineWorkflowAddonAttachmentProjector.maxAttachmentBytes
private let noteAddonDefaultMaxPageCount = 500
extension KaibaAddonCatalog {
  static func executeNoteAddon(
    _ input: WorkflowAddonExecutionInput,
    environment: [String: String],
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
    case .tagSearch:
      candidate = try searchNotesByTag(context)
    case .graphNeighbors:
      candidate = try graphNeighbors(context)
    case .chain:
      candidate = try noteChain(context)
    case .tagApply:
      candidate = try applyNoteTags(context)
    case .attachFile:
      candidate = try attachNoteFile(context, input: input)
    case .attachments:
      candidate = try noteAttachments(context)
    case .memos:
      candidate = try noteMemos(context)
    case .graphQLDocument:
      candidate = try await executeNoteGraphQLDocument(context)
    case .commentAdd:
      candidate = try addNoteComment(context)
    case .notebookIngestPages:
      candidate = try ingestNotebookPages(context)
    case .documentImport:
      candidate = try await importKaibaDocument(context)
    case .conversationSave:
      candidate = try saveNoteConversation(context)
    }

    var payload: JSONObject = [
      "status": .string("ok"),
      "addon": .string(input.addon.name),
      "operation": .string(operation.outputName),
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
  var inputs: KaibaAddonInputs
  var noteRoot: String
  var service: NoteService
  var kaibaConfiguration: KaibaConfiguration
  var config: JSONObject { inputs.config }
  var variables: JSONObject { inputs.variables }
  var environment: [String: String] { inputs.environment }
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
    inputs = KaibaAddonInputs(input: input, environment: environment)
    let config = inputs.config
    let variables = inputs.variables
    let workflowInput = noteObject(variables["workflowInput"])
    noteRoot = noteString("noteRoot", config: config, variables: variables)
      ?? nonEmptyString(workflowInput["noteRoot"])
      ?? environment["KAIBA_NOTE_ROOT"].flatMap { $0.isEmpty ? nil : $0 }
      ?? environment["RIELA_NOTE_ROOT"].flatMap { $0.isEmpty ? nil : $0 }
      ?? "\(NSHomeDirectory())/.kaiba"
    noteRoot = (noteRoot as NSString).expandingTildeInPath
    let configuredPath = noteString("configPath", config: config, variables: variables)
      ?? environment["KAIBA_CONFIG_PATH"].flatMap { $0.isEmpty ? nil : $0 }
    if let configuredPath {
      kaibaConfiguration = try KaibaConfigurationLoader.load(
        at: (configuredPath as NSString).expandingTildeInPath,
        required: true
      )
    } else {
      kaibaConfiguration = KaibaConfiguration()
    }
    let driver = try KaibaConfigurationLoader.makeDriver(
      configuration: kaibaConfiguration.database,
      noteRoot: noteRoot,
      environment: environment
    )
    // Kaiba owns the note store; riela does not dispatch auto-action
    // workflows here. Pending auto-action rows accumulate only for actions
    // the user explicitly enabled in kaiba.
    service = try NoteService(driver: driver)
  }

  func string(_ keys: String...) -> String? {
    inputs.string(keys)
  }

  func requiredString(_ keys: String..., fieldName: String) throws -> String {
    try inputs.requiredString(keys, fieldName: fieldName)
  }

  func bool(_ key: String, default defaultValue: Bool) -> Bool {
    inputs.bool(key, default: defaultValue)
  }

  func int(_ key: String, default defaultValue: Int) -> Int {
    inputs.int(key, default: defaultValue)
  }

  func value(_ key: String) -> JSONValue? {
    inputs.value(key)
  }
}

private func createNote(_ context: NoteAddonContext) throws -> JSONObject {
  let bodyMarkdown = try context.requiredString("bodyMarkdown", "body", "markdown", "text", fieldName: "bodyMarkdown")
  let notebookId = context.string("notebookId")
  let notebookKindTag = context.string("notebookKindTag", "kindTagName")
  let effectiveNotebookId: NotebookID?
  if notebookId == nil, let notebookKindTag {
    let notebook = try context.service.createNotebook(
      title: context.string("notebookTitle", "title") ?? noteTitleFallback(from: bodyMarkdown),
      kindTagName: notebookKindTag,
      metaJSON: noteMetaJSONString(context.value("notebookMeta"), context.value("notebookMetaJSON")),
      originatingActionId: context.string("originatingActionId", "actionId").map(AutoActionID.init)
    )
    effectiveNotebookId = notebook.notebookId
  } else {
    effectiveNotebookId = notebookId.map(NotebookID.init)
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
    originatingActionId: context.string("originatingActionId", "actionId").map(AutoActionID.init)
  )
  return [
    "noteId": .string(note.noteId.rawValue),
    "notebookId": .string(note.notebookId.rawValue),
    "note": noteJSON(note)
  ]
}

private func updateNote(_ context: NoteAddonContext) throws -> JSONObject {
  // kaiba/note-update re-derives the stored title from the new body.
  let note = try context.service.updateNoteBody(
    noteId: NoteID(try context.requiredString("noteId", fieldName: "noteId")),
    bodyMarkdown: try context.requiredString("bodyMarkdown", "body", "markdown", "text", fieldName: "bodyMarkdown"),
    originatingActionId: context.string("originatingActionId", "actionId").map(AutoActionID.init)
  )
  return [
    "noteId": .string(note.noteId.rawValue),
    "notebookId": .string(note.notebookId.rawValue),
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
    let noteIds = orderedUniqueNoteIds(requestedNoteIds)
      .prefix(NoteGraphPolicy.maximumSeedCount)
      .map(NoteID.init)
    let notes = try noteIds.map(context.service.getNote)
    var payload: JSONObject = [
      "notes": .array(notes.map(noteJSON)),
      "noteIds": .array(notes.map { .string($0.noteId.rawValue) })
    ]
    if let graphEvidence = context.value("graphEvidence") {
      payload["graphEvidence"] = graphEvidence
    }
    return payload
  }
  let note = try context.service.getNote(NoteID(try context.requiredString("noteId", fieldName: "noteId")))
  return [
    "noteId": .string(note.noteId.rawValue),
    "notebookId": .string(note.notebookId.rawValue),
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
    "noteIds": .array(results.map { .string($0.note.noteId.rawValue) })
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
  let noteIds = orderedUniqueNoteIds(requestedNoteIds)
    .prefix(NoteGraphPolicy.maximumSeedCount)
    .map(NoteID.init)
  let results = try context.service.graphNeighbors(
    noteIds: noteIds,
    maxDepth: context.int("depth", default: NoteGraphPolicy.defaultMaxDepth),
    limit: context.int("limit", default: NoteGraphPolicy.defaultLimit)
  )
  return [
    "results": .array(results.map(noteGraphNeighborJSON)),
    "resultCount": .number(Double(results.count)),
    "noteIds": .array(results.map { .string($0.note.noteId.rawValue) }),
    "seedNoteIds": .array(noteIds.map { .string($0.rawValue) }),
    "retrievalNoteIds": .array(
      orderedUniqueNoteIds(noteIds + results.map(\.note.noteId)).map { .string($0.rawValue) }
    )
  ]
}

// Generic over the id type: the payload side still carries raw strings while
// the kaiba side is typed, and both spellings need the same order-preserving
// deduplication.
private func orderedUniqueNoteIds<ID: Hashable>(_ noteIds: [ID]) -> [ID] {
  var seen = Set<ID>()
  return noteIds.filter { seen.insert($0).inserted }
}

private func applyNoteTags(_ context: NoteAddonContext) throws -> JSONObject {
  let note = try context.service.applyTags(
    noteId: NoteID(try context.requiredString("noteId", fieldName: "noteId")),
    tags: try noteTagsRequired(context.value("tags") ?? context.value("tag")),
    provenance: .ai,
    assignedBy: noteAddonWorkflowActor(context)
  )
  return [
    "noteId": .string(note.noteId.rawValue),
    "notebookId": .string(note.notebookId.rawValue),
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
    noteId: NoteID(try context.requiredString("noteId", fieldName: "noteId")),
    data: attachment.data,
    role: noteFileRole(context.string("role")) ?? .related,
    mediaType: attachment.mediaType,
    originalFilename: attachment.filename,
    position: context.int("position", default: 0)
  )
  return [
    "noteId": .string(stored.noteId.rawValue),
    "fileId": .string(stored.file.fileId.rawValue),
    "file": noteFileAttachmentJSON(stored)
  ]
}

private func addNoteComment(_ context: NoteAddonContext) throws -> JSONObject {
  let noteId = NoteID(try context.requiredString("noteId", fieldName: "noteId"))
  let comment = try context.service.addComment(
    noteId: noteId,
    bodyMarkdown: try context.requiredString("bodyMarkdown", "body", "comment", "text", fieldName: "bodyMarkdown"),
    author: context.string("author", "assignedBy") ?? "user"
  )
  return [
    "noteId": .string((comment.noteId ?? noteId).rawValue),
    "commentId": .string(comment.commentId.rawValue),
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
    originatingActionId: context.string("originatingActionId", "actionId").map(AutoActionID.init)
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
      "notebookId": .string(result.notebook.notebookId.rawValue),
      "notebook": notebookJSON(result.notebook),
      "notes": .array(notes.map(noteJSON)),
      "noteIds": .array(notes.map { JSONValue.string($0.noteId.rawValue) }),
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
    originatingActionId: context.string("originatingActionId", "actionId").map(AutoActionID.init)
  )
  return [
    "notebookId": .string(saved.notebook.notebookId.rawValue),
    "notebook": notebookJSON(saved.notebook),
    "notes": .array(saved.notes.map(noteJSON)),
    "noteIds": .array(saved.notes.map { .string($0.noteId.rawValue) })
  ]
}

private func attachSourceDocument(
  context: NoteAddonContext,
  notebookId: NotebookID
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
      sourceNoteIds: (try noteStringArray(context.value("sourceNoteIds"), fieldName: "sourceNoteIds") ?? [])
        .map(NoteID.init)
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
    sourceNoteIds: (try noteStringArray(object["sourceNoteIds"], fieldName: "\(path).sourceNoteIds") ?? [])
      .map(NoteID.init)
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
        return NoteTagInput(
          name: name,
          classId: (nonEmptyString(object["classId"]) ?? nonEmptyString(object["class"]))
            .map(TagClassID.init)
        )
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
func noteIntValue(_ value: JSONValue?, variables: JSONObject) -> Int? {
  if let int = intValue(value) {
    return int
  }
  guard let template = nonEmptyString(value) else {
    return nil
  }
  let rendered = renderPromptTemplate(template, variables: variables).trimmingCharacters(in: .whitespacesAndNewlines)
  return Int(rendered)
}

func noteString(_ key: String, config: JSONObject, variables: JSONObject) -> String? {
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
    "notebookId": .string(notebook.notebookId.rawValue),
    "title": .string(notebook.title),
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
    "noteId": .string(note.noteId.rawValue),
    "notebookId": .string(note.notebookId.rawValue),
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
    "noteId": .string(result.note.noteId.rawValue),
    "notebookId": .string(result.note.notebookId.rawValue),
    "snippet": .string(result.snippet),
    "rank": .number(result.rank),
    "matchedTags": .array(result.matchedTags.map(tagJSON)),
    "isLinkedNeighbor": .bool(result.isLinkedNeighbor)
  ])
}

func noteGraphNeighborJSON(_ result: NoteGraphNeighbor) -> JSONValue {
  .object([
    "seedNoteId": .string(result.seedNoteId.rawValue),
    "note": noteJSON(result.note),
    "noteId": .string(result.note.noteId.rawValue),
    "edgeKind": .string(result.edgeKind.rawValue),
    "weight": .number(result.weight),
    "hopCount": .number(Double(result.hopCount)),
    "pathNoteIds": .array(result.pathNoteIds.map { .string($0.rawValue) })
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
    "tagId": .string(tag.tagId.rawValue),
    "name": .string(tag.name),
    "classId": tag.classId.map { .string($0.rawValue) } ?? .null,
    "isSystem": .bool(tag.isSystem),
    "createdAt": .string(tag.createdAt)
  ])
}

func noteCommentJSON(_ comment: NoteComment) -> JSONValue {
  .object([
    "commentId": .string(comment.commentId.rawValue),
    "noteId": comment.noteId.map { .string($0.rawValue) } ?? .null,
    "bodyMarkdown": .string(comment.bodyMarkdown),
    "author": .string(comment.author),
    "createdAt": .string(comment.createdAt)
  ])
}

private func noteLinkJSON(_ link: NoteLink) -> JSONValue {
  .object([
    "fromNoteId": .string(link.fromNoteId.rawValue),
    "toNoteId": .string(link.toNoteId.rawValue),
    "linkKind": .string(link.linkKind),
    "provenance": .string(link.provenance.rawValue),
    "createdAt": .string(link.createdAt)
  ])
}

func noteFileAttachmentJSON(_ attachment: NoteFileAttachment) -> JSONValue {
  .object([
    "noteId": .string(attachment.noteId.rawValue),
    "role": .string(attachment.role.rawValue),
    "position": .number(Double(attachment.position)),
    "file": fileRecordJSON(attachment.file)
  ])
}

func notebookFileAttachmentJSON(_ attachment: NotebookFileAttachment) -> JSONValue {
  .object([
    "notebookId": .string(attachment.notebookId.rawValue),
    "role": .string(attachment.role.rawValue),
    "file": fileRecordJSON(attachment.file)
  ])
}

func fileRecordJSON(_ file: FileRecord) -> JSONValue {
  .object([
    "fileId": .string(file.fileId.rawValue),
    "storageKind": .string(file.storageKind.rawValue),
    "localPath": file.localPath.map { .string($0) } ?? .null,
    "s3Profile": file.s3Profile.map { .string($0) } ?? .null,
    "s3Bucket": file.s3Bucket.map { .string($0) } ?? .null,
    "s3Key": file.s3Key.map { .string($0) } ?? .null,
    "s3URL": s3Locator(for: file).map { .string($0) } ?? .null,
    "mediaType": .string(file.mediaType),
    "byteSize": .number(Double(file.byteSize)),
    "sha256": .string(file.sha256),
    "originalFilename": file.originalFilename.map { .string($0) } ?? .null,
    "createdAt": .string(file.createdAt),
    "migratedAt": file.migratedAt.map { .string($0) } ?? .null
  ])
}
