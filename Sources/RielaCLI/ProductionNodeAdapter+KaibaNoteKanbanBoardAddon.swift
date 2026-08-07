import RielaCore
import AppCore

func kanbanBoard(_ context: NoteAddonContext) throws -> JSONObject {
  let requestedTagId = context.string("folderTagId", "tagId")
  let requestedTagName = context.string("tagName", "folderTagName")
  let candidates = try context.service.listTags().filter { tag in
    if let requestedTagId { return tag.tagId == requestedTagId }
    return tag.name == requestedTagName
  }
  guard candidates.count == 1, let folderTag = candidates.first else {
    let identity = requestedTagId ?? requestedTagName ?? ""
    guard !identity.isEmpty else {
      throw noteAddonInvalidInput("\(context.input.addon.name) requires folderTagId or tagName")
    }
    if candidates.isEmpty {
      throw NoteServiceError.notFound("tag not found: \(identity)")
    }
    throw NoteServiceError.invalidInput("tag name is ambiguous: \(identity)")
  }
  guard folderTag.classId == "folder" else {
    throw noteAddonInvalidInput(
      "\(context.input.addon.name) requires a folder-class tag: \(folderTag.tagId)"
    )
  }
  let limit = max(1, min(context.int("limit", default: 200), 200))
  let columns = try context.service.kanbanBoard(tagId: folderTag.tagId, limit: limit)
  return [
    "folderTagId": .string(folderTag.tagId),
    "tagName": .string(folderTag.name),
    "columns": .array(columns.map { column in
      .object([
        "status": .object([
          "name": .string(column.status.name),
          "category": .string(column.status.category.rawValue),
          "position": .number(Double(column.status.position))
        ]),
        "notebooks": .array(column.notebooks.map { notebook in
          .object([
            "notebookId": .string(notebook.notebookId),
            "title": .string(notebook.title),
            "progress": .string(notebook.progress),
            "updatedAt": .string(notebook.updatedAt),
            "metaJSON": notebook.metaJSON.map { .string($0) } ?? .null
          ])
        })
      ])
    })
  ]
}
