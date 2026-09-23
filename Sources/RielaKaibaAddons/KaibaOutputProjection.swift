import KaibaClient
import RielaCore

// Only explicit compatibility projections cross from KaibaClient into a
// workflow payload. Control-plane diagnostics are deliberately not forwarded.

func kaibaSingleNotePayload(_ note: KaibaNote) -> JSONObject {
  [
    "noteId": .string(note.noteId.rawValue),
    "notebookId": .string(note.notebookId.rawValue),
    "note": kaibaNoteJSON(note)
  ]
}

func kaibaNotesPayload(_ notes: [KaibaNote]) -> JSONObject {
  [
    "notes": .array(notes.map(kaibaNoteJSON)),
    "noteIds": .array(notes.map { .string($0.noteId.rawValue) })
  ]
}

func kaibaCountedNotesPayload(_ notes: [KaibaNote]) -> JSONObject {
  var output = kaibaNotesPayload(notes)
  output["resultCount"] = .number(Double(notes.count))
  return output
}

func kaibaAttachmentsPayload(_ attachments: [KaibaFileAttachment]) -> JSONObject {
  [
    "attachments": .array(attachments.map(kaibaFileAttachmentJSON)),
    "files": .array(attachments.map { kaibaFileJSON($0.file) }),
    "fileCount": .number(Double(attachments.count))
  ]
}

func kaibaNoteAttachmentsPayload(
  _ attachments: [KaibaFileAttachment],
  noteID: String
) -> JSONObject {
  var output = kaibaAttachmentsPayload(attachments)
  output["noteId"] = .string(noteID)
  return output
}

func kaibaNotebookAttachmentsPayload(
  _ attachments: [KaibaFileAttachment],
  notebookID: String
) -> JSONObject {
  var output = kaibaAttachmentsPayload(attachments)
  output["notebookId"] = .string(notebookID)
  return output
}

func kaibaTagAssignmentsJSON(_ assignments: [KaibaTagAssignment]) -> JSONValue {
  .array(assignments.map(kaibaTagAssignmentJSON))
}

func kaibaSearchPayload(_ results: [KaibaNoteSearchResult]) -> JSONObject {
  [
    "results": .array(results.map { result in
      .object([
        "note": kaibaNoteJSON(result.note),
        "noteId": .string(result.note.noteId.rawValue),
        "notebookId": .string(result.note.notebookId.rawValue),
        "snippet": .string(result.snippet),
        "rank": .number(result.rank),
        "matchedTags": .array(result.matchedTags.map(kaibaTagJSON)),
        "isLinkedNeighbor": .bool(result.isLinkedNeighbor),
        "termCoverage": .number(result.termCoverage)
      ])
    }),
    "noteIds": .array(results.map { .string($0.note.noteId.rawValue) }),
    "resultCount": .number(Double(results.count))
  ]
}

func kaibaNeighborsPayload(_ results: [KaibaNoteGraphNeighbor]) -> JSONObject {
  [
    "results": .array(results.map(kaibaNeighborJSON)),
    "noteIds": .array(results.map { .string($0.note.noteId.rawValue) }),
    "resultCount": .number(Double(results.count))
  ]
}

func kaibaNoteJSON(_ value: KaibaNote) -> JSONValue {
  .object([
    "noteId": .string(value.noteId.rawValue),
    "notebookId": .string(value.notebookId.rawValue),
    "noteNumber": .number(Double(value.noteNumber)),
    "title": value.title.map(JSONValue.string) ?? .null,
    "bodyMarkdown": .string(value.bodyMarkdown),
    "readOnly": .bool(value.readOnly),
    "createdAt": .string(value.createdAt),
    "updatedAt": .string(value.updatedAt),
    "metaJSON": value.metaJSON.map(JSONValue.string) ?? .null,
    "tags": .array(value.tags.map(kaibaTagAssignmentJSON))
  ])
}

func kaibaNotebookJSON(_ value: KaibaNotebook) -> JSONValue {
  .object([
    "notebookId": .string(value.notebookId.rawValue),
    "title": .string(value.title),
    "readOnly": .bool(value.readOnly),
    "createdAt": .string(value.createdAt),
    "updatedAt": .string(value.updatedAt),
    "metaJSON": value.metaJSON.map(JSONValue.string) ?? .null,
    "tags": .array(value.tags.map(kaibaTagAssignmentJSON)),
    "noteCount": value.noteCount.map { .number(Double($0)) } ?? .null
  ])
}

func kaibaFileJSON(_ value: KaibaFile) -> JSONValue {
  .object([
    "fileId": .string(value.fileId.rawValue),
    "storageKind": .string(value.storageKind),
    "s3URL": value.s3URL.map(JSONValue.string) ?? .null,
    "mediaType": .string(value.mediaType),
    "byteSize": .number(Double(value.byteSize)),
    "sha256": .string(value.sha256),
    "originalFilename": value.originalFilename.map(JSONValue.string) ?? .null,
    "createdAt": .string(value.createdAt),
    "migratedAt": value.migratedAt.map(JSONValue.string) ?? .null
  ])
}

private func kaibaTagJSON(_ value: KaibaTag) -> JSONValue {
  .object([
    "tagId": .string(value.tagId.rawValue), "name": .string(value.name),
    "classId": value.classId.map(JSONValue.string) ?? .null,
    "isSystem": .bool(value.isSystem), "createdAt": .string(value.createdAt)
  ])
}

private func kaibaTagAssignmentJSON(_ value: KaibaTagAssignment) -> JSONValue {
  .object([
    "tag": kaibaTagJSON(value.tag), "provenance": .string(value.provenance),
    "assignedBy": value.assignedBy.map(JSONValue.string) ?? .null,
    "deletable": .bool(value.deletable), "createdAt": .string(value.createdAt)
  ])
}

func kaibaFileAttachmentJSON(_ value: KaibaFileAttachment) -> JSONValue {
  .object([
    "noteId": value.noteId.map { .string($0.rawValue) } ?? .null,
    "notebookId": value.notebookId.map { .string($0.rawValue) } ?? .null,
    "file": kaibaFileJSON(value.file), "role": .string(value.role.rawValue),
    "position": value.position.map { .number(Double($0)) } ?? .null
  ])
}

func kaibaCommentJSON(_ value: KaibaComment) -> JSONValue {
  .object([
    "commentId": .string(value.commentId.rawValue),
    "noteId": value.noteId.map { .string($0.rawValue) } ?? .null,
    "notebookId": value.notebookId.map { .string($0.rawValue) } ?? .null,
    "bodyMarkdown": .string(value.bodyMarkdown), "author": .string(value.author),
    "createdAt": .string(value.createdAt)
  ])
}

func kaibaLinkJSON(_ value: KaibaNoteLink) -> JSONValue {
  .object([
    "fromNoteId": .string(value.fromNoteId.rawValue), "toNoteId": .string(value.toNoteId.rawValue),
    "linkKind": .string(value.linkKind), "provenance": .string(value.provenance),
    "createdAt": .string(value.createdAt)
  ])
}

private func kaibaNeighborJSON(_ value: KaibaNoteGraphNeighbor) -> JSONValue {
  .object([
    "seedNoteId": .string(value.seedNoteId.rawValue), "note": kaibaNoteJSON(value.note),
    "noteId": .string(value.note.noteId.rawValue),
    "targetNoteId": .string(value.note.noteId.rawValue), "edgeKind": .string(value.edgeKind),
    "weight": .number(value.weight), "hopCount": .number(Double(value.hopCount)),
    "pathNoteIds": .array(value.pathNoteIds.map { .string($0.rawValue) })
  ])
}
