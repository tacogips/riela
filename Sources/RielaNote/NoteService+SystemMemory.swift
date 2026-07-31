import RielaSQLite

public extension NoteService {
  func systemMemoryNotebook() throws -> Notebook {
    try getNotebook(NoteStoreSchema.systemMemoryNotebookId)
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
