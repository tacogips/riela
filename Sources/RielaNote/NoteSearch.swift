import Foundation
import RielaSQLite

struct FTSPayload {
  var rowId: Int64
  var title: String
  var body: String
  var tags: String
}

func searchNotesInDatabase(
  query: String,
  tagFilter: [String],
  classFilter: [String],
  limit: Int,
  offset: Int,
  in database: SQLiteDatabase
) throws -> [NoteSearchResult] {
  let requestedLimit = max(0, limit)
  let requestedOffset = max(0, offset)
  let fetchLimit = requestedLimit + requestedOffset
  guard fetchLimit > 0 else {
    return []
  }
  guard let matchQuery = ftsMatchQuery(from: query) else {
    let results = try searchNotesByFilters(
      tagFilter: tagFilter,
      classFilter: classFilter,
      limit: fetchLimit,
      in: database
    )
    return Array(results.dropFirst(requestedOffset).prefix(requestedLimit))
  }
  var sql = """
    SELECT m.note_id, bm25(note_fts) AS rank
    FROM note_fts
    INNER JOIN note_fts_map m ON m.fts_rowid = note_fts.rowid
    INNER JOIN notes n ON n.note_id = m.note_id
    WHERE note_fts MATCH ?
    """
  var bindings: [SQLiteValue] = [.text(matchQuery)]
  if !tagFilter.isEmpty {
    sql += """

      AND EXISTS (
        SELECT 1
        FROM note_tags nt
        INNER JOIN tags t ON t.tag_id = nt.tag_id
        WHERE nt.note_id = n.note_id
          AND t.name IN (\(placeholders(count: tagFilter.count)))
      )
      """
    bindings.append(contentsOf: tagFilter.map(SQLiteValue.text))
  }
  if !classFilter.isEmpty {
    sql += """

      AND EXISTS (
        SELECT 1
        FROM note_tags nt
        INNER JOIN tags t ON t.tag_id = nt.tag_id
        WHERE nt.note_id = n.note_id
          AND t.class_id IN (\(placeholders(count: classFilter.count)))
      )
      """
    bindings.append(contentsOf: classFilter.map(SQLiteValue.text))
  }
  sql += " ORDER BY rank, n.created_at DESC LIMIT ?"
  bindings.append(.int(Int64(fetchLimit)))

  let rows = try database.query(sql, bindings: bindings)
  let notesById = try requireNotes(rows.compactMap { $0["note_id"] }, in: database)
  var results = try rows.map { row in
    guard let noteId = row["note_id"] else {
      throw NoteServiceError.invalidRow("search row is missing note_id")
    }
    guard let note = notesById[noteId] else {
      throw NoteServiceError.notFound("note not found: \(noteId)")
    }
    let rank = Double(row["rank"] ?? "") ?? 0
    return NoteSearchResult(
      note: note,
      snippet: snippet(from: note.bodyMarkdown, query: query),
      rank: rank,
      matchedTags: note.tags.map(\.tag)
    )
  }
  if shouldRunTextLikeFallback(query: query, ftsResultCount: results.count) {
    let fallback = try searchNotesByTextLike(
      query: query,
      tagFilter: tagFilter,
      classFilter: classFilter,
      excludedNoteIds: Set(results.map(\.note.noteId)),
      limit: fetchLimit - results.count,
      in: database
    )
    results.append(contentsOf: fallback)
  }
  return Array(results.dropFirst(requestedOffset).prefix(requestedLimit))
}

private func shouldRunTextLikeFallback(query: String, ftsResultCount: Int) -> Bool {
  ftsResultCount == 0 || queryHasSubtrigramTerm(query)
}

private func searchNotesByFilters(
  tagFilter: [String],
  classFilter: [String],
  limit: Int,
  in database: SQLiteDatabase
) throws -> [NoteSearchResult] {
  guard !tagFilter.isEmpty || !classFilter.isEmpty else {
    return []
  }
  var predicates: [String] = []
  var bindings: [SQLiteValue] = []
  if !tagFilter.isEmpty {
    predicates.append(
      """
      EXISTS (
        SELECT 1
        FROM note_tags nt
        INNER JOIN tags t ON t.tag_id = nt.tag_id
        WHERE nt.note_id = n.note_id
          AND t.name IN (\(placeholders(count: tagFilter.count)))
      )
      """
    )
    bindings.append(contentsOf: tagFilter.map(SQLiteValue.text))
  }
  if !classFilter.isEmpty {
    predicates.append(
      """
      EXISTS (
        SELECT 1
        FROM note_tags nt
        INNER JOIN tags t ON t.tag_id = nt.tag_id
        WHERE nt.note_id = n.note_id
          AND t.class_id IN (\(placeholders(count: classFilter.count)))
      )
      """
    )
    bindings.append(contentsOf: classFilter.map(SQLiteValue.text))
  }
  bindings.append(.int(Int64(limit)))
  let rows = try database.query(
    """
    SELECT n.note_id
    FROM notes n
    WHERE \(predicates.joined(separator: " AND "))
    ORDER BY n.created_at DESC, n.note_id
    LIMIT ?
    """,
    bindings: bindings
  )
  let notesById = try requireNotes(rows.compactMap { $0["note_id"] }, in: database)
  return try rows.map { row in
    guard let noteId = row["note_id"] else {
      throw NoteServiceError.invalidRow("filtered search row is missing note_id")
    }
    guard let note = notesById[noteId] else {
      throw NoteServiceError.notFound("note not found: \(noteId)")
    }
    return NoteSearchResult(
      note: note,
      snippet: snippet(from: note.bodyMarkdown, query: ""),
      rank: 0,
      matchedTags: note.tags.map(\.tag)
    )
  }
}

private func searchNotesByTextLike(
  query: String,
  tagFilter: [String],
  classFilter: [String],
  excludedNoteIds: Set<String>,
  limit: Int,
  in database: SQLiteDatabase
) throws -> [NoteSearchResult] {
  let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !normalizedQuery.isEmpty, limit > 0 else {
    return []
  }
  let likePattern = "%\(escapedLikePattern(normalizedQuery))%"
  var predicates = [
    """
    (
      n.title LIKE ? ESCAPE '\\'
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
  ]
  var bindings: [SQLiteValue] = [.text(likePattern), .text(likePattern), .text(likePattern)]
  if !excludedNoteIds.isEmpty {
    predicates.append("n.note_id NOT IN (\(placeholders(count: excludedNoteIds.count)))")
    bindings.append(contentsOf: excludedNoteIds.sorted().map(SQLiteValue.text))
  }
  if !tagFilter.isEmpty {
    predicates.append(
      """
      EXISTS (
        SELECT 1
        FROM note_tags nt
        INNER JOIN tags t ON t.tag_id = nt.tag_id
        WHERE nt.note_id = n.note_id
          AND t.name IN (\(placeholders(count: tagFilter.count)))
      )
      """
    )
    bindings.append(contentsOf: tagFilter.map(SQLiteValue.text))
  }
  if !classFilter.isEmpty {
    predicates.append(
      """
      EXISTS (
        SELECT 1
        FROM note_tags nt
        INNER JOIN tags t ON t.tag_id = nt.tag_id
        WHERE nt.note_id = n.note_id
          AND t.class_id IN (\(placeholders(count: classFilter.count)))
      )
      """
    )
    bindings.append(contentsOf: classFilter.map(SQLiteValue.text))
  }
  bindings.append(.int(Int64(limit)))
  let rows = try database.query(
    """
    SELECT n.note_id
    FROM notes n
    WHERE \(predicates.joined(separator: " AND "))
    ORDER BY n.created_at DESC, n.note_id
    LIMIT ?
    """,
    bindings: bindings
  )
  let notesById = try requireNotes(rows.compactMap { $0["note_id"] }, in: database)
  return try rows.map { row in
    guard let noteId = row["note_id"] else {
      throw NoteServiceError.invalidRow("fallback search row is missing note_id")
    }
    guard let note = notesById[noteId] else {
      throw NoteServiceError.notFound("note not found: \(noteId)")
    }
    return NoteSearchResult(
      note: note,
      snippet: snippet(from: note.bodyMarkdown, query: query),
      rank: 1,
      matchedTags: note.tags.map(\.tag)
    )
  }
}

func refreshFTS(noteId: String, previous: FTSPayload?, in database: SQLiteDatabase) throws {
  if let previous {
    try database.execute(
      """
      INSERT INTO note_fts(note_fts, rowid, title, body, tags)
      VALUES('delete', ?, ?, ?, ?)
      """,
      bindings: [
        .int(previous.rowId),
        .text(previous.title),
        .text(previous.body),
        .text(previous.tags)
      ]
    )
    try database.execute("DELETE FROM note_fts_map WHERE note_id = ?", bindings: [.text(noteId)])
  }

  let payload = try currentFTSPayload(noteId: noteId, rowId: previous?.rowId, in: database)
  try database.execute(
    "INSERT INTO note_fts(rowid, title, body, tags) VALUES (?, ?, ?, ?)",
    bindings: [
      .int(payload.rowId),
      .text(payload.title),
      .text(payload.body),
      .text(payload.tags)
    ]
  )
  try database.execute(
    """
    INSERT INTO note_fts_map (fts_rowid, note_id)
    VALUES (?, ?)
    ON CONFLICT(note_id) DO UPDATE SET fts_rowid = excluded.fts_rowid
    """,
    bindings: [.int(payload.rowId), .text(noteId)]
  )
}

func ftsPayload(noteId: String, in database: SQLiteDatabase) throws -> FTSPayload? {
  let rows = try database.query(
    """
    SELECT m.fts_rowid, n.title, n.body_markdown, ifnull((
        SELECT group_concat(ordered_tags.name, ' ')
        FROM (
          SELECT t.name
          FROM note_tags nt
          INNER JOIN tags t ON t.tag_id = nt.tag_id
          WHERE nt.note_id = n.note_id
          ORDER BY t.name
        ) ordered_tags
      ), '') AS tags
    FROM note_fts_map m
    INNER JOIN notes n ON n.note_id = m.note_id
    WHERE m.note_id = ?
    LIMIT 1
    """,
    bindings: [.text(noteId)]
  )
  guard let row = rows.first, let rowIdText = row["fts_rowid"], let rowId = Int64(rowIdText) else {
    return nil
  }
  return FTSPayload(
    rowId: rowId,
    title: row["title"] ?? "",
    body: row["body_markdown"] ?? "",
    tags: row["tags"] ?? ""
  )
}

private func currentFTSPayload(noteId: String, rowId: Int64?, in database: SQLiteDatabase) throws -> FTSPayload {
  let note = try requireNote(noteId, in: database)
  let ftsRowId: Int64
  if let rowId {
    ftsRowId = rowId
  } else {
    ftsRowId = try nextFTSRowId(in: database)
  }
  return FTSPayload(
    rowId: ftsRowId,
    title: note.title ?? "",
    body: note.bodyMarkdown,
    tags: note.tags.map(\.tag.name).joined(separator: " ")
  )
}

private func nextFTSRowId(in database: SQLiteDatabase) throws -> Int64 {
  let rows = try database.query("SELECT ifnull(max(fts_rowid), 0) + 1 AS next_rowid FROM note_fts_map")
  return Int64(rows.first?["next_rowid"] ?? "") ?? 1
}

private func snippet(from body: String, query: String) -> String {
  let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !normalizedQuery.isEmpty,
        let range = body.range(of: normalizedQuery, options: [.caseInsensitive, .diacriticInsensitive])
  else {
    return String(body.replacingOccurrences(of: "\n", with: " ").prefix(200))
  }
  let lower = body.index(range.lowerBound, offsetBy: -80, limitedBy: body.startIndex) ?? body.startIndex
  let upper = body.index(range.upperBound, offsetBy: 80, limitedBy: body.endIndex) ?? body.endIndex
  return String(body[lower..<upper].replacingOccurrences(of: "\n", with: " "))
}

func placeholders(count: Int) -> String {
  Array(repeating: "?", count: count).joined(separator: ",")
}

private func escapedLikePattern(_ value: String) -> String {
  value
    .replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "%", with: "\\%")
    .replacingOccurrences(of: "_", with: "\\_")
}

private func ftsMatchQuery(from query: String) -> String? {
  let terms = ftsTerms(from: query)
  guard !terms.isEmpty else {
    return nil
  }
  return terms.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
    .joined(separator: " ")
}

private func queryHasSubtrigramTerm(_ query: String) -> Bool {
  ftsTerms(from: query).contains { term in
    term.unicodeScalars.count < 3
  }
}

private func ftsTerms(from query: String) -> [String] {
  query.unicodeScalars.split { scalar in
    !CharacterSet.alphanumerics.contains(scalar)
  }.map(String.init).filter { !$0.isEmpty }
}
