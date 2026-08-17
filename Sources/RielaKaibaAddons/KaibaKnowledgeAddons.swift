import AppCore
import Foundation
import RielaAddonSupport
import RielaCore

func searchNotesByTag(_ context: NoteAddonContext) throws -> JSONObject {
  let tags = try noteTags(context.value("tagFilter") ?? context.value("tags") ?? context.value("tag"))
    .map(\.name)
  guard !tags.isEmpty else {
    throw noteAddonInvalidInput("\(context.input.addon.name) tags must be a non-empty string or array")
  }
  let limit = min(max(context.int("limit", default: 20), 0), 200)
  let offset = min(max(context.int("offset", default: 0), 0), 1_000_000)
  let notes = try context.service.listNotes(
    limit: limit,
    offset: offset,
    notebookId: context.string("notebookId").map(NotebookID.init),
    tagFilter: tags
  )
  return [
    "notes": .array(notes.map(noteJSON)),
    "noteIds": .array(notes.map { .string($0.noteId.rawValue) }),
    "resultCount": .number(Double(notes.count)),
    "tagFilter": .array(tags.map(JSONValue.string))
  ]
}

func noteChain(_ context: NoteAddonContext) throws -> JSONObject {
  guard let rawNoteIds = context.value("noteIds") ?? context.value("noteId") else {
    throw noteAddonInvalidInput("\(context.input.addon.name) noteIds is required")
  }
  let seedNoteIds = try kaibaStringArray(rawNoteIds, fieldName: "noteIds")
  guard !seedNoteIds.isEmpty else {
    throw noteAddonInvalidInput("\(context.input.addon.name) noteIds must not be empty")
  }
  let results = try context.service.graphNeighbors(
    noteIds: seedNoteIds.prefix(NoteGraphPolicy.maximumSeedCount).map(NoteID.init),
    maxDepth: context.int("depth", default: NoteGraphPolicy.defaultMaxDepth),
    limit: context.int("limit", default: NoteGraphPolicy.defaultLimit)
  )
  let chains = results.map { result in
    JSONValue.object([
      "seedNoteId": .string(result.seedNoteId.rawValue),
      "targetNoteId": .string(result.note.noteId.rawValue),
      "pathNoteIds": .array(result.pathNoteIds.map { .string($0.rawValue) }),
      "hopCount": .number(Double(result.hopCount)),
      "edgeKind": .string(result.edgeKind.rawValue),
      "weight": .number(result.weight)
    ])
  }
  return [
    "chains": .array(chains),
    "results": .array(results.map(noteGraphNeighborJSON)),
    "resultCount": .number(Double(results.count)),
    "seedNoteIds": .array(seedNoteIds.map(JSONValue.string))
  ]
}

func noteAttachments(_ context: NoteAddonContext) throws -> JSONObject {
  if let noteId = context.string("noteId") {
    let attachments = try context.service.listFiles(noteId: NoteID(noteId))
    return [
      "noteId": .string(noteId),
      "attachments": .array(attachments.map(noteFileAttachmentJSON)),
      "files": .array(attachments.map { fileRecordJSON($0.file) }),
      "fileCount": .number(Double(attachments.count))
    ]
  }
  if let notebookId = context.string("notebookId") {
    let attachments = try context.service.listFiles(notebookId: NotebookID(notebookId))
    return [
      "notebookId": .string(notebookId),
      "attachments": .array(attachments.map(notebookFileAttachmentJSON)),
      "files": .array(attachments.map { fileRecordJSON($0.file) }),
      "fileCount": .number(Double(attachments.count))
    ]
  }
  throw noteAddonInvalidInput("\(context.input.addon.name) noteId or notebookId is required")
}

func noteMemos(_ context: NoteAddonContext) throws -> JSONObject {
  let noteId = try context.requiredString("noteId", fieldName: "noteId")
  let author = context.string("author")
  let comments = try context.service.listComments(noteId: NoteID(noteId)).filter { comment in
    author == nil || comment.author == author
  }
  let agentMemos = comments.filter { comment in
    let normalized = comment.author.lowercased()
    return normalized.hasPrefix("agent") || normalized.hasPrefix("ai")
      || normalized.hasPrefix("workflow:") || normalized == "assistant"
  }
  return [
    "noteId": .string(noteId),
    "memos": .array(comments.map(noteCommentJSON)),
    "memoCount": .number(Double(comments.count)),
    "agentMemos": .array(agentMemos.map(noteCommentJSON)),
    "agentMemoCount": .number(Double(agentMemos.count))
  ]
}

func importKaibaDocument(_ context: NoteAddonContext) async throws -> JSONObject {
  guard context.string("endpoint") == nil else {
    throw noteAddonInvalidInput(
      "\(context.input.addon.name) imports local files and does not support endpoint mode"
    )
  }
  let path = try context.requiredString("path", "filePath", fieldName: "path")
  let sourceURL = try localFileReferenceURL(path, context: context)
  guard FileManager.default.fileExists(atPath: sourceURL.path) else {
    throw noteAddonInvalidInput("\(context.input.addon.name) source file does not exist: \(path)")
  }
  _ = try localFileSize(url: sourceURL, context: context)

  let converter = try kaibaImportConverter(context)
  let imported: DocumentImportResult
  do {
    imported = try context.service.importDocument(
      at: sourceURL.path,
      title: context.string("title", "notebookTitle"),
      kindTagName: context.string("kindTagName", "notebookKindTag")
        ?? NoteStoreSchema.importedMaterialNotebookKindTag,
      converter: converter
    )
  } catch let error as DocumentConversionError {
    throw noteAddonInvalidInput("\(context.input.addon.name) conversion failed: \(error)")
  }

  var sourceFile = imported.sourceFile.file
  if let profileName = context.string("s3ProfileName") {
    let profiles = try KaibaConfigurationLoader.makeS3Profiles(
      configuration: context.kaibaConfiguration,
      environment: context.environment
    )
    guard let profile = profiles.first(where: { $0.name == profileName }) else {
      throw noteAddonInvalidInput("\(context.input.addon.name) unknown S3 profile: \(profileName)")
    }
    sourceFile = try context.service.migrateFileStorage(
      fileId: sourceFile.fileId,
      to: profile,
      verifyRemoteRead: context.bool("verifyS3Read", default: true)
    )
  }

  var payload: JSONObject = [
    "notebookId": .string(imported.notebook.notebookId.rawValue),
    "notebook": kaibaNotebookJSON(imported.notebook),
    "notes": .array(imported.notes.map(noteJSON)),
    "noteIds": .array(imported.notes.map { .string($0.noteId.rawValue) }),
    "noteCount": .number(Double(imported.notes.count)),
    "sourceFile": fileRecordJSON(sourceFile),
    "ocrRequested": .bool(context.bool("ocr", default: false)),
    "translationRequested": .bool(context.bool("translate", default: false))
  ]
  if context.bool("translate", default: false) {
    let translated = try await translateImportedNotebook(context, imported: imported)
    payload["translationNotebookId"] = .string(translated.notebookId.rawValue)
    payload["translationNotebook"] = kaibaNotebookJSON(translated)
  }
  return payload
}

func s3Locator(for file: FileRecord) -> String? {
  guard file.storageKind == .s3,
        let bucket = file.s3Bucket,
        let key = file.s3Key else {
    return nil
  }
  return "s3://\(bucket)/\(key)"
}

private func kaibaImportConverter(_ context: NoteAddonContext) throws -> ImportDocumentConverter {
  guard context.bool("ocr", default: false) else {
    return ImportDocumentConverter()
  }
  let configured = context.kaibaConfiguration.importSettings?.ocr
  guard let vendor = context.string("ocrVendor", "vendor") ?? configured?.vendor,
        let model = context.string("ocrModel", "model") ?? configured?.model else {
    throw noteAddonInvalidInput(
      "\(context.input.addon.name) ocr requires ocrVendor and ocrModel or Kaiba import.ocr configuration"
    )
  }
  let converter = AgentGatewayImageOCRConverter(
    commandPath: context.string("ocrCommandPath") ?? configured?.commandPath,
    vendor: vendor,
    model: model,
    apiKeyEnvironment: context.string("ocrAPIKeyEnv") ?? configured?.apiKeyEnvironmentVariable,
    environment: context.environment,
    prompt: context.string("ocrPrompt") ?? AgentGatewayImageOCRConverter.defaultPrompt
  )
  return ImportDocumentConverter(ocr: converter)
}

private func translateImportedNotebook(
  _ context: NoteAddonContext,
  imported: DocumentImportResult
) async throws -> Notebook {
  let configured = context.kaibaConfiguration.ai?.agent
  guard let vendor = context.string("translationVendor", "vendor") ?? configured?.provider,
        let model = context.string("translationModel", "model") ?? configured?.model else {
    throw noteAddonInvalidInput(
      "\(context.input.addon.name) translate requires translationVendor and translationModel or Kaiba ai.agent configuration"
    )
  }
  let language = try context.requiredString("targetLanguage", fieldName: "targetLanguage")
  let invoker = AgentGatewayCLIInvoker(
    commandPath: context.string("translationCommandPath") ?? configured?.commandPath,
    vendor: vendor,
    model: model,
    apiKeyEnvironment: context.string("translationAPIKeyEnv")
      ?? configured?.apiKeyEnvironmentVariable,
    environment: context.environment
  )
  return try await AITranslationService(
    service: context.service,
    invoker: invoker,
    provider: vendor,
    model: model
  ).translateNotebook(
    sourceNotebookId: imported.notebook.notebookId,
    targetLanguage: language,
    title: context.string("translationTitle")
  )
}

private func kaibaStringArray(_ value: JSONValue, fieldName: String) throws -> [String] {
  switch value {
  case let .string(string):
    return string.isEmpty ? [] : [string]
  case let .array(values):
    return try values.enumerated().map { index, value in
      guard case let .string(string) = value, !string.isEmpty else {
        throw noteAddonInvalidInput("\(fieldName)[\(index)] must be a non-empty string")
      }
      return string
    }
  default:
    throw noteAddonInvalidInput("\(fieldName) must be a string or array of strings")
  }
}

private func kaibaNotebookJSON(_ notebook: Notebook) -> JSONValue {
  .object([
    "notebookId": .string(notebook.notebookId.rawValue),
    "title": .string(notebook.title),
    "readOnly": .bool(notebook.readOnly),
    "createdAt": .string(notebook.createdAt),
    "updatedAt": .string(notebook.updatedAt),
    "metaJSON": notebook.metaJSON.map(JSONValue.string) ?? .null
  ])
}
