import Foundation
import RielaSQLite

public extension NoteService {
  @discardableResult
  func applyNotebookTags(
    notebookId: String,
    tags: [String],
    provenance: NoteProvenance,
    assignedBy: String? = nil
  ) throws -> Notebook {
    try driver.withDatabase { database in
      try database.transaction { db in
        _ = try requireNotebook(notebookId, in: db)
        for tagName in tags {
          try applyNotebookTag(
            notebookId: notebookId,
            tagName: tagName,
            provenance: provenance,
            assignedBy: assignedBy,
            deletable: true,
            in: db
          )
        }
        return try requireNotebook(notebookId, in: db)
      }
    }
  }

  @discardableResult
  func removeNotebookTag(
    notebookId: String,
    tagName: String,
    removedBy provenance: NoteProvenance
  ) throws -> Notebook {
    try driver.withDatabase { database in
      try database.transaction { db in
        let existing = try notebookTagAssignment(notebookId: notebookId, tagName: tagName, in: db)
        guard let existing else {
          return try requireNotebook(notebookId, in: db)
        }
        guard existing.deletable else {
          throw NoteServiceError.protectedTag(tagName)
        }
        if provenance == .ai, existing.provenance == .human {
          throw NoteServiceError.protectedTag(tagName)
        }
        try db.execute(
          """
          DELETE FROM notebook_tags
          WHERE notebook_id = ? AND tag_id = ?
          """,
          bindings: [.text(notebookId), .text(existing.tag.tagId)]
        )
        return try requireNotebook(notebookId, in: db)
      }
    }
  }
}
