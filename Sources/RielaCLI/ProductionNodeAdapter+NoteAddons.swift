import Foundation
import RielaCore
import RielaGraphQL
import RielaNote
import RielaNoteDispatch

private let noteAddonDefaultMaxAttachmentBytes = InlineWorkflowAddonAttachmentProjector.maxAttachmentBytes
private let noteAddonDefaultMaxPageCount = 500

enum BuiltinNoteAddon: String {
  case create = "riela/note-create"
  case update = "riela/note-update"
  case get = "riela/note-get"
  case search = "riela/note-search"
  case tagApply = "riela/note-tag-apply"
  case attachFile = "riela/note-attach-file"
  case graphQLDocument = "riela/note-graphql-document"
  case commentAdd = "riela/note-comment-add"
  case notebookIngestPages = "riela/notebook-ingest-pages"
  case conversationSave = "riela/note-conversation-save"
}

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
    }

    var payload: JSONObject = [
      "status": .string("ok"),
      "addon": .string(input.addon.name),
      "operation": .string(operation.rawValue.replacingOccurrences(of: "riela/note-", with: "")
        .replacingOccurrences(of: "riela/notebook-", with: "notebook-")),
      "stepId": .string(input.stepId),
      "noteRoot": .string(context.noteRoot),
      "databasePath": .string(context.service.driver.databasePath)
    ]
    for (key, value) in candidate {
      payload[key] = value
    }
    return AdapterExecutionOutput(
      provider: "riela-builtin-addon",
      model: input.addon.name,
      promptText: "",
      completionPassed: true,
      payload: payload
    )
  }
}

private struct NoteAddonContext {
  var input: WorkflowAddonExecutionInput
  var config: JSONObject
  var variables: JSONObject
  var noteRoot: String
  var service: NoteService
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
    config = input.addon.config ?? [:]
    variables = addonVariables(for: input)
    let workflowInput = noteObject(variables["workflowInput"])
    noteRoot = noteString("noteRoot", config: config, variables: variables)
      ?? nonEmptyString(workflowInput["noteRoot"])
      ?? environment["RIELA_NOTE_ROOT"].flatMap { $0.isEmpty ? nil : $0 }
      ?? "\(NSHomeDirectory())/.riela/note"
    noteRoot = (noteRoot as NSString).expandingTildeInPath
    service = try NoteService(
      driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot),
      autoActionDispatcher: NoteAutoActionWorkflowDispatcher(
        launcher: NoteAutoActionWorkflowCLILauncher(noteRoot: noteRoot)
      ),
      autoActionDiagnosticRecorder: StderrAutoActionFilterDiagnostics()
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
  // riela/note-update re-derives the stored title from the new body.
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
  let results = try context.service.searchNotes(
    query: try context.requiredString("query", "match", fieldName: "query"),
    tagFilter: try noteStringArray(context.value("tagFilter") ?? context.value("tags"), fieldName: "note tagFilter") ?? [],
    classFilter: try noteStringArray(context.value("classFilter"), fieldName: "note classFilter") ?? [],
    limit: context.int("limit", default: 20)
  )
  return [
    "results": .array(results.map(noteSearchResultJSON)),
    "resultCount": .number(Double(results.count)),
    "noteIds": .array(results.map { .string($0.note.noteId) })
  ]
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

private func executeNoteGraphQLDocument(_ context: NoteAddonContext) async throws -> JSONObject {
  let query = try context.requiredString("query", "document", fieldName: "query")
  let variables = try noteGraphQLVariables(context)
  let executor = NoteGraphQLDocumentExecutor(service: GraphQLNoteGraphQLService(service: context.service))
  let response = await executor.execute(GraphQLDocumentRequest(
    query: query,
    variables: variables,
    operationName: context.string("operationName")
  ))
  guard response.handled else {
    throw noteAddonInvalidInput("\(context.input.addon.name) document was not handled")
  }
  if let errors = response.body["errors"] {
    throw noteAddonInvalidInput("\(context.input.addon.name) document failed: \(errors)")
  }
  var payload: JSONObject = [
    "handled": .bool(response.handled),
    "statusCode": .number(Double(response.status)),
    "body": .object(response.body)
  ]
  for (key, value) in context.input.resolvedInputPayload
    where payload[key] == nil && key != "runtime" && key != "upstream" {
    payload[key] = value
  }
  let data = noteObject(response.body["data"])
  if data.count == 1, let field = data.keys.first {
    payload["fieldName"] = .string(field)
    let fieldValue = data[field] ?? .null
    payload["fieldPayload"] = fieldValue
    if case let .object(fieldPayload) = fieldValue {
      for (key, value) in fieldPayload {
        payload[key] = value
      }
    }
  }
  return payload
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
        readOnly: page.readOnly,
        tags: page.tags,
        metaJSON: pageMetaJSON(page),
        noteNumber: page.number
      )
    },
    provenance: noteProvenance(context.string("provenance")) ?? .system,
    assignedBy: context.string("assignedBy") ?? "riela-note-ingest",
    originatingActionId: context.string("originatingActionId", "actionId")
  )
  let sourceDocument = try attachSourceDocument(context: context, notebookId: result.notebook.notebookId)
  let pageImages = try attachPageImages(context: context, pages: pages, notes: result.notes)
  return [
    "notebookId": .string(result.notebook.notebookId),
    "notebook": notebookJSON(result.notebook),
    "notes": .array(result.notes.map(noteJSON)),
    "noteIds": .array(result.notes.map { .string($0.noteId) }),
    "pageCount": .number(Double(result.notes.count)),
    "sourceDocument": sourceDocument.map(notebookFileAttachmentJSON) ?? .null,
    "pageImages": .array(pageImages.map(noteFileAttachmentJSON))
  ]
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

private struct NoteAttachmentData {
  var data: Data
  var mediaType: String
  var filename: String?
}

private enum SourceAttachmentInput {
  case inline(NoteAttachmentData)
  case localFile(url: URL, mediaType: String, filename: String?)
}

private func noteAttachmentData(
  context: NoteAddonContext,
  input: WorkflowAddonExecutionInput
) throws -> NoteAttachmentData {
  let field = context.string("attachmentField", "attachment")
  let projected = field.flatMap { input.attachments[$0] } ?? (input.attachments.count == 1 ? input.attachments.values.first : nil)
  if let projected {
    let data: Data
    if let contentBase64 = projected.contentBase64, let decoded = Data(base64Encoded: contentBase64) {
      data = decoded
    } else if let contentText = projected.contentText {
      data = Data(contentText.utf8)
    } else {
      throw noteAddonInvalidInput("\(input.addon.name) attachment has no inline content")
    }
    try validateNoteAddonAttachmentSize(data.count, maxBytes: context.maxAttachmentBytes, label: "attachment")
    return NoteAttachmentData(data: data, mediaType: projected.mediaType, filename: projected.filename)
  }
  if let filePath = context.string("filePath", "path", "localPath") {
    let url = try localFileReferenceURL(filePath, context: context)
    return NoteAttachmentData(
      data: try boundedLocalFileData(url: url, context: context),
      mediaType: context.string("mediaType", "contentType") ?? "application/octet-stream",
      filename: context.string("filename", "fileName") ?? url.lastPathComponent
    )
  }
  let text = try context.requiredString("contentText", "text", "body", fieldName: "attachment content")
  try validateNoteAddonAttachmentSize(Data(text.utf8).count, maxBytes: context.maxAttachmentBytes, label: "attachment content")
  return NoteAttachmentData(
    data: Data(text.utf8),
    mediaType: context.string("mediaType", "contentType") ?? "text/plain",
    filename: context.string("filename", "fileName")
  )
}

private func sourceAttachmentInput(ref: String, context: NoteAddonContext) throws -> SourceAttachmentInput? {
  if let attachment = context.input.attachments[ref] {
    return .inline(try noteAttachmentData(attachment, addonName: context.input.addon.name, maxBytes: context.maxAttachmentBytes))
  }
  guard isLocalFileReference(ref) else {
    return nil
  }
  let url = try localFileReferenceURL(ref, context: context)
  guard FileManager.default.fileExists(atPath: url.path) else {
    return nil
  }
  _ = try localFileSize(url: url, context: context)
  return .localFile(
    url: url,
    mediaType: mediaType(for: url),
    filename: url.lastPathComponent
  )
}

private func noteAttachmentData(
  _ attachment: WorkflowAddonAttachmentValue,
  addonName: String,
  maxBytes: Int
) throws -> NoteAttachmentData {
  if let contentBase64 = attachment.contentBase64, let decoded = Data(base64Encoded: contentBase64) {
    try validateNoteAddonAttachmentSize(decoded.count, maxBytes: maxBytes, label: "attachment")
    return NoteAttachmentData(data: decoded, mediaType: attachment.mediaType, filename: attachment.filename)
  }
  if let contentText = attachment.contentText {
    let data = Data(contentText.utf8)
    try validateNoteAddonAttachmentSize(data.count, maxBytes: maxBytes, label: "attachment")
    return NoteAttachmentData(data: data, mediaType: attachment.mediaType, filename: attachment.filename)
  }
  throw noteAddonInvalidInput("\(addonName) attachment has no inline content")
}

private func isLocalFileReference(_ ref: String) -> Bool {
  if ref.hasPrefix("s3://") || ref.hasPrefix("http://") || ref.hasPrefix("https://") {
    return false
  }
  return ref.hasPrefix("file://") || ref.hasPrefix("/") || ref.hasPrefix("./") || ref.hasPrefix("../")
}

private func fileReferenceURL(_ ref: String, relativeTo root: URL) -> URL {
  if ref.hasPrefix("file://"), let url = URL(string: ref), url.isFileURL {
    return url.standardizedFileURL
  }
  if ref.hasPrefix("/") {
    return URL(fileURLWithPath: ref).standardizedFileURL
  }
  return URL(fileURLWithPath: ref, relativeTo: root).standardizedFileURL
}

private func localFileReferenceURL(_ ref: String, context: NoteAddonContext) throws -> URL {
  let root = context.localFileRoot
  let url = fileReferenceURL(ref, relativeTo: root)
  guard context.allowsLocalFileReferencesOutsideRoot || isDescendant(url, of: root) else {
    throw noteAddonInvalidInput("\(context.input.addon.name) local file reference is outside allowed root: \(ref)")
  }
  return url
}

private func isDescendant(_ url: URL, of root: URL) -> Bool {
  let path = url.standardizedFileURL.path
  let rootPath = root.standardizedFileURL.path
  return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
}

private func boundedLocalFileData(url: URL, context: NoteAddonContext) throws -> Data {
  _ = try localFileSize(url: url, context: context)
  let data = try Data(contentsOf: url)
  try validateNoteAddonAttachmentSize(data.count, maxBytes: context.maxAttachmentBytes, label: url.path)
  return data
}

private func localFileSize(url: URL, context: NoteAddonContext) throws -> Int {
  let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
  guard values.isRegularFile == true else {
    throw noteAddonInvalidInput("\(context.input.addon.name) local file reference is not a regular file: \(url.path)")
  }
  let size = values.fileSize ?? 0
  try validateNoteAddonAttachmentSize(size, maxBytes: context.maxAttachmentBytes, label: url.path)
  return size
}

private func validateNoteAddonAttachmentSize(_ size: Int, maxBytes: Int, label: String) throws {
  guard size <= maxBytes else {
    throw noteAddonInvalidInput("note attachment \(label) is \(size) bytes; max \(maxBytes)")
  }
}

private func mediaType(for url: URL) -> String {
  switch url.pathExtension.lowercased() {
  case "pdf":
    return "application/pdf"
  case "png":
    return "image/png"
  case "jpg", "jpeg":
    return "image/jpeg"
  case "webp":
    return "image/webp"
  case "txt", "md":
    return "text/plain"
  default:
    return "application/octet-stream"
  }
}

private struct NotePageInput {
  var bodyMarkdown: String
  var readOnly: Bool
  var tags: [NoteTagInput]
  var metaJSON: String?
  var number: Int?
  var pageImageRef: String?
}

private func notePageInputs(_ context: NoteAddonContext) throws -> [NotePageInput] {
  let value = context.value("pages")
  guard case let .array(values)? = value, !values.isEmpty else {
    throw noteAddonInvalidInput("riela/notebook-ingest-pages pages must be a non-empty array")
  }
  guard values.count <= context.maxPageCount else {
    throw noteAddonInvalidInput("riela/notebook-ingest-pages pages has \(values.count) items; max \(context.maxPageCount)")
  }
  return try values.enumerated().map { index, value in
    guard case let .object(page) = value else {
      throw noteAddonInvalidInput("riela/notebook-ingest-pages pages[\(index)] must be an object")
    }
    guard let body = nonEmptyString(page["bodyMarkdown"])
      ?? nonEmptyString(page["body"])
      ?? nonEmptyString(page["markdown"])
      ?? nonEmptyString(page["text"]) else {
      throw noteAddonInvalidInput("riela/notebook-ingest-pages pages[\(index)].bodyMarkdown is required")
    }
    let title = nonEmptyString(page["title"])
    let bodyMarkdown = title == nil || body.hasPrefix("# ") ? body : "# \(title ?? "")\n\n\(body)"
    return NotePageInput(
      bodyMarkdown: bodyMarkdown,
      readOnly: boolValue(page["readOnly"]) ?? true,
      tags: try noteTags(page["tags"]),
      metaJSON: noteMetaJSONString(page["meta"], page["metaJSON"]),
      number: intValue(page["number"]) ?? intValue(page["pageNumber"]),
      pageImageRef: nonEmptyString(page["pageImageRef"]) ?? nonEmptyString(page["imageRef"])
    )
  }
}

private func pageMetaJSON(_ page: NotePageInput) -> String? {
  var meta = page.metaJSON.flatMap(jsonObjectString)
  if page.number == nil, page.pageImageRef == nil {
    return page.metaJSON
  }
  if meta == nil {
    meta = [:]
  }
  if let number = page.number {
    meta?["number"] = .number(Double(number))
  }
  if let pageImageRef = page.pageImageRef {
    meta?["pageImageRef"] = .string(pageImageRef)
  }
  return JSONValue.object(meta ?? [:]).compactJSONStringOrEmpty()
}

private func jsonObjectString(_ string: String) -> JSONObject? {
  guard let data = string.data(using: .utf8),
        case let .object(object) = try? JSONDecoder().decode(JSONValue.self, from: data) else {
    return nil
  }
  return object
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

private func noteTags(_ value: JSONValue?) throws -> [NoteTagInput] {
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

private func noteGraphQLVariables(_ context: NoteAddonContext) throws -> JSONObject {
  guard let rawVariables = context.value("variables") else {
    return [:]
  }
  let rendered = renderJSONTemplates(rawVariables, variables: context.variables)
  guard case let .object(variables) = rendered else {
    throw noteAddonInvalidInput("\(context.input.addon.name) variables must be an object")
  }
  return variables
}

private func noteAddonInvalidInput(_ message: String) -> AdapterExecutionError {
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

private func noteObject(_ value: JSONValue?) -> JSONObject {
  guard case let .object(object)? = value else {
    return [:]
  }
  return object
}

private func noteMetaJSONString(_ values: JSONValue?...) -> String? {
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
    "progress": .string(notebook.progress.rawValue),
    "createdAt": .string(notebook.createdAt),
    "updatedAt": .string(notebook.updatedAt),
    "metaJSON": notebook.metaJSON.map { .string($0) } ?? .null,
    "tags": .array(notebook.tags.map(tagAssignmentJSON)),
    "firstNotePreview": notebook.firstNotePreview.map { .string($0) } ?? .null,
    "noteCount": notebook.noteCount.map { .number(Double($0)) } ?? .null
  ])
}

private func noteJSON(_ note: Note) -> JSONValue {
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
    "matchedTags": .array(result.matchedTags.map(tagJSON))
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
