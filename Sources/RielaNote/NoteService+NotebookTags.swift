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
    let result = try driver.withDatabase { database in
      try database.transaction { db in
        let before = try requireNotebook(notebookId, in: db)
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
        let after = try requireNotebook(notebookId, in: db)
        return (notebook: after, tagNames: affectedFolderTagNames(before: before, after: after))
      }
    }
    publishChange(NoteChangeEvent(
      kind: NoteChangeEventKind.notebookTags,
      notebookId: notebookId,
      tagNames: result.tagNames
    ))
    return result.notebook
  }

  @discardableResult
  func removeNotebookTag(
    notebookId: String,
    tagName: String,
    removedBy provenance: NoteProvenance
  ) throws -> Notebook {
    let result = try driver.withDatabase { database in
      try database.transaction { db in
        let existing = try notebookTagAssignment(notebookId: notebookId, tagName: tagName, in: db)
        guard let existing else {
          return (notebook: try requireNotebook(notebookId, in: db), tagNames: nil as [String]?)
        }
        guard existing.deletable else {
          throw NoteServiceError.protectedTag(tagName)
        }
        if provenance == .ai, existing.provenance == .human {
          throw NoteServiceError.protectedTag(tagName)
        }
        let before = try requireNotebook(notebookId, in: db)
        try db.execute(
          """
          DELETE FROM notebook_tags
          WHERE notebook_id = ? AND tag_id = ?
          """,
          bindings: [.text(notebookId), .text(existing.tag.tagId)]
        )
        let after = try requireNotebook(notebookId, in: db)
        return (notebook: after, tagNames: affectedFolderTagNames(before: before, after: after))
      }
    }
    if let tagNames = result.tagNames {
      publishChange(NoteChangeEvent(
        kind: NoteChangeEventKind.notebookTags,
        notebookId: notebookId,
        tagNames: tagNames
      ))
    }
    return result.notebook
  }
}

/// A tag change can move a notebook onto or off a board, so subscribers on both
/// the old and the new scope need waking.
func affectedFolderTagNames(before: Notebook, after: Notebook) -> [String] {
  Array(Set(folderTagNames(of: before)).union(folderTagNames(of: after))).sorted()
}

func ensureNotebookKindTag(_ tagName: String, in database: SQLiteDatabase) throws {
  let tagId = notebookKindTagId(for: tagName)
  try database.execute(
    """
    INSERT INTO tags (tag_id, name, class_id, is_system, created_at)
    VALUES (?, ?, 'document-kind', 1, ?)
    ON CONFLICT(name) DO NOTHING
    """,
    bindings: [.text(tagId), .text(tagName), .text(NoteStoreClock.system.now())]
  )
}

private func notebookKindTagId(for tagName: String) -> String {
  "notebook-kind-\(tagName.utf8.map { String(format: "%02x", $0) }.joined())"
}
