import Foundation
import RielaSQLite

func noteTags(noteId: String, in database: SQLiteDatabase) throws -> [TagAssignment] {
  try tagAssignments(
    sql: """
      SELECT t.tag_id, t.name, t.class_id, t.is_system, t.created_at,
        nt.provenance, nt.assigned_by, nt.deletable, nt.created_at AS assigned_at
      FROM note_tags nt
      INNER JOIN tags t ON t.tag_id = nt.tag_id
      WHERE nt.note_id = ?
      ORDER BY t.name
      """,
    id: noteId,
    in: database
  )
}

func noteTags(noteIds: [String], in database: SQLiteDatabase) throws -> [String: [TagAssignment]] {
  let orderedNoteIds = orderedUnique(noteIds)
  guard !orderedNoteIds.isEmpty else {
    return [:]
  }
  let rows = try database.query(
    """
      SELECT nt.note_id, t.tag_id, t.name, t.class_id, t.is_system, t.created_at,
        nt.provenance, nt.assigned_by, nt.deletable, nt.created_at AS assigned_at
      FROM note_tags nt
      INNER JOIN tags t ON t.tag_id = nt.tag_id
      WHERE nt.note_id IN (\(placeholders(count: orderedNoteIds.count)))
      ORDER BY nt.note_id, t.name
      """,
    bindings: orderedNoteIds.map(SQLiteValue.text)
  )
  var tagsByNoteId: [String: [TagAssignment]] = [:]
  tagsByNoteId.reserveCapacity(orderedNoteIds.count)
  for row in rows {
    guard let noteId = row["note_id"] else {
      throw NoteServiceError.invalidRow("tag assignment row is missing note_id")
    }
    tagsByNoteId[noteId, default: []].append(try tagAssignment(from: row))
  }
  return tagsByNoteId
}

func notebookTags(notebookId: String, in database: SQLiteDatabase) throws -> [TagAssignment] {
  try tagAssignments(
    sql: """
      SELECT t.tag_id, t.name, t.class_id, t.is_system, t.created_at,
        nt.provenance, nt.assigned_by, nt.deletable, nt.created_at AS assigned_at
      FROM notebook_tags nt
      INNER JOIN tags t ON t.tag_id = nt.tag_id
      WHERE nt.notebook_id = ?
      ORDER BY t.name
      """,
    id: notebookId,
    in: database
  )
}

func tagAssignment(noteId: String, tagName: String, in database: SQLiteDatabase) throws -> TagAssignment? {
  try tagAssignments(
    sql: """
      SELECT t.tag_id, t.name, t.class_id, t.is_system, t.created_at,
        nt.provenance, nt.assigned_by, nt.deletable, nt.created_at AS assigned_at
      FROM note_tags nt
      INNER JOIN tags t ON t.tag_id = nt.tag_id
      WHERE nt.note_id = ? AND t.name = ?
      LIMIT 1
      """,
    bindings: [.text(noteId), .text(tagName)],
    in: database
  ).first
}

func notebookTagAssignment(notebookId: String, tagName: String, in database: SQLiteDatabase) throws -> TagAssignment? {
  try tagAssignments(
    sql: """
      SELECT t.tag_id, t.name, t.class_id, t.is_system, t.created_at,
        nt.provenance, nt.assigned_by, nt.deletable, nt.created_at AS assigned_at
      FROM notebook_tags nt
      INNER JOIN tags t ON t.tag_id = nt.tag_id
      WHERE nt.notebook_id = ? AND t.name = ?
      LIMIT 1
      """,
    bindings: [.text(notebookId), .text(tagName)],
    in: database
  ).first
}

private func tagAssignments(sql: String, id: String, in database: SQLiteDatabase) throws -> [TagAssignment] {
  try tagAssignments(sql: sql, bindings: [.text(id)], in: database)
}

private func tagAssignments(sql: String, bindings: [SQLiteValue], in database: SQLiteDatabase) throws -> [TagAssignment] {
  try database.query(sql, bindings: bindings).map(tagAssignment(from:))
}

private func tagAssignment(from row: SQLiteRow) throws -> TagAssignment {
  guard let provenanceText = row["provenance"],
        let provenance = NoteProvenance(rawValue: provenanceText),
        let assignedAt = row["assigned_at"] else {
    throw NoteServiceError.invalidRow("tag assignment row is missing required fields")
  }
  return TagAssignment(
    tag: try tag(from: row),
    provenance: provenance,
    assignedBy: row["assigned_by"] ?? nil,
    deletable: row["deletable"] != "0",
    createdAt: assignedAt
  )
}

func orderedUnique(_ values: [String]) -> [String] {
  var seen = Set<String>()
  return values.filter { seen.insert($0).inserted }
}

func firstNotePreview(notebookId: String, in database: SQLiteDatabase) throws -> String? {
  let rows = try database.query(
    """
    SELECT body_markdown
    FROM notes
    WHERE notebook_id = ?
    ORDER BY note_number
    LIMIT 1
    """,
    bindings: [.text(notebookId)]
  )
  guard let body = rows.first?["body_markdown"] else {
    return nil
  }
  return notebookPreviewText(body)
}

func nextNoteNumber(notebookId: String, in database: SQLiteDatabase) throws -> Int {
  let rows = try database.query(
    "SELECT ifnull(max(note_number), 0) + 1 AS next_note_number FROM notes WHERE notebook_id = ?",
    bindings: [.text(notebookId)]
  )
  return Int(rows.first?["next_note_number"] ?? "") ?? 1
}

func validateNotebookIngestPageNumbers(_ pages: [NotePageDraft]) throws {
  var explicitNumbers = Set<Int>()
  for page in pages {
    guard let noteNumber = page.noteNumber else {
      continue
    }
    guard noteNumber > 0 else {
      throw NoteServiceError.invalidInput("notebook ingest page numbers must be positive")
    }
    guard explicitNumbers.insert(noteNumber).inserted else {
      throw NoteServiceError.invalidInput("notebook ingest page numbers must be unique")
    }
  }
}

func noteTitle(from bodyMarkdown: String) -> String? {
  NoteTitleDerivation.title(from: bodyMarkdown)
}

func makeNoteId(prefix: String) -> String {
  let milliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
  return "\(prefix)-\(milliseconds)-\(UUID().uuidString.lowercased())"
}
