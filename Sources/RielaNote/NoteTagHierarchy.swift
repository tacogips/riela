import RielaSQLite

func expandedTagFilterNames(
  _ tagNames: [String],
  in database: SQLiteDatabase
) throws -> [String] {
  let roots = orderedUnique(tagNames)
  guard !roots.isEmpty else {
    return []
  }
  return try database.query(
    """
    WITH RECURSIVE descendant_tags(tag_id, name) AS (
      SELECT tag_id, name
      FROM tags
      WHERE name IN (\(placeholders(count: roots.count)))
      UNION
      SELECT child.tag_id, child.name
      FROM tags child
      INNER JOIN descendant_tags parent
        ON child.parent_tag_id = parent.tag_id
    )
    SELECT name
    FROM descendant_tags
    ORDER BY name
    """,
    bindings: roots.map(SQLiteValue.text)
  ).compactMap { $0["name"] }
}

func validateTagParent(
  childTagId: String,
  parentTagId: String,
  in database: SQLiteDatabase
) throws {
  guard childTagId != parentTagId else {
    throw NoteServiceError.invalidInput("a tag cannot be its own parent")
  }
  let parentRows = try database.query(
    "SELECT tag_id FROM tags WHERE tag_id = ? LIMIT 1",
    bindings: [.text(parentTagId)]
  )
  guard !parentRows.isEmpty else {
    throw NoteServiceError.notFound("parent tag not found: \(parentTagId)")
  }
  let cycleRows = try database.query(
    """
    WITH RECURSIVE ancestors(tag_id, parent_tag_id) AS (
      SELECT tag_id, parent_tag_id
      FROM tags
      WHERE tag_id = ?
      UNION
      SELECT parent.tag_id, parent.parent_tag_id
      FROM tags parent
      INNER JOIN ancestors child
        ON parent.tag_id = child.parent_tag_id
    )
    SELECT tag_id
    FROM ancestors
    WHERE tag_id = ?
    LIMIT 1
    """,
    bindings: [.text(parentTagId), .text(childTagId)]
  )
  guard cycleRows.isEmpty else {
    throw NoteServiceError.invalidInput("tag parent would create a cycle")
  }
}
