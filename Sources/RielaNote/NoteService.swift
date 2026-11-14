import Foundation
import RielaSQLite

public enum NoteServiceError: Error, Equatable, Sendable {
  case notFound(String)
  case readOnly(String)
  case protectedTag(String)
  case invalidInput(String)
  case invalidRow(String)
}

public struct NoteService: Sendable {
  public var driver: NoteDatabaseDriving
  public var autoActionDispatcher: AutoActionDispatching?
  public var autoActionDiagnosticRecorder: (any NoteAutoActionFilterDiagnosticRecording)?

  public init(
    driver: NoteDatabaseDriving,
    autoActionDispatcher: AutoActionDispatching? = nil,
    autoActionDiagnosticRecorder: (any NoteAutoActionFilterDiagnosticRecording)? = nil
  ) throws {
    self.driver = driver
    self.autoActionDispatcher = autoActionDispatcher
    self.autoActionDiagnosticRecorder = autoActionDiagnosticRecorder
    try NoteStoreSchema.prepare(on: driver)
    if autoActionDispatcher != nil {
      try? recoverInterruptedAutoActionDispatches()
      _ = try? retryPendingAutoActionDispatches()
    }
  }

  @discardableResult
  public func createNotebook(
    title: String,
    kindTagName: String? = nil,
    metaJSON: String? = nil,
    originatingActionId: String? = nil
  ) throws -> Notebook {
    let result = try driver.withDatabase { database in
      try database.transaction { db in
        let now = NoteStoreClock.system.now()
        let notebookId = makeNoteId(prefix: "notebook")
        try db.execute(
          """
          INSERT INTO notebooks (notebook_id, title, created_at, updated_at, meta_json)
          VALUES (?, ?, ?, ?, jsonb(?))
          """,
          bindings: [
            .text(notebookId),
            .text(title),
            .text(now),
            .text(now),
            .optionalText(metaJSON)
          ]
        )
        if let kindTagName {
          try ensureNotebookKindTag(kindTagName, in: db)
          try applyNotebookTag(
            notebookId: notebookId,
            tagName: kindTagName,
            provenance: .system,
            assignedBy: "riela-note",
            deletable: false,
            in: db
          )
        }
        let notebook = try requireNotebook(notebookId, in: db)
        let dispatches = try enqueueAutoActions(
          for: NoteAutoActionEvent(
            trigger: .notebookCreated,
            notebookId: notebook.notebookId,
            originatingActionId: originatingActionId
          ),
          in: db
        )
        return (notebook: notebook, dispatches: dispatches)
      }
    }
    dispatchQueuedAutoActions(result.dispatches)
    return result.notebook
  }

  @discardableResult
  public func createNote(
    notebookId requestedNotebookId: String? = nil,
    notebookTitle: String? = nil,
    title: String? = nil,
    bodyMarkdown: String,
    readOnly: Bool = false,
    tags: [NoteTagInput] = [],
    provenance: NoteProvenance = .human,
    assignedBy: String? = nil,
    metaJSON: String? = nil,
    originatingActionId: String? = nil
  ) throws -> Note {
    let result = try driver.withDatabase { database in
      try database.transaction { db in
        let now = NoteStoreClock.system.now()
        let notebookId: String
        let createdNotebookId: String?
        if let requestedNotebookId {
          _ = try requireNotebook(requestedNotebookId, in: db)
          notebookId = requestedNotebookId
          createdNotebookId = nil
        } else {
          let derivedTitle = title ?? noteTitle(from: bodyMarkdown) ?? notebookTitle ?? "Untitled"
          notebookId = makeNoteId(prefix: "notebook")
          createdNotebookId = notebookId
          try db.execute(
            """
            INSERT INTO notebooks (notebook_id, title, created_at, updated_at, meta_json)
            VALUES (?, ?, ?, ?, NULL)
            """,
            bindings: [.text(notebookId), .text(derivedTitle), .text(now), .text(now)]
          )
        }

        let noteNumber = try nextNoteNumber(notebookId: notebookId, in: db)
        let noteId = makeNoteId(prefix: "note")
        let noteTitle = title ?? noteTitle(from: bodyMarkdown)
        try db.execute(
          """
          INSERT INTO notes (
            note_id, notebook_id, note_number, title, body_markdown,
            read_only, created_at, updated_at, meta_json
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, jsonb(?))
          """,
          bindings: [
            .text(noteId),
            .text(notebookId),
            .int(Int64(noteNumber)),
            .optionalText(noteTitle),
            .text(bodyMarkdown),
            .int(readOnly ? 1 : 0),
            .text(now),
            .text(now),
            .optionalText(metaJSON)
          ]
        )
        try db.execute(
          "UPDATE notebooks SET updated_at = ? WHERE notebook_id = ?",
          bindings: [.text(now), .text(notebookId)]
        )
        for tag in tags {
          try applyTag(
            noteId: noteId,
            tag: tag,
            provenance: provenance,
            assignedBy: assignedBy,
            deletable: true,
            in: db
          )
        }
        try refreshFTS(noteId: noteId, previous: nil, in: db)
        let note = try requireNote(noteId, in: db)
        var dispatches: [QueuedAutoActionDispatch] = []
        if let createdNotebookId {
          dispatches.append(contentsOf: try enqueueAutoActions(
            for: NoteAutoActionEvent(
              trigger: .notebookCreated,
              notebookId: createdNotebookId,
              originatingActionId: originatingActionId
            ),
            in: db
          ))
        }
        dispatches.append(contentsOf: try enqueueAutoActions(
          for: NoteAutoActionEvent(
            trigger: .noteCreated,
            notebookId: note.notebookId,
            noteId: note.noteId,
            noteBodyMarkdown: note.bodyMarkdown,
            originatingActionId: originatingActionId
          ),
          in: db
        ))
        return (note: note, dispatches: dispatches)
      }
    }
    dispatchQueuedAutoActions(result.dispatches)
    return result.note
  }

  @discardableResult
  public func createNotebookWithNotes(
    title: String,
    kindTagName: String? = nil,
    metaJSON: String? = nil,
    pages: [NotePageDraft],
    provenance: NoteProvenance = .system,
    assignedBy: String? = "riela-note-ingest",
    originatingActionId: String? = nil
  ) throws -> NotebookIngestResult {
    guard !pages.isEmpty else {
      throw NoteServiceError.invalidInput("notebook ingest pages must not be empty")
    }
    try validateNotebookIngestPageNumbers(pages)
    let result = try driver.withDatabase { database in
      try database.transaction { db in
        try insertNotebookWithNotes(
          title: title,
          kindTagName: kindTagName,
          metaJSON: metaJSON,
          pages: pages,
          provenance: provenance,
          assignedBy: assignedBy,
          originatingActionId: originatingActionId,
          in: db
        )
      }
    }
    dispatchQueuedAutoActions(result.dispatches)
    return result.ingestResult
  }

  /// Inserts a notebook plus its notes against an already-open transaction `db`.
  ///
  /// This is the shared body extracted from `createNotebookWithNotes` (byte-for-byte
  /// behavior preserved). Callers that need to compose the notebook/note inserts with
  /// additional writes in the *same* transaction (e.g. `promoteCommentToNotebook`
  /// inlining a `note_links` INSERT) call this helper directly and dispatch the returned
  /// auto-actions after the transaction commits. Never open a nested transaction here.
  private func insertNotebookWithNotes(
    title: String,
    kindTagName: String?,
    metaJSON: String?,
    pages: [NotePageDraft],
    provenance: NoteProvenance,
    assignedBy: String?,
    originatingActionId: String?,
    in db: SQLiteDatabase
  ) throws -> (ingestResult: NotebookIngestResult, dispatches: [QueuedAutoActionDispatch]) {
    let now = NoteStoreClock.system.now()
    let notebookId = makeNoteId(prefix: "notebook")
    try db.execute(
      """
      INSERT INTO notebooks (notebook_id, title, created_at, updated_at, meta_json)
      VALUES (?, ?, ?, ?, jsonb(?))
      """,
      bindings: [
        .text(notebookId),
        .text(title),
        .text(now),
        .text(now),
        .optionalText(metaJSON)
      ]
    )
    if let kindTagName {
      try ensureNotebookKindTag(kindTagName, in: db)
      try applyNotebookTag(
        notebookId: notebookId,
        tagName: kindTagName,
        provenance: .system,
        assignedBy: "riela-note",
        deletable: false,
        in: db
      )
    }

    var notes: [Note] = []
    for (index, page) in pages.enumerated() {
      let noteNumber = page.noteNumber ?? index + 1
      let noteId = makeNoteId(prefix: "note")
      let noteTitle = noteTitle(from: page.bodyMarkdown)
      try db.execute(
        """
        INSERT INTO notes (
          note_id, notebook_id, note_number, title, body_markdown,
          read_only, created_at, updated_at, meta_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, jsonb(?))
        """,
        bindings: [
          .text(noteId),
          .text(notebookId),
          .int(Int64(noteNumber)),
          .optionalText(noteTitle),
          .text(page.bodyMarkdown),
          .int(page.readOnly ? 1 : 0),
          .text(now),
          .text(now),
          .optionalText(page.metaJSON)
        ]
      )
      for tag in page.tags {
        try applyTag(
          noteId: noteId,
          tag: tag,
          provenance: provenance,
          assignedBy: assignedBy,
          deletable: true,
          in: db
        )
      }
      try refreshFTS(noteId: noteId, previous: nil, in: db)
      notes.append(try requireNote(noteId, in: db))
    }
    let ingestResult = NotebookIngestResult(notebook: try requireNotebook(notebookId, in: db), notes: notes)
    var dispatches = try enqueueAutoActions(
      for: NoteAutoActionEvent(
        trigger: .notebookCreated,
        notebookId: ingestResult.notebook.notebookId,
        originatingActionId: originatingActionId
      ),
      in: db
    )
    for note in ingestResult.notes {
      dispatches.append(contentsOf: try enqueueAutoActions(
        for: NoteAutoActionEvent(
          trigger: .noteCreated,
          notebookId: ingestResult.notebook.notebookId,
          noteId: note.noteId,
          noteBodyMarkdown: note.bodyMarkdown,
          originatingActionId: originatingActionId
        ),
        in: db
      ))
    }
    return (ingestResult: ingestResult, dispatches: dispatches)
  }

  /// Promotes a note comment into a freshly created notebook whose first note carries the
  /// comment body, linking the source note to that new note — all in ONE transaction.
  ///
  /// The notebook/note inserts reuse `insertNotebookWithNotes(…, in: db)` and the
  /// `note_links` row is inlined (copied from `linkNotes`) against the same `db`, so a
  /// partial failure rolls the whole promotion back (SR-001). The two self-transacting
  /// public methods (`createNotebookWithNotes`, `linkNotes`) are intentionally NOT composed.
  @discardableResult
  public func promoteCommentToNotebook(
    noteId: String,
    commentId: String,
    notebookTitle: String? = nil,
    linkKind: String = "related",
    provenance: NoteProvenance = .human,
    assignedBy: String? = "riela-note-ui"
  ) throws -> (notebook: Notebook, note: Note) {
    let result = try driver.withDatabase { database in
      try database.transaction { db -> (notebook: Notebook, note: Note, dispatches: [QueuedAutoActionDispatch]) in
        _ = try requireNote(noteId, in: db)
        let commentRows = try db.query(
          """
          SELECT body_markdown
          FROM note_comments
          WHERE comment_id = ? AND note_id = ?
          LIMIT 1
          """,
          bindings: [.text(commentId), .text(noteId)]
        )
        guard let commentRow = commentRows.first,
              let commentBody = commentRow["body_markdown"] else {
          throw NoteServiceError.invalidInput("comment \(commentId) does not belong to note \(noteId)")
        }
        let resolvedTitle = promoteCommentNotebookTitle(explicit: notebookTitle, commentBody: commentBody)
        let inserted = try insertNotebookWithNotes(
          title: resolvedTitle,
          kindTagName: nil,
          metaJSON: nil,
          pages: [NotePageDraft(bodyMarkdown: commentBody, readOnly: false)],
          provenance: provenance,
          assignedBy: assignedBy,
          originatingActionId: nil,
          in: db
        )
        guard let newNote = inserted.ingestResult.notes.first else {
          throw NoteServiceError.invalidInput("promote produced no note for comment \(commentId)")
        }
        // Inlined from `linkNotes` (NoteService+Relations.swift) so the link is written in
        // the SAME transaction as the notebook/note inserts. Keep the ON CONFLICT upsert
        // guards verbatim.
        let now = NoteStoreClock.system.now()
        try db.execute(
          """
          INSERT INTO note_links (
            from_note_id, to_note_id, link_kind, provenance, created_at
          ) VALUES (?, ?, ?, ?, ?)
          ON CONFLICT(from_note_id, to_note_id, link_kind) DO UPDATE SET
            provenance = CASE
              WHEN note_links.provenance IN ('human', 'system')
                AND excluded.provenance = 'ai'
                THEN note_links.provenance
              ELSE excluded.provenance
            END,
            created_at = CASE
              WHEN note_links.provenance IN ('human', 'system')
                AND excluded.provenance = 'ai'
                THEN note_links.created_at
              ELSE excluded.created_at
            END
          """,
          bindings: [
            .text(noteId),
            .text(newNote.noteId),
            .text(linkKind),
            .text(provenance.rawValue),
            .text(now)
          ]
        )
        return (
          notebook: inserted.ingestResult.notebook,
          note: newNote,
          dispatches: inserted.dispatches
        )
      }
    }
    dispatchQueuedAutoActions(result.dispatches)
    return (notebook: result.notebook, note: result.note)
  }

  public func listNotebooks(
    limit: Int = 50,
    offset: Int = 0,
    tagFilter: [String] = [],
    sort: NoteListSort = .createdAtDesc,
    createdAfter: String? = nil,
    createdBefore: String? = nil
  ) throws -> [Notebook] {
    try driver.withDatabase { database in
      var predicates: [String] = []
      var bindings: [SQLiteValue] = []
      if !tagFilter.isEmpty {
        predicates.append(
          """
          EXISTS (
            SELECT 1
            FROM notebook_tags nt
            INNER JOIN tags t ON t.tag_id = nt.tag_id
            WHERE nt.notebook_id = notebooks.notebook_id
              AND t.name IN (\(placeholders(count: tagFilter.count)))
          )
          """
        )
        bindings.append(contentsOf: tagFilter.map(SQLiteValue.text))
      }
      appendCreatedAtPredicates(
        alias: "notebooks",
        createdAfter: createdAfter,
        createdBefore: createdBefore,
        predicates: &predicates,
        bindings: &bindings
      )
      let whereClause = predicates.isEmpty ? "" : "WHERE \(predicates.joined(separator: " AND "))"
      bindings.append(.int(Int64(limit)))
      bindings.append(.int(Int64(offset)))
      var notebooks = try database.query(
        """
        SELECT notebook_id, title, created_at, updated_at,
          CASE WHEN meta_json IS NULL THEN NULL ELSE json(meta_json) END AS meta_json
        FROM notebooks
        \(whereClause)
        ORDER BY \(notebookSortOrderClause(alias: "notebooks", sort: sort))
        LIMIT ? OFFSET ?
        """,
        bindings: bindings
      )
      .map { row in
        try notebook(from: row, in: database)
      }
      try enrichNotebookListMetadata(&notebooks, in: database)
      return notebooks
    }
  }

  public func getNotebook(_ notebookId: String) throws -> Notebook {
    try driver.withDatabase { database in
      try requireNotebook(notebookId, in: database)
    }
  }

  public func getNote(_ noteId: String) throws -> Note {
    try driver.withDatabase { database in
      try requireNote(noteId, in: database)
    }
  }

  public func listNotes(notebookId: String, limit: Int = 100, offset: Int = 0) throws -> [Note] {
    try driver.withDatabase { database in
      _ = try requireNotebook(notebookId, in: database)
      let rows = try database.query(
        """
        SELECT note_id, notebook_id, note_number, title, body_markdown, read_only,
          created_at, updated_at,
          CASE WHEN meta_json IS NULL THEN NULL ELSE json(meta_json) END AS meta_json
        FROM notes
        WHERE notebook_id = ?
        ORDER BY note_number, note_id
        LIMIT ? OFFSET ?
        """,
        bindings: [.text(notebookId), .int(Int64(limit)), .int(Int64(offset))]
      )
      return try notes(from: rows, in: database)
    }
  }

  public func listNotes(
    limit: Int = 100,
    offset: Int = 0,
    notebookId: String? = nil,
    tagFilter: [String] = []
  ) throws -> [Note] {
    try driver.withDatabase { database in
      var predicates: [String] = []
      var bindings: [SQLiteValue] = []
      if let notebookId {
        _ = try requireNotebook(notebookId, in: database)
        predicates.append("notebook_id = ?")
        bindings.append(.text(notebookId))
      }
      if !tagFilter.isEmpty {
        predicates.append(
          """
          EXISTS (
            SELECT 1
            FROM note_tags nt
            INNER JOIN tags t ON t.tag_id = nt.tag_id
            WHERE nt.note_id = notes.note_id
              AND t.name IN (\(placeholders(count: tagFilter.count)))
          )
          """
        )
        bindings.append(contentsOf: tagFilter.map(SQLiteValue.text))
      }
      let whereClause = predicates.isEmpty ? "" : "WHERE \(predicates.joined(separator: " AND "))"
      bindings.append(.int(Int64(limit)))
      bindings.append(.int(Int64(offset)))
      let rows = try database.query(
        """
        SELECT note_id, notebook_id, note_number, title, body_markdown, read_only,
          created_at, updated_at,
          CASE WHEN meta_json IS NULL THEN NULL ELSE json(meta_json) END AS meta_json
        FROM notes
        \(whereClause)
        ORDER BY created_at DESC, note_id
        LIMIT ? OFFSET ?
        """,
        bindings: bindings
      )
      return try notes(from: rows, in: database)
    }
  }

  @discardableResult
  public func updateNoteBody(
    noteId: String,
    bodyMarkdown: String,
    originatingActionId: String? = nil
  ) throws -> Note {
    let result = try driver.withDatabase { database in
      try database.transaction { db in
        let existing = try requireNote(noteId, in: db)
        guard !existing.readOnly else {
          throw NoteServiceError.readOnly(noteId)
        }
        let previous = try ftsPayload(noteId: noteId, in: db)
        let now = NoteStoreClock.system.now()
        let updatedTitle = noteTitle(from: bodyMarkdown) ?? existing.title
        try db.execute(
          """
          UPDATE notes
          SET title = ?, body_markdown = ?, updated_at = ?
          WHERE note_id = ?
          """,
          bindings: [
            .optionalText(updatedTitle),
            .text(bodyMarkdown),
            .text(now),
            .text(noteId)
          ]
        )
        try db.execute(
          "UPDATE notebooks SET updated_at = ? WHERE notebook_id = ?",
          bindings: [.text(now), .text(existing.notebookId)]
        )
        try refreshFTS(noteId: noteId, previous: previous, in: db)
        let note = try requireNote(noteId, in: db)
        let dispatches = try enqueueAutoActions(
          for: NoteAutoActionEvent(
            trigger: .noteUpdated,
            notebookId: note.notebookId,
            noteId: note.noteId,
            noteBodyMarkdown: note.bodyMarkdown,
            originatingActionId: originatingActionId
          ),
          in: db
        )
        return (note: note, dispatches: dispatches)
      }
    }
    dispatchQueuedAutoActions(result.dispatches)
    return result.note
  }

  @discardableResult
  public func setReadOnly(noteId: String, readOnly: Bool) throws -> Note {
    try driver.withDatabase { database in
      try database.transaction { db in
        _ = try requireNote(noteId, in: db)
        try db.execute(
          "UPDATE notes SET read_only = ?, updated_at = ? WHERE note_id = ?",
          bindings: [.int(readOnly ? 1 : 0), .text(NoteStoreClock.system.now()), .text(noteId)]
        )
        return try requireNote(noteId, in: db)
      }
    }
  }

  public func deleteNote(noteId: String) throws {
    try driver.withDatabase { database in
      try database.transaction { db in
        let note = try requireNote(noteId, in: db)
        guard !note.readOnly else {
          throw NoteServiceError.readOnly(noteId)
        }
        try deleteNoteRows(noteId: noteId, in: db)
        try db.execute(
          "UPDATE notebooks SET updated_at = ? WHERE notebook_id = ?",
          bindings: [.text(NoteStoreClock.system.now()), .text(note.notebookId)]
        )
      }
    }
  }

  public func deleteNotebook(notebookId: String) throws {
    try driver.withDatabase { database in
      try database.transaction { db in
        _ = try requireNotebook(notebookId, in: db)
        let notes = try db.query(
          "SELECT note_id, read_only FROM notes WHERE notebook_id = ? ORDER BY note_number",
          bindings: [.text(notebookId)]
        )
        if let readOnlyNoteId = notes.first(where: { $0["read_only"] == "1" })?["note_id"] {
          throw NoteServiceError.readOnly(readOnlyNoteId)
        }
        for row in notes {
          if let noteId = row["note_id"] {
            try deleteNoteRows(noteId: noteId, in: db)
          }
        }
        try db.execute("DELETE FROM notebook_tags WHERE notebook_id = ?", bindings: [.text(notebookId)])
        try db.execute("DELETE FROM notebook_files WHERE notebook_id = ?", bindings: [.text(notebookId)])
        try db.execute("DELETE FROM notebooks WHERE notebook_id = ?", bindings: [.text(notebookId)])
      }
    }
  }

  @discardableResult
  public func applyTags(
    noteId: String,
    tags: [NoteTagInput],
    provenance: NoteProvenance,
    assignedBy: String? = nil
  ) throws -> Note {
    try driver.withDatabase { database in
      try database.transaction { db in
        _ = try requireNote(noteId, in: db)
        let previous = try ftsPayload(noteId: noteId, in: db)
        for tag in tags {
          try applyTag(
            noteId: noteId,
            tag: tag,
            provenance: provenance,
            assignedBy: assignedBy,
            deletable: true,
            in: db
          )
        }
        try refreshFTS(noteId: noteId, previous: previous, in: db)
        return try requireNote(noteId, in: db)
      }
    }
  }

  @discardableResult
  public func removeTag(noteId: String, tagName: String, removedBy provenance: NoteProvenance) throws -> Note {
    try driver.withDatabase { database in
      try database.transaction { db in
        let existing = try tagAssignment(noteId: noteId, tagName: tagName, in: db)
        guard let existing else {
          return try requireNote(noteId, in: db)
        }
        guard existing.deletable else {
          throw NoteServiceError.protectedTag(tagName)
        }
        if provenance == .ai, existing.provenance == .human {
          throw NoteServiceError.protectedTag(tagName)
        }
        let previous = try ftsPayload(noteId: noteId, in: db)
        try db.execute(
          """
          DELETE FROM note_tags
          WHERE note_id = ? AND tag_id = ?
          """,
          bindings: [.text(noteId), .text(existing.tag.tagId)]
        )
        try refreshFTS(noteId: noteId, previous: previous, in: db)
        return try requireNote(noteId, in: db)
      }
    }
  }

  @discardableResult
  public func addComment(noteId: String, bodyMarkdown: String, author: String = "user") throws -> NoteComment {
    try driver.withDatabase { database in
      try database.transaction { db in
        _ = try requireNote(noteId, in: db)
        let now = NoteStoreClock.system.now()
        let commentId = makeNoteId(prefix: "comment")
        try db.execute(
          """
          INSERT INTO note_comments (comment_id, note_id, body_markdown, author, created_at)
          VALUES (?, ?, ?, ?, ?)
          """,
          bindings: [.text(commentId), .text(noteId), .text(bodyMarkdown), .text(author), .text(now)]
        )
        return NoteComment(
          commentId: commentId,
          noteId: noteId,
          bodyMarkdown: bodyMarkdown,
          author: author,
          createdAt: now
        )
      }
    }
  }

  public func searchNotes(
    query: String,
    tagFilter: [String] = [],
    classFilter: [String] = [],
    sort: NoteListSort = .createdAtDesc,
    createdAfter: String? = nil,
    createdBefore: String? = nil,
    includeLinked: Bool = false,
    limit: Int = 20,
    offset: Int = 0
  ) throws -> [NoteSearchResult] {
    try driver.withDatabase { database in
      try searchNotesInDatabase(
        query: query,
        tagFilter: tagFilter,
        classFilter: classFilter,
        sort: sort,
        createdAfter: createdAfter,
        createdBefore: createdBefore,
        includeLinked: includeLinked,
        limit: limit,
        offset: offset,
        in: database
      )
    }
  }
}

/// Resolves the title for a comment-promoted notebook: an explicit non-empty title wins,
/// otherwise the shared note-title heuristic on the comment body, falling back to
/// "Comment notebook". The result is capped at 120 characters.
func promoteCommentNotebookTitle(explicit: String?, commentBody: String) -> String {
  let trimmedExplicit = explicit?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  let base = trimmedExplicit.isEmpty
    ? (noteTitle(from: commentBody) ?? "Comment notebook")
    : trimmedExplicit
  return String(base.prefix(120))
}

private func ensureNotebookKindTag(_ tagName: String, in database: SQLiteDatabase) throws {
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

func applyNotebookTag(
  notebookId: String,
  tagName: String,
  provenance: NoteProvenance,
  assignedBy: String?,
  deletable: Bool,
  in database: SQLiteDatabase
) throws {
  try ensureTag(NoteTagInput(name: tagName), in: database)
  let tag = try requireTag(name: tagName, in: database)
  let existing = try notebookTagAssignment(notebookId: notebookId, tagName: tagName, in: database)
  if let existing, existing.provenance == .system, provenance != .system {
    return
  }
  try database.execute(
    """
    INSERT INTO notebook_tags (
      notebook_id, tag_id, provenance, assigned_by, deletable, created_at
    ) VALUES (?, ?, ?, ?, ?, ?)
    ON CONFLICT(notebook_id, tag_id) DO UPDATE SET
      provenance = CASE
        WHEN notebook_tags.provenance = 'system' THEN notebook_tags.provenance
        ELSE excluded.provenance
      END,
      assigned_by = CASE
        WHEN notebook_tags.provenance = 'system' THEN notebook_tags.assigned_by
        ELSE excluded.assigned_by
      END,
      deletable = CASE
        WHEN notebook_tags.deletable = 0 THEN 0
        ELSE excluded.deletable
      END
    """,
    bindings: [
      .text(notebookId),
      .text(tag.tagId),
      .text(provenance.rawValue),
      .optionalText(assignedBy),
      .int(deletable ? 1 : 0),
      .text(NoteStoreClock.system.now())
    ]
  )
}

private func applyTag(
  noteId: String,
  tag: NoteTagInput,
  provenance: NoteProvenance,
  assignedBy: String?,
  deletable: Bool,
  in database: SQLiteDatabase
) throws {
  try ensureTag(tag, in: database)
  let existing = try tagAssignment(noteId: noteId, tagName: tag.name, in: database)
  if let existing, existing.provenance == .human, provenance == .ai {
    return
  }
  if let existing, existing.provenance == .system, provenance != .system {
    return
  }
  let storedTag = try requireTag(name: tag.name, in: database)
  try database.execute(
    """
    INSERT INTO note_tags (
      note_id, tag_id, provenance, assigned_by, deletable, created_at
    ) VALUES (?, ?, ?, ?, ?, ?)
    ON CONFLICT(note_id, tag_id) DO UPDATE SET
      provenance = CASE
        WHEN note_tags.provenance = 'system' THEN note_tags.provenance
        ELSE excluded.provenance
      END,
      assigned_by = CASE
        WHEN note_tags.provenance = 'system' THEN note_tags.assigned_by
        ELSE excluded.assigned_by
      END,
      deletable = CASE
        WHEN note_tags.deletable = 0 THEN 0
        ELSE excluded.deletable
      END
    """,
    bindings: [
      .text(noteId),
      .text(storedTag.tagId),
      .text(provenance.rawValue),
      .optionalText(assignedBy),
      .int(deletable ? 1 : 0),
      .text(NoteStoreClock.system.now())
    ]
  )
}

private func ensureTag(_ tag: NoteTagInput, in database: SQLiteDatabase) throws {
  if let classId = tag.classId?.trimmingCharacters(in: .whitespacesAndNewlines), !classId.isEmpty {
    _ = try requireTagClass(classId: classId, in: database)
  }
  try database.execute(
    """
    INSERT INTO tags (tag_id, name, class_id, is_system, created_at)
    VALUES (?, ?, ?, 0, ?)
    ON CONFLICT(name) DO UPDATE SET
      class_id = coalesce(tags.class_id, excluded.class_id)
    """,
    bindings: [
      .text(makeNoteId(prefix: "tag")),
      .text(tag.name),
      .optionalText(tag.classId),
      .text(NoteStoreClock.system.now())
    ]
  )
}

private func deleteNoteRows(noteId: String, in database: SQLiteDatabase) throws {
  if let previous = try ftsPayload(noteId: noteId, in: database) {
    try database.execute(
      """
      INSERT INTO note_fts(note_fts, rowid, title, body, tags)
      VALUES('delete', ?, ?, ?, ?)
      """,
      bindings: [.int(previous.rowId), .text(previous.title), .text(previous.body), .text(previous.tags)]
    )
  }
  try database.execute("DELETE FROM note_fts_map WHERE note_id = ?", bindings: [.text(noteId)])
  try database.execute("DELETE FROM note_tags WHERE note_id = ?", bindings: [.text(noteId)])
  try database.execute("DELETE FROM note_files WHERE note_id = ?", bindings: [.text(noteId)])
  try database.execute(
    "DELETE FROM note_links WHERE from_note_id = ? OR to_note_id = ?",
    bindings: [.text(noteId), .text(noteId)]
  )
  try database.execute("DELETE FROM note_comments WHERE note_id = ?", bindings: [.text(noteId)])
  try database.execute("DELETE FROM notes WHERE note_id = ?", bindings: [.text(noteId)])
}

func requireNotebook(_ notebookId: String, in database: SQLiteDatabase) throws -> Notebook {
  let rows = try database.query(
    """
    SELECT notebook_id, title, created_at, updated_at,
      CASE WHEN meta_json IS NULL THEN NULL ELSE json(meta_json) END AS meta_json
    FROM notebooks
    WHERE notebook_id = ?
    LIMIT 1
    """,
    bindings: [.text(notebookId)]
  )
  guard let row = rows.first else {
    throw NoteServiceError.notFound("notebook not found: \(notebookId)")
  }
  var notebook = try notebook(from: row, in: database)
  try enrichNotebookListMetadata(&notebook, in: database)
  return notebook
}

func requireNote(_ noteId: String, in database: SQLiteDatabase) throws -> Note {
  let rows = try database.query(
    """
    SELECT note_id, notebook_id, note_number, title, body_markdown, read_only,
      created_at, updated_at,
      CASE WHEN meta_json IS NULL THEN NULL ELSE json(meta_json) END AS meta_json
    FROM notes
    WHERE note_id = ?
    LIMIT 1
    """,
    bindings: [.text(noteId)]
  )
  guard let row = rows.first else {
    throw NoteServiceError.notFound("note not found: \(noteId)")
  }
  return try note(from: row, in: database)
}

func requireNotes(_ noteIds: [String], in database: SQLiteDatabase) throws -> [String: Note] {
  let orderedNoteIds = orderedUnique(noteIds)
  guard !orderedNoteIds.isEmpty else {
    return [:]
  }
  let rows = try database.query(
    """
    SELECT note_id, notebook_id, note_number, title, body_markdown, read_only,
      created_at, updated_at,
      CASE WHEN meta_json IS NULL THEN NULL ELSE json(meta_json) END AS meta_json
    FROM notes
    WHERE note_id IN (\(placeholders(count: orderedNoteIds.count)))
    """,
    bindings: orderedNoteIds.map(SQLiteValue.text)
  )
  let hydratedNotes = try notes(from: rows, in: database)
  var notesById: [String: Note] = [:]
  notesById.reserveCapacity(hydratedNotes.count)
  for note in hydratedNotes {
    notesById[note.noteId] = note
  }
  return notesById
}

private func requireTag(name: String, in database: SQLiteDatabase) throws -> Tag {
  let rows = try database.query(
    "SELECT tag_id, name, class_id, is_system, created_at FROM tags WHERE name = ? LIMIT 1",
    bindings: [.text(name)]
  )
  guard let row = rows.first else {
    throw NoteServiceError.notFound("tag not found: \(name)")
  }
  return try tag(from: row)
}

private func notebook(from row: SQLiteRow, in database: SQLiteDatabase) throws -> Notebook {
  guard let notebookId = row["notebook_id"],
        let title = row["title"],
        let createdAt = row["created_at"],
        let updatedAt = row["updated_at"] else {
    throw NoteServiceError.invalidRow("notebook row is missing required fields")
  }
  return Notebook(
    notebookId: notebookId,
    title: title,
    createdAt: createdAt,
    updatedAt: updatedAt,
    metaJSON: row["meta_json"] ?? nil,
    tags: try notebookTags(notebookId: notebookId, in: database)
  )
}

private func note(from row: SQLiteRow, in database: SQLiteDatabase) throws -> Note {
  guard let noteId = row["note_id"] else {
    throw NoteServiceError.invalidRow("note row is missing note_id")
  }
  return try note(from: row, tags: noteTags(noteId: noteId, in: database))
}

private func notes(from rows: [SQLiteRow], in database: SQLiteDatabase) throws -> [Note] {
  let noteIds = rows.compactMap { $0["note_id"] }
  let tagsByNoteId = try noteTags(noteIds: noteIds, in: database)
  return try rows.map { row in
    guard let noteId = row["note_id"] else {
      throw NoteServiceError.invalidRow("note row is missing note_id")
    }
    return try note(from: row, tags: tagsByNoteId[noteId] ?? [])
  }
}

private func note(from row: SQLiteRow, tags: [TagAssignment]) throws -> Note {
  guard let noteId = row["note_id"],
        let notebookId = row["notebook_id"],
        let noteNumberText = row["note_number"],
        let noteNumber = Int(noteNumberText),
        let bodyMarkdown = row["body_markdown"],
        let createdAt = row["created_at"],
        let updatedAt = row["updated_at"] else {
    throw NoteServiceError.invalidRow("note row is missing required fields")
  }
  return Note(
    noteId: noteId,
    notebookId: notebookId,
    noteNumber: noteNumber,
    title: row["title"] ?? nil,
    bodyMarkdown: bodyMarkdown,
    readOnly: row["read_only"] == "1",
    createdAt: createdAt,
    updatedAt: updatedAt,
    metaJSON: row["meta_json"] ?? nil,
    tags: tags
  )
}

func tag(from row: SQLiteRow) throws -> Tag {
  guard let tagId = row["tag_id"],
        let name = row["name"],
        let createdAt = row["created_at"] else {
    throw NoteServiceError.invalidRow("tag row is missing required fields")
  }
  return Tag(
    tagId: tagId,
    name: name,
    classId: row["class_id"] ?? nil,
    isSystem: row["is_system"] == "1",
    createdAt: createdAt
  )
}
