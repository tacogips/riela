import Crypto
import Foundation
import KaibaClient
import RielaAddonSupport
import RielaCore

/// HTTP-only implementations for every registered note add-on. Endpoint,
/// authentication, and transport have already been frozen in `client` by
/// Kaiba preflight; authored configuration is input data only.
extension KaibaAddonCatalog {
  static func executeNoteAddon(
    _ input: WorkflowAddonExecutionInput,
    client: KaibaClient,
    operation: BuiltinNoteAddon
  ) async throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(.policyBlocked, "unsupported \(input.addon.name) version '\(input.addon.version ?? "")'")
    }
    let values = KaibaAddonInputs(input: input, environment: [:])
    let payload: JSONObject
    do {
      switch operation {
      case .create: payload = try await create(input, values: values, client: client)
      case .update: payload = try await update(values: values, client: client)
      case .get: payload = try await get(values: values, client: client)
      case .search: payload = try await search(values: values, client: client, tagsOnly: false)
      case .tagSearch: payload = try await search(values: values, client: client, tagsOnly: true)
      case .graphNeighbors, .chain: payload = try await neighbors(values: values, client: client, chain: operation == .chain)
      case .tagApply: payload = try await applyTags(values: values, client: client)
      case .attachFile: payload = try await attach(input, values: values, client: client)
      case .attachments: payload = try await attachments(values: values, client: client)
      case .memos: payload = try await memos(values: values, client: client)
      case .graphQLDocument, .graphQLRemote:
        return try await KaibaRemoteGraphQLAddon.execute(input, client: client)
      case .commentAdd: payload = try await comment(values: values, client: client)
      case .notebookIngestPages:
        payload = try await ingest(input, values: values, client: client, discriminator: operation.rawValue)
      case .documentImport: payload = try await importDocument(input, values: values, client: client)
      case .conversationSave: payload = try await conversation(values: values, client: client)
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as AdapterExecutionError {
      throw error
    } catch {
      throw AdapterExecutionError(.providerError, "Kaiba HTTP operation failed")
    }
    return addonOutput(input: input, operation: operation.outputName, payload: payload, values: values)
  }
}

private func create(_ input: WorkflowAddonExecutionInput, values: KaibaAddonInputs, client: KaibaClient) async throws -> JSONObject {
  let result = try await client.createNote(
    notebookId: values.string(["notebookId"]).map(KaibaNotebookID.init(rawValue:)),
    notebookTitle: values.string(["notebookTitle"]), title: values.string(["title"]),
    bodyMarkdown: try values.requiredString(["bodyMarkdown", "body", "markdown", "text"], fieldName: "bodyMarkdown"),
    readOnly: values.bool("readOnly", default: false), tags: try tags(values.value("tags")),
    provenance: values.string(["provenance"]), assignedBy: values.string(["assignedBy"]),
    metaJSON: values.string(["metaJSON"])
  )
  try requireAccepted(result.result)
  return kaibaSingleNotePayload(try requiredNote(result))
}

private func update(values: KaibaAddonInputs, client: KaibaClient) async throws -> JSONObject {
  let noteID = try values.requiredString(["noteId"], fieldName: "noteId")
  let body = try values.requiredString(["bodyMarkdown", "body", "markdown", "text"], fieldName: "bodyMarkdown")
  let result = try await client.updateNote(.init(rawValue: noteID), bodyMarkdown: body)
  try requireAccepted(result.result)
  return kaibaSingleNotePayload(try requiredNote(result))
}

private func get(values: KaibaAddonInputs, client: KaibaClient) async throws -> JSONObject {
  if let noteID = values.string(["noteId"]) {
    let typedID = KaibaNoteID(rawValue: noteID)
    async let noteResult = client.getNote(typedID)
    async let commentsResult = client.listNoteComments(typedID)
    async let linksResult = client.noteLinks(typedID)
    async let filesResult = client.listNoteAttachments(typedID)
    let result = try await noteResult
    let comments = try await commentsResult
    let links = try await linksResult
    let files = try await filesResult
    try requireAccepted(result.result)
    try requireAccepted(comments.result)
    try requireAccepted(links.result)
    try requireAccepted(files.result)
    guard let note = result.value else { return kaibaNotesPayload([]) }
    return [
      "noteId": .string(note.noteId.rawValue),
      "notebookId": .string(note.notebookId.rawValue),
      "note": kaibaNoteJSON(note),
      "comments": .array((comments.value ?? []).map(kaibaCommentJSON)),
      "links": .array((links.value ?? []).map(kaibaLinkJSON)),
      "files": .array((files.value ?? []).map(kaibaFileAttachmentJSON))
    ]
  }
  if let rawIDs = values.value("noteIds") {
    let requested = try stringArray(rawIDs, field: "noteIds")
    let uniqueIDs = Array(NSOrderedSet(array: requested)).compactMap { $0 as? String }.prefix(20)
    var notes: [KaibaNote] = []
    for noteID in uniqueIDs {
      let result = try await client.getNote(.init(rawValue: noteID))
      try requireAccepted(result.result)
      if let note = result.value { notes.append(note) }
    }
    var output = kaibaNotesPayload(notes)
    if let evidence = values.value("graphEvidence") { output["graphEvidence"] = evidence }
    return output
  }
  let result = try await client.listNotes(
    notebookId: values.string(["notebookId"]).map(KaibaNotebookID.init(rawValue:)),
    limit: bounded(values.int("limit", default: 20), upper: 200),
    offset: nonnegative(values.int("offset", default: 0))
  )
  try requireAccepted(result.result)
  return kaibaNotesPayload(result.value ?? [])
}

private func search(values: KaibaAddonInputs, client: KaibaClient, tagsOnly: Bool) async throws -> JSONObject {
  let tags = try tagNames(values.value("tagFilter") ?? values.value("tags") ?? values.value("tag"))
  if tagsOnly {
    guard !tags.isEmpty else {
      throw noteAddonInvalidInput("\(values.addonName) tags must be a non-empty string or array")
    }
    let result = try await client.listNotes(
      notebookId: values.string(["notebookId"]).map(KaibaNotebookID.init(rawValue:)),
      tagFilter: tags,
      limit: bounded(values.int("limit", default: 20), upper: 200),
      offset: nonnegative(values.int("offset", default: 0))
    )
    try requireAccepted(result.result)
    var output = kaibaCountedNotesPayload(result.value ?? [])
    output["tagFilter"] = .array(tags.map(JSONValue.string))
    return output
  }
  let result = try await client.searchNotes(
    query: try values.requiredString(["query", "text", "match"], fieldName: "query"),
    notebookId: values.string(["notebookId"]).map(KaibaNotebookID.init(rawValue:)),
    tagFilter: tags,
    includeLinked: values.bool("includeLinked", default: false),
    depth: bounded(values.int("depth", default: 1), upper: 8),
    limit: bounded(values.int("limit", default: 20), upper: 200),
    offset: nonnegative(values.int("offset", default: 0))
  )
  try requireAccepted(result.result)
  return kaibaSearchPayload(result.value ?? [])
}

private func neighbors(values: KaibaAddonInputs, client: KaibaClient, chain: Bool) async throws -> JSONObject {
  let ids = try stringArray(values.value("noteIds") ?? values.value("noteId"), field: "noteIds")
  guard !ids.isEmpty else { throw noteAddonInvalidInput("\(values.addonName) noteIds must not be empty") }
  let result = try await client.noteGraphNeighbors(noteIds: ids.map { KaibaNoteID(rawValue: $0) }, depth: bounded(values.int("depth", default: 2), upper: 8), limit: bounded(values.int("limit", default: 20), upper: 200))
  try requireAccepted(result.result); var output = kaibaNeighborsPayload(result.value ?? [])
  output["seedNoteIds"] = .array(ids.map(JSONValue.string))
  if chain {
    output["chains"] = output["results"] ?? .array([])
    output.removeValue(forKey: "noteIds")
  } else {
    let retrieved = orderedUniqueNoteIDs(ids + (result.value ?? []).map { $0.note.noteId.rawValue })
    output["retrievalNoteIds"] = .array(retrieved.map(JSONValue.string))
  }
  return output
}

private func applyTags(values: KaibaAddonInputs, client: KaibaClient) async throws -> JSONObject {
  let result = try await client.applyNoteTags(
    noteId: .init(rawValue: try values.requiredString(["noteId"], fieldName: "noteId")),
    tags: try tags(values.value("tags") ?? values.value("tag")),
    provenance: values.string(["provenance"]),
    assignedBy: values.string(["assignedBy"])
  )
  try requireAccepted(result.result)
  let note = try requiredNote(result)
  var output = kaibaSingleNotePayload(note)
  output["tags"] = kaibaTagAssignmentsJSON(note.tags)
  return output
}

private func attach(_ input: WorkflowAddonExecutionInput, values: KaibaAddonInputs, client: KaibaClient) async throws -> JSONObject {
  let attachment = try inlineAttachment(input: input, values: values)
  let noteID = try values.requiredString(["noteId"], fieldName: "noteId")
  let position = nonnegative(values.int("position", default: 0))
  let result = try await client.attachNoteFile(.init(rawValue: noteID), bytes: attachment.bytes, mediaType: attachment.mediaType, originalFilename: attachment.filename, position: position)
  try requireAccepted(result.result)
  guard let file = result.file else {
    throw AdapterExecutionError(.providerError, "Kaiba HTTP operation returned no file")
  }
  return [
    "noteId": .string(noteID),
    "fileId": .string(file.fileId.rawValue),
    "file": .object([
      "noteId": .string(noteID),
      "role": .string(values.string(["role"]) ?? "related"),
      "position": .number(Double(position)),
      "file": kaibaFileJSON(file)
    ])
  ]
}

private func attachments(values: KaibaAddonInputs, client: KaibaClient) async throws -> JSONObject {
  if let noteID = values.string(["noteId"]) {
    let result = try await client.listNoteAttachments(.init(rawValue: noteID))
    try requireAccepted(result.result)
    return kaibaNoteAttachmentsPayload(result.value ?? [], noteID: noteID)
  }
  let notebook = try values.requiredString(["notebookId"], fieldName: "noteId or notebookId")
  let result = try await client.listNotebookAttachments(.init(rawValue: notebook))
  try requireAccepted(result.result)
  return kaibaNotebookAttachmentsPayload(result.value ?? [], notebookID: notebook)
}

private func memos(values: KaibaAddonInputs, client: KaibaClient) async throws -> JSONObject {
  let noteID = try values.requiredString(["noteId"], fieldName: "noteId")
  let result = try await client.listNoteComments(.init(rawValue: noteID)); try requireAccepted(result.result)
  let comments = result.value ?? []
  let memoValues = comments.map(kaibaCommentOutput)
  let agents = memoValues.filter(isAgentMemo)
  var output: JSONObject = ["noteId": .string(noteID), "memos": .array(memoValues), "memoCount": .number(Double(memoValues.count))]
  output["agentMemos"] = .array(agents)
  output["agentMemoCount"] = .number(Double(agents.count))
  return output
}

private func comment(values: KaibaAddonInputs, client: KaibaClient) async throws -> JSONObject {
  let result = try await client.addNoteComment(
    .init(rawValue: try values.requiredString(["noteId"], fieldName: "noteId")),
    bodyMarkdown: try values.requiredString(
      ["bodyMarkdown", "body", "comment", "text"], fieldName: "bodyMarkdown"
    ),
    author: values.string(["author", "assignedBy"])
  )
  try requireAccepted(result.result)
  guard let addedComment = result.comment else {
    throw AdapterExecutionError(.providerError, "Kaiba HTTP operation returned no comment")
  }
  let noteID = try values.requiredString(["noteId"], fieldName: "noteId")
  return [
    "noteId": .string(addedComment.noteId?.rawValue ?? noteID),
    "commentId": .string(addedComment.commentId.rawValue),
    "comment": kaibaCommentJSON(addedComment)
  ]
}

private func ingest(_ input: WorkflowAddonExecutionInput, values: KaibaAddonInputs, client: KaibaClient, discriminator: String) async throws -> JSONObject {
  let pages = try ingestPages(values.value("pages"))
  let result = try await client.ingestNotebookPages(
    idempotencyKey: try idempotencyKey(input, values: values, discriminator: discriminator),
    title: values.string(["notebookTitle", "title"]) ?? "Imported Material",
    pages: pages,
    kindTagName: values.string(["notebookKindTag", "kindTagName"]),
    metaJSON: values.string(["metaJSON"])
  )
  try requireAccepted(result.result)
  guard let notebook = result.notebook else {
    throw AdapterExecutionError(.providerError, "Kaiba HTTP operation returned no notebook")
  }
  let notes = result.notes ?? []
  var output: JSONObject = [
    "notebookId": .string(notebook.notebookId.rawValue),
    "notebook": kaibaNotebookJSON(notebook),
    "notes": .array(notes.map(kaibaNoteJSON)),
    "noteIds": .array(notes.map { .string($0.noteId.rawValue) })
  ]
  output["pageCount"] = .number(Double(pages.count))
  output["sourceDocument"] = sourceDocumentAttachment(
    result.notebookFiles,
    notebookID: notebook.notebookId.rawValue
  )
  output["pageImages"] = pageImageAttachments(result.noteFiles)
  return output
}

private func importDocument(
  _ input: WorkflowAddonExecutionInput,
  values: KaibaAddonInputs,
  client: KaibaClient
) async throws -> JSONObject {
  let document = try documentImportInput(values)
  let primaryKey = try idempotencyKey(input, values: values, discriminator: "document-import:primary")
  let primary = try await client.ingestDocument(
    idempotencyKey: primaryKey,
    title: document.title,
    pages: document.pages,
    sourceDocument: document.source,
    metaJSON: values.string(["metaJSON"])
  )
  try requireAccepted(primary.result)
  guard let notebook = primary.notebook else {
    throw AdapterExecutionError(.providerError, "Kaiba HTTP operation returned no notebook")
  }
  let notes = primary.notes ?? []
  var output: JSONObject = [
    "notebookId": .string(notebook.notebookId.rawValue),
    "notebook": kaibaNotebookJSON(notebook),
    "notes": .array(notes.map(kaibaNoteJSON)),
    "noteIds": .array(notes.map { .string($0.noteId.rawValue) }),
    "noteCount": .number(Double(notes.count))
  ]
  output["sourceFile"] = primary.notebookFiles?.first.map { kaibaFileJSON($0.file) } ?? .null
  output["ocrRequested"] = .bool(values.bool("ocr", default: false))
  output["translationRequested"] = .bool(values.bool("translate", default: false))
  if values.bool("translate", default: false) {
    let translatedPages = try ingestPages(values.value("translatedPages"))
    let translated = try await client.ingestDocument(
      idempotencyKey: try idempotencyKey(input, values: values, discriminator: "document-import:translation"),
      title: values.string(["translationTitle"]) ?? "\(document.title) (translation)",
      pages: translatedPages,
      sourceDocument: document.source,
      metaJSON: values.string(["translationMetaJSON", "metaJSON"])
    )
    try requireAccepted(translated.result)
    output["translationNotebookId"] = translated.notebook.map { .string($0.notebookId.rawValue) } ?? .null
    output["translationNotebook"] = translated.notebook.map(kaibaNotebookJSON) ?? .null
  }
  return output
}

private func conversation(values: KaibaAddonInputs, client: KaibaClient) async throws -> JSONObject {
  let result = try await client.saveConversation(
    title: try values.requiredString(["title", "conversationTitle"], fieldName: "title"),
    transcript: try conversationTurns(values.value("transcript") ?? values.value("turns")),
    assignedBy: values.string(["assignedBy"])
  )
  try requireAccepted(result.result)
  guard let notebook = result.notebook else {
    throw AdapterExecutionError(.providerError, "Kaiba HTTP operation returned no notebook")
  }
  let notes = result.notes ?? []
  return [
    "notebookId": .string(notebook.notebookId.rawValue),
    "notebook": kaibaNotebookJSON(notebook),
    "notes": .array(notes.map(kaibaNoteJSON)),
    "noteIds": .array(notes.map { .string($0.noteId.rawValue) })
  ]
}

private func requiredNote(_ value: KaibaOperationPayload) throws -> KaibaNote {
  guard let note = value.note else {
    throw AdapterExecutionError(.providerError, "Kaiba HTTP operation returned no note")
  }
  return note
}

private func kaibaCommentOutput(_ value: KaibaComment) -> JSONValue {
  .object([
    "commentId": .string(value.commentId.rawValue),
    "noteId": value.noteId.map { .string($0.rawValue) } ?? .null,
    "notebookId": value.notebookId.map { .string($0.rawValue) } ?? .null,
    "bodyMarkdown": .string(value.bodyMarkdown),
    "author": .string(value.author),
    "createdAt": .string(value.createdAt)
  ])
}

private func isAgentMemo(_ value: JSONValue) -> Bool {
  guard case let .object(object) = value,
        case let .string(author)? = object["author"] else { return false }
  let normalized = author.lowercased()
  return normalized.hasPrefix("agent") || normalized.hasPrefix("ai")
    || normalized.hasPrefix("workflow:") || normalized == "assistant"
}

func addonOutput(input: WorkflowAddonExecutionInput, operation: String, payload: JSONObject, values: KaibaAddonInputs) -> AdapterExecutionOutput {
  var body: JSONObject = ["status": .string("ok"), "addon": .string(input.addon.name), "operation": .string(operation), "stepId": .string(input.stepId)]
  if case let .object(pass)? = values.config["passthrough"].map({ renderJSONTemplates($0, variables: values.variables) }) { body.merge(pass) { _, incoming in incoming } }
  body.merge(payload) { _, incoming in incoming }
  return .init(provider: "riela-builtin-addon", model: input.addon.name, promptText: "", completionPassed: true, when: ["always": true], payload: body)
}

func requireAccepted(_ result: KaibaControlPlaneResult) throws { if !result.accepted { throw AdapterExecutionError(.providerError, "Kaiba HTTP operation was rejected") } }
func bounded(_ value: Int, upper: Int) -> Int { min(max(value, 1), upper) }
func nonnegative(_ value: Int) -> Int { max(0, value) }
func tags(_ value: JSONValue?) throws -> [KaibaTagInput] { try tagNames(value).map { KaibaTagInput(name: $0) } }
func tagNames(_ value: JSONValue?) throws -> [String] { try stringArray(value, field: "tags") }
func stringArray(_ value: JSONValue?, field: String) throws -> [String] {
  guard let value else { return [] }
  if case let .string(item) = value, !item.isEmpty { return [item] }
  guard case let .array(items) = value else { throw noteAddonInvalidInput("\(field) must be a string or array") }
  return try items.map { item in guard case let .string(value) = item, !value.isEmpty else { throw noteAddonInvalidInput("\(field) must contain strings") }; return value }
}

private func orderedUniqueNoteIDs(_ values: [String]) -> [String] {
  var seen = Set<String>()
  return values.filter { seen.insert($0).inserted }
}

private func sourceDocumentAttachment(
  _ attachments: [KaibaFileAttachment]?,
  notebookID: String
) -> JSONValue {
  guard let attachment = attachments?.first(where: { $0.role == .sourceDocument }) else {
    return .null
  }
  return .object([
    "notebookId": .string(notebookID),
    "role": .string(attachment.role.rawValue),
    "file": kaibaFileJSON(attachment.file)
  ])
}

private func pageImageAttachments(_ attachments: [KaibaFileAttachment]?) -> JSONValue {
  .array((attachments ?? [])
    .filter { $0.role == .sourcePageImage }
    .map(kaibaFileAttachmentJSON))
}

private struct InlineAttachmentData {
  let bytes: Data
  let mediaType: String
  let filename: String?
}

private func inlineAttachment(
  input: WorkflowAddonExecutionInput,
  values: KaibaAddonInputs
) throws -> InlineAttachmentData {
  let selectedName = values.string(["attachmentField", "attachment"])
  let chosen = selectedName.flatMap { input.attachments[$0] }
    ?? (input.attachments.count == 1 ? input.attachments.values.first : nil)
  if let chosen {
    if let base64 = chosen.contentBase64, let bytes = Data(base64Encoded: base64) {
      return .init(bytes: bytes, mediaType: chosen.mediaType, filename: chosen.filename)
    }
    if let text = chosen.contentText {
      return .init(bytes: Data(text.utf8), mediaType: chosen.mediaType, filename: chosen.filename)
    }
  }
  let text = try values.requiredString(["contentText", "text", "body"], fieldName: "attachment content")
  return .init(
    bytes: Data(text.utf8),
    mediaType: values.string(["mediaType", "contentType"]) ?? "text/plain",
    filename: values.string(["filename", "fileName"])
  )
}

func ingestPages(_ value: JSONValue?) throws -> [KaibaIngestPage] {
  guard case let .array(pages)? = value, !pages.isEmpty else {
    throw noteAddonInvalidInput("kaiba/notebook-ingest-pages pages must be a non-empty array")
  }
  return try pages.enumerated().map { index, value in
    guard case let .object(page) = value,
          let body = page["bodyMarkdown"].flatMap(nonEmptyString)
            ?? page["body"].flatMap(nonEmptyString) else {
      throw noteAddonInvalidInput("pages[\(index)].bodyMarkdown is required")
    }
    return .init(
      bodyMarkdown: body,
      readOnly: boolValue(page["readOnly"]) ?? true,
      tags: try tags(page["tags"]),
      metaJSON: page["metaJSON"].flatMap(nonEmptyString),
      noteNumber: intValue(page["noteNumber"])
    )
  }
}

private func conversationTurns(_ value: JSONValue?) throws -> [KaibaConversationTurn] {
  guard case let .array(turns)? = value else { throw noteAddonInvalidInput("transcript must be an array") }
  return try turns.enumerated().map { index, value in
    guard case let .object(turn) = value,
          let user = turn["userMarkdown"].flatMap(nonEmptyString),
          let assistant = turn["assistantMarkdown"].flatMap(nonEmptyString) else {
      throw noteAddonInvalidInput("transcript[\(index)] requires userMarkdown and assistantMarkdown")
    }
    return .init(
      userMarkdown: user,
      assistantMarkdown: assistant,
      sourceNoteIds: try stringArray(turn["sourceNoteIds"], field: "sourceNoteIds")
        .map(KaibaNoteID.init(rawValue:))
    )
  }
}

func idempotencyKey(_ input: WorkflowAddonExecutionInput, values: KaibaAddonInputs, discriminator: String) throws -> String {
  if let value = values.string(["idempotencyKey"]), !value.isEmpty { return value }
  guard let identity = input.executionIdentity else { throw noteAddonInvalidInput("missing_idempotency_identity") }
  let operation = try identity.validatedOperationExecutionId()
  let fields = [identity.workflowExecutionId, operation, input.workflowId, input.stepId, input.nodeId, input.addon.name, discriminator]
  guard !fields.contains(where: \.isEmpty) else { throw noteAddonInvalidInput("missing_idempotency_identity") }
  let bytes = fields.reduce(into: Data()) { result, field in let value = Data(field.utf8); result.append(Data("\(value.count):".utf8)); result.append(value) }
  return "riela-kaiba-v1-" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}
