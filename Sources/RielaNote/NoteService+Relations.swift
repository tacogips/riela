import Foundation
import RielaSQLite

public extension NoteService {
  @discardableResult
  func linkNotes(
    from fromNoteId: String,
    to toNoteId: String,
    linkKind: String = "related",
    provenance: NoteProvenance = .human
  ) throws -> NoteLink {
    try driver.withDatabase { database in
      try database.transaction { db in
        try linkNotesInDatabase(
          from: fromNoteId,
          to: toNoteId,
          linkKind: linkKind,
          provenance: provenance,
          in: db
        )
      }
    }
  }

  func listLinks(noteId: String) throws -> [NoteLink] {
    try driver.withDatabase { database in
      _ = try requireNote(noteId, in: database)
      return try database.query(
        """
        SELECT from_note_id, to_note_id, link_kind, provenance, created_at
        FROM note_links
        WHERE from_note_id = ? OR to_note_id = ?
        ORDER BY created_at, from_note_id, to_note_id
        """,
        bindings: [.text(noteId), .text(noteId)]
      ).map(noteLink(from:))
    }
  }

  func proposeLinks(noteId: String, limit: Int = 8) throws -> [NoteLinkProposal] {
    try driver.withDatabase { database in
      let note = try requireNote(noteId, in: database)
      let links = try database.query(
        """
        SELECT from_note_id, to_note_id, link_kind, provenance, created_at
        FROM note_links
        WHERE from_note_id = ? OR to_note_id = ?
        """,
        bindings: [.text(noteId), .text(noteId)]
      ).map(noteLink(from:))
      let excludedIds = Set(links.map { $0.counterpartNoteId(for: noteId) } + [noteId])
      let terms = linkProposalTerms(from: note.bodyMarkdown)
      guard !terms.isEmpty else {
        return []
      }
      var proposals: [NoteLinkProposal] = []
      var seenIds = excludedIds
      for term in terms {
        let results = try searchNotesInDatabase(
          query: term,
          tagFilter: [],
          classFilter: [],
          sort: .createdAtDesc,
          createdAfter: nil,
          createdBefore: nil,
          includeLinked: false,
          limit: max(limit * 2, 10),
          offset: 0,
          in: database
        )
        for result in results where seenIds.insert(result.note.noteId).inserted {
          proposals.append(NoteLinkProposal(
            targetNote: result.note,
            linkKind: "related",
            reason: "Shares the term \"\(term)\" with this note."
          ))
          if proposals.count >= limit {
            return proposals
          }
        }
      }
      return proposals
    }
  }

  func listComments(noteId: String) throws -> [NoteComment] {
    try driver.withDatabase { database in
      _ = try requireNote(noteId, in: database)
      return try database.query(
        """
        SELECT comment_id, note_id, body_markdown, author, created_at
        FROM note_comments
        WHERE note_id = ?
        ORDER BY created_at, comment_id
        """,
        bindings: [.text(noteId)]
      ).map(noteComment(from:))
    }
  }

  @discardableResult
  func appendConversationTurn(
    notebookId: String,
    turn: NoteConversationTurn,
    sourceLinks: NoteConversationSourceLinks? = nil,
    assignedBy: String? = nil,
    originatingActionId: String? = nil
  ) throws -> Note {
    let result = try driver.withDatabase { database in
      try database.transaction { db in
        _ = try requireNotebook(notebookId, in: db)
        let note = try appendConversationTurnInDatabase(
          notebookId: notebookId,
          turn: turn,
          sourceLinks: sourceLinks,
          assignedBy: assignedBy,
          in: db
        )
        let dispatches = try enqueueAutoActions(
          for: NoteAutoActionEvent(
            trigger: .noteCreated,
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
  func saveConversation(
    title conversationTitle: String,
    transcript: [NoteConversationTurn],
    notebookMetaJSON: String? = nil,
    sourceLinks: NoteConversationSourceLinks? = nil,
    assignedBy: String? = nil,
    originatingActionId: String? = nil
  ) throws -> SavedConversation {
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
            .text(conversationTitle),
            .text(now),
            .text(now),
            .optionalText(notebookMetaJSON)
          ]
        )
        try applyConversationNotebookKind(notebookId: notebookId, assignedBy: assignedBy, in: db)

        var notes: [Note] = []
        for turn in transcript {
          notes.append(
            try appendConversationTurnInDatabase(
              notebookId: notebookId,
              turn: turn,
              sourceLinks: sourceLinks,
              assignedBy: assignedBy,
              in: db
            )
          )
        }
        let notebook = try requireNotebook(notebookId, in: db)
        let saved = SavedConversation(notebook: notebook, notes: notes)
        var dispatches = try enqueueAutoActions(
          for: NoteAutoActionEvent(
            trigger: .notebookCreated,
            notebookId: notebook.notebookId,
            originatingActionId: originatingActionId
          ),
          in: db
        )
        for note in notes {
          dispatches.append(contentsOf: try enqueueAutoActions(
            for: NoteAutoActionEvent(
              trigger: .noteCreated,
              notebookId: notebook.notebookId,
              noteId: note.noteId,
              noteBodyMarkdown: note.bodyMarkdown,
              originatingActionId: originatingActionId
            ),
            in: db
          ))
        }
        return (saved: saved, dispatches: dispatches)
      }
    }
    dispatchQueuedAutoActions(result.dispatches)
    return result.saved
  }
}

private func appendConversationTurnInDatabase(
  notebookId: String,
  turn: NoteConversationTurn,
  sourceLinks: NoteConversationSourceLinks?,
  assignedBy: String?,
  in database: SQLiteDatabase
) throws -> Note {
  for sourceNoteId in turn.sourceNoteIds {
    _ = try requireNote(sourceNoteId, in: database)
  }
  if let sourceLinks {
    for sourceNoteId in sourceLinks.sourceNoteIds {
      _ = try requireNote(sourceNoteId, in: database)
    }
  }
  let now = NoteStoreClock.system.now()
  let noteNumber = try nextNoteNumber(notebookId: notebookId, in: database)
  let bodyMarkdown = conversationBody(turn: turn, noteNumber: noteNumber)
  let noteId = makeNoteId(prefix: "note")
  try database.execute(
    """
    INSERT INTO notes (
      note_id, notebook_id, note_number, title, body_markdown,
      read_only, created_at, updated_at, meta_json
    ) VALUES (?, ?, ?, ?, ?, 0, ?, ?, NULL)
    """,
    bindings: [
      .text(noteId),
      .text(notebookId),
      .int(Int64(noteNumber)),
      .optionalText(noteTitle(from: bodyMarkdown)),
      .text(bodyMarkdown),
      .text(now),
      .text(now)
    ]
  )
  for sourceNoteId in turn.sourceNoteIds {
    _ = try linkNotesInDatabase(
      from: noteId,
      to: sourceNoteId,
      linkKind: "source-citation",
      provenance: .system,
      in: database
    )
  }
  if let sourceLinks {
    for sourceNoteId in sourceLinks.sourceNoteIds {
      _ = try linkNotesInDatabase(
        from: noteId,
        to: sourceNoteId,
        linkKind: sourceLinks.linkKind,
        provenance: sourceLinks.provenance,
        in: database
      )
    }
  }
  try database.execute(
    "UPDATE notebooks SET updated_at = ? WHERE notebook_id = ?",
    bindings: [.text(now), .text(notebookId)]
  )
  try refreshFTS(noteId: noteId, previous: nil, in: database)
  return try requireNote(noteId, in: database)
}

@discardableResult
func linkNotesInDatabase(
  from fromNoteId: String,
  to toNoteId: String,
  linkKind: String,
  provenance: NoteProvenance,
  in database: SQLiteDatabase
) throws -> NoteLink {
  // Bind link_kind verbatim (no trimming / emptiness check) so this shared
  // helper preserves the exact behavior of the public `linkNotes` mutation it
  // was extracted from. The conversation source-link callers always pass a
  // controlled, non-empty kind, so they need no additional validation here.
  _ = try requireNote(fromNoteId, in: database)
  _ = try requireNote(toNoteId, in: database)
  let now = NoteStoreClock.system.now()
  try database.execute(
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
      .text(fromNoteId),
      .text(toNoteId),
      .text(linkKind),
      .text(provenance.rawValue),
      .text(now)
    ]
  )
  return try requireNoteLink(from: fromNoteId, to: toNoteId, linkKind: linkKind, in: database)
}

private func applyConversationNotebookKind(
  notebookId: String,
  assignedBy: String?,
  in database: SQLiteDatabase
) throws {
  let tagRows = try database.query(
    """
    SELECT tag_id
    FROM tags
    WHERE name = 'notebook-kind:agent-conversation'
    LIMIT 1
    """
  )
  guard let tagId = tagRows.first?["tag_id"] else {
    throw NoteServiceError.notFound("system tag not found: notebook-kind:agent-conversation")
  }
  try database.execute(
    """
    INSERT INTO notebook_tags (
      notebook_id, tag_id, provenance, assigned_by, deletable, created_at
    ) VALUES (?, ?, 'system', ?, 0, ?)
    ON CONFLICT(notebook_id, tag_id) DO NOTHING
    """,
    bindings: [
      .text(notebookId),
      .text(tagId),
      .optionalText(assignedBy ?? "riela-note"),
      .text(NoteStoreClock.system.now())
    ]
  )
}

private func conversationBody(turn: NoteConversationTurn, noteNumber: Int) -> String {
  """
  # Conversation Turn \(noteNumber)

  ## User
  \(turn.userMarkdown)

  ## Agent
  \(turn.assistantMarkdown)
  """
}

private func noteLink(from row: SQLiteRow) throws -> NoteLink {
  guard let fromNoteId = row["from_note_id"],
        let toNoteId = row["to_note_id"],
        let linkKind = row["link_kind"],
        let provenanceText = row["provenance"],
        let provenance = NoteProvenance(rawValue: provenanceText),
        let createdAt = row["created_at"] else {
    throw NoteServiceError.invalidRow("note link row is missing required fields")
  }
  return NoteLink(
    fromNoteId: fromNoteId,
    toNoteId: toNoteId,
    linkKind: linkKind,
    provenance: provenance,
    createdAt: createdAt
  )
}

private func requireNoteLink(
  from fromNoteId: String,
  to toNoteId: String,
  linkKind: String,
  in database: SQLiteDatabase
) throws -> NoteLink {
  let rows = try database.query(
    """
    SELECT from_note_id, to_note_id, link_kind, provenance, created_at
    FROM note_links
    WHERE from_note_id = ? AND to_note_id = ? AND link_kind = ?
    LIMIT 1
    """,
    bindings: [.text(fromNoteId), .text(toNoteId), .text(linkKind)]
  )
  guard let row = rows.first else {
    throw NoteServiceError.notFound("note link not found: \(fromNoteId) -> \(toNoteId) (\(linkKind))")
  }
  return try noteLink(from: row)
}

private func noteComment(from row: SQLiteRow) throws -> NoteComment {
  guard let commentId = row["comment_id"],
        let noteId = row["note_id"],
        let bodyMarkdown = row["body_markdown"],
        let author = row["author"],
        let createdAt = row["created_at"] else {
    throw NoteServiceError.invalidRow("note comment row is missing required fields")
  }
  return NoteComment(
    commentId: commentId,
    noteId: noteId,
    bodyMarkdown: bodyMarkdown,
    author: author,
    createdAt: createdAt
  )
}

private extension NoteLink {
  func counterpartNoteId(for noteId: String) -> String {
    fromNoteId == noteId ? toNoteId : fromNoteId
  }
}

private func linkProposalTerms(from bodyMarkdown: String) -> [String] {
  var seen = Set<String>()
  var terms: [String] = []
  var current = String.UnicodeScalarView()
  func flushCurrentTerm() {
    let term = String(current).trimmingCharacters(in: .whitespacesAndNewlines)
    current.removeAll(keepingCapacity: true)
    guard term.count >= 4, seen.insert(term.lowercased()).inserted else {
      return
    }
    terms.append(term)
  }
  for scalar in bodyMarkdown.unicodeScalars {
    if CharacterSet.alphanumerics.contains(scalar) {
      current.append(scalar)
    } else {
      flushCurrentTerm()
    }
    if terms.count >= 8 {
      break
    }
  }
  if terms.count < 8 {
    flushCurrentTerm()
  }
  return terms
}
