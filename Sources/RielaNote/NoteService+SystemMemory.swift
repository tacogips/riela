import Foundation
import RielaSQLite

public extension NoteService {
  func systemMemoryNotebook() throws -> Notebook {
    try getNotebook(NoteStoreSchema.systemMemoryNotebookId)
  }

  func searchSystemMemoryNotes(
    query: String = "",
    namespace: String? = nil,
    tagFilter: [String] = [],
    limit: Int = 20
  ) throws -> [Note] {
    guard limit > 0 else { return [] }
    let normalizedNamespace = namespace?.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedTags = orderedUnique(tagFilter.compactMap { rawValue in
      let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
      return value.isEmpty ? nil : value
    })
    return try driver.withDatabase { database in
      let notebook = try requireNotebook(NoteStoreSchema.systemMemoryNotebookId, in: database)
      guard notebook.tags.contains(where: { $0.tag.name == NoteStoreSchema.systemMemoryNotebookKindTag }) else {
        throw NoteServiceError.invalidInput("reserved system-memory notebook is missing its kind tag")
      }
      var predicates = ["n.notebook_id = ?"]
      var bindings: [SQLiteValue] = [.text(NoteStoreSchema.systemMemoryNotebookId)]
      if let normalizedNamespace, !normalizedNamespace.isEmpty {
        predicates.append(systemMemoryTagPredicate(alias: "n"))
        bindings.append(.text("memory-namespace:\(normalizedNamespace)"))
      }
      if !normalizedTags.isEmpty {
        predicates.append(
          """
          EXISTS (
            SELECT 1
            FROM note_tags nt
            INNER JOIN tags t ON t.tag_id = nt.tag_id
            WHERE nt.note_id = n.note_id
              AND t.name IN (\(placeholders(count: normalizedTags.count)))
          )
          """
        )
        bindings.append(contentsOf: normalizedTags.map(SQLiteValue.text))
      }
      let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
      if !normalizedQuery.isEmpty {
        let pattern = "%\(escapedSystemMemoryLikePattern(normalizedQuery))%"
        predicates.append(
          """
          (
            coalesce(n.title, '') LIKE ? ESCAPE '\\'
            OR n.body_markdown LIKE ? ESCAPE '\\'
            OR EXISTS (
              SELECT 1
              FROM note_tags nt
              INNER JOIN tags t ON t.tag_id = nt.tag_id
              WHERE nt.note_id = n.note_id
                AND t.name LIKE ? ESCAPE '\\'
            )
          )
          """
        )
        bindings.append(contentsOf: [.text(pattern), .text(pattern), .text(pattern)])
      }
      bindings.append(.int(Int64(limit)))
      let rows = try database.query(
        """
        SELECT n.note_id
        FROM notes n
        WHERE \(predicates.joined(separator: " AND "))
        ORDER BY n.created_at DESC, n.note_number DESC, n.note_id DESC
        LIMIT ?
        """,
        bindings: bindings
      )
      let noteIds = rows.compactMap { $0["note_id"] }
      let notesById = try requireNotes(noteIds, in: database)
      return try noteIds.map { noteId in
        guard let note = notesById[noteId] else {
          throw NoteServiceError.notFound("note not found: \(noteId)")
        }
        return note
      }
    }
  }

  @discardableResult
  func setNotebookReadOnly(notebookId: String, readOnly: Bool) throws -> Notebook {
    try driver.withDatabase { database in
      try database.transaction { db in
        _ = try requireNotebook(notebookId, in: db)
        try db.execute(
          "UPDATE notebooks SET read_only = ?, updated_at = ? WHERE notebook_id = ?",
          bindings: [
            .int(readOnly ? 1 : 0),
            .text(NoteStoreClock.system.now()),
            .text(notebookId)
          ]
        )
        return try requireNotebook(notebookId, in: db)
      }
    }
  }

  @discardableResult
  func saveSystemMemoryNote(
    title: String? = nil,
    bodyMarkdown: String,
    tags: [NoteTagInput] = [],
    metaJSON: String? = nil,
    assignedBy: String? = "riela-system-memory"
  ) throws -> Note {
    try driver.withDatabase { database in
      try database.transaction { db in
        let notebook = try requireNotebook(NoteStoreSchema.systemMemoryNotebookId, in: db)
        guard notebook.tags.contains(where: { $0.tag.name == NoteStoreSchema.systemMemoryNotebookKindTag }) else {
          throw NoteServiceError.invalidInput("reserved system-memory notebook is missing its kind tag")
        }
        let now = NoteStoreClock.system.now()
        let noteId = makeNoteId(prefix: "note")
        let noteNumber = try nextNoteNumber(notebookId: notebook.notebookId, in: db)
        let resolvedTitle = title ?? noteTitle(from: bodyMarkdown)
        let titleSource: NoteTitleSource = title == nil ? .derived : .explicit
        try db.execute(
          """
          INSERT INTO notes (
            note_id, notebook_id, note_number, title, title_source, body_markdown,
            read_only, created_at, updated_at, meta_json
          ) VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, jsonb(?))
          """,
          bindings: [
            .text(noteId),
            .text(notebook.notebookId),
            .int(Int64(noteNumber)),
            .optionalText(resolvedTitle),
            .text(titleSource.rawValue),
            .text(bodyMarkdown),
            .text(now),
            .text(now),
            .optionalText(metaJSON)
          ]
        )
        for tag in tags {
          try applyTag(
            noteId: noteId,
            tag: tag,
            provenance: .system,
            assignedBy: assignedBy,
            deletable: true,
            in: db
          )
        }
        try db.execute(
          "UPDATE notebooks SET updated_at = ? WHERE notebook_id = ?",
          bindings: [.text(now), .text(notebook.notebookId)]
        )
        try refreshFTS(noteId: noteId, previous: nil, in: db)
        return try requireNote(noteId, in: db)
      }
    }
  }

  @discardableResult
  func updateSystemMemoryNote(
    noteId: String,
    bodyMarkdown: String,
    metaJSON: String? = nil
  ) throws -> Note {
    try driver.withDatabase { database in
      try database.transaction { db in
        let existing = try requireNote(noteId, in: db)
        guard existing.notebookId == NoteStoreSchema.systemMemoryNotebookId else {
          throw NoteServiceError.invalidInput("system-memory update target is outside the reserved notebook")
        }
        guard !existing.readOnly else {
          throw NoteServiceError.readOnly(existing.noteId)
        }
        let previous = try ftsPayload(noteId: noteId, in: db)
        let now = NoteStoreClock.system.now()
        let titleSource = try noteTitleSource(noteId: noteId, in: db)
        let updatedTitle = titleSource == .explicit
          ? existing.title
          : (noteTitle(from: bodyMarkdown) ?? existing.title)
        try db.execute(
          """
          UPDATE notes
          SET title = ?, body_markdown = ?, meta_json = jsonb(?), updated_at = ?
          WHERE note_id = ?
          """,
          bindings: [
            .optionalText(updatedTitle),
            .text(bodyMarkdown),
            .optionalText(metaJSON ?? existing.metaJSON),
            .text(now),
            .text(noteId)
          ]
        )
        try db.execute(
          "UPDATE notebooks SET updated_at = ? WHERE notebook_id = ?",
          bindings: [.text(now), .text(existing.notebookId)]
        )
        try refreshFTS(noteId: noteId, previous: previous, in: db)
        return try requireNote(noteId, in: db)
      }
    }
  }

  func rollbackSystemMemoryNotes(noteIds: [String]) throws {
    let uniqueNoteIds = orderedUnique(noteIds)
    guard !uniqueNoteIds.isEmpty else { return }
    let deletedFiles = try driver.withDatabase { database in
      try database.transaction { db in
        for noteId in uniqueNoteIds {
          let note = try requireNote(noteId, in: db)
          guard note.notebookId == NoteStoreSchema.systemMemoryNotebookId else {
            throw NoteServiceError.invalidInput("system-memory rollback target is outside the reserved notebook")
          }
        }
        let rows = try db.query(
          """
          SELECT DISTINCT f.file_id, f.storage_kind, f.local_path, f.s3_profile, f.s3_bucket, f.s3_key,
            f.media_type, f.byte_size, f.sha256, f.original_filename, f.created_at, f.migrated_at
          FROM files f
          INNER JOIN note_files nf ON nf.file_id = f.file_id
          WHERE nf.note_id IN (\(placeholders(count: uniqueNoteIds.count)))
          """,
          bindings: uniqueNoteIds.map(SQLiteValue.text)
        )
        let candidates = try rows.map(fileRecord(from:))
        for noteId in uniqueNoteIds {
          try deleteNoteRows(noteId: noteId, in: db)
        }
        var deleted: [FileRecord] = []
        for record in candidates {
          let stillReferenced = try db.query(
            """
            SELECT 1
            WHERE EXISTS (SELECT 1 FROM note_files WHERE file_id = ?)
               OR EXISTS (SELECT 1 FROM notebook_files WHERE file_id = ?)
            LIMIT 1
            """,
            bindings: [.text(record.fileId), .text(record.fileId)]
          ).first != nil
          guard !stillReferenced else { continue }
          try db.execute("DELETE FROM files WHERE file_id = ?", bindings: [.text(record.fileId)])
          deleted.append(record)
        }
        try db.execute(
          "UPDATE notebooks SET updated_at = ? WHERE notebook_id = ?",
          bindings: [.text(NoteStoreClock.system.now()), .text(NoteStoreSchema.systemMemoryNotebookId)]
        )
        return deleted
      }
    }
    let localStore = LocalNoteFileStore(noteRoot: noteRootPath())
    for record in deletedFiles where record.storageKind == .local {
      try localStore.delete(record: record)
    }
  }
}

private func systemMemoryTagPredicate(alias: String) -> String {
  """
  EXISTS (
    SELECT 1
    FROM note_tags nt
    INNER JOIN tags t ON t.tag_id = nt.tag_id
    WHERE nt.note_id = \(alias).note_id
      AND t.name = ?
  )
  """
}

private func escapedSystemMemoryLikePattern(_ value: String) -> String {
  value
    .replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "%", with: "\\%")
    .replacingOccurrences(of: "_", with: "\\_")
}

func requireNotebookContentWritable(_ notebook: Notebook) throws {
  guard !notebook.readOnly else {
    throw NoteServiceError.readOnly(notebook.notebookId)
  }
}

func requireNoteContentWritable(_ note: Note, in database: SQLiteDatabase) throws {
  guard !note.readOnly else {
    throw NoteServiceError.readOnly(note.noteId)
  }
  try requireNotebookContentWritable(requireNotebook(note.notebookId, in: database))
}

func requireNoteNotebookContentWritable(_ note: Note, in database: SQLiteDatabase) throws {
  try requireNotebookContentWritable(requireNotebook(note.notebookId, in: database))
}
