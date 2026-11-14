import Foundation
@testable import RielaNote
import RielaSQLite
import XCTest

final class NoteHierarchyProgressTests: NoteTestCase {
  func testV3MigrationPreservesRowsAndAddsHierarchyAndProgressConstraints() throws {
    let driver = try makeNoteDriver()
    try driver.withDatabase { database in
      try database.execute(
        """
        CREATE TABLE note_schema_version (
          version INTEGER PRIMARY KEY,
          applied_at TEXT NOT NULL
        )
        """
      )
      for version in 1...3 {
        try database.execute(
          "INSERT INTO note_schema_version (version, applied_at) VALUES (?, '2026-07-24T00:00:00Z')",
          bindings: [.int(Int64(version))]
        )
      }
      try database.execute(
        """
        CREATE TABLE notebooks (
          notebook_id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          meta_json BLOB CHECK (meta_json IS NULL OR json_valid(meta_json, 8))
        )
        """
      )
      try database.execute(
        """
        INSERT INTO notebooks (notebook_id, title, created_at, updated_at)
        VALUES ('existing-notebook', 'Existing', '2026-07-24T00:00:00Z', '2026-07-24T00:00:00Z')
        """
      )
      try database.execute(
        """
        CREATE TABLE tags (
          tag_id TEXT PRIMARY KEY,
          name TEXT NOT NULL UNIQUE,
          class_id TEXT,
          is_system INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL
        )
        """
      )
      try database.execute(
        """
        INSERT INTO tags (tag_id, name, is_system, created_at)
        VALUES ('existing-tag', 'existing', 0, '2026-07-24T00:00:00Z')
        """
      )
    }

    try NoteStoreSchema.prepare(on: driver)

    try driver.withDatabase { database in
      let notebookColumns = try database.query("PRAGMA table_info(notebooks)")
        .compactMap { $0["name"] }
      let tagColumns = try database.query("PRAGMA table_info(tags)")
        .compactMap { $0["name"] }
      XCTAssertTrue(notebookColumns.contains("progress"))
      XCTAssertTrue(tagColumns.contains("parent_tag_id"))
      XCTAssertEqual(
        try database.query(
          "SELECT title, progress FROM notebooks WHERE notebook_id = 'existing-notebook'"
        ).first?["progress"],
        "none"
      )
      XCTAssertNil(
        try database.query(
          "SELECT parent_tag_id FROM tags WHERE tag_id = 'existing-tag'"
        ).first?["parent_tag_id"] ?? nil
      )
      XCTAssertThrowsError(
        try database.execute(
          "UPDATE notebooks SET progress = 'invalid' WHERE notebook_id = 'existing-notebook'"
        )
      )
    }
  }

  func testHierarchyFiltersNotesAndNotebooksTransitively() throws {
    let service = try NoteService(driver: makeNoteDriver())
    let parent = try service.defineTag(name: "portfolio", classId: "topic")
    let child = try service.defineTag(
      name: "project",
      classId: "topic",
      parentTagId: parent.tagId
    )
    let grandchild = try service.defineTag(
      name: "launch",
      classId: "topic",
      parentTagId: child.tagId
    )
    let leaf = try service.defineTag(name: "standalone", classId: "topic")

    let parentNote = try service.createNote(
      bodyMarkdown: "# Parent\nAlpha parent",
      tags: [NoteTagInput(name: parent.name)]
    )
    let childNote = try service.createNote(
      bodyMarkdown: "# Child\nAlpha child",
      tags: [NoteTagInput(name: child.name)]
    )
    let grandchildNote = try service.createNote(
      bodyMarkdown: "# Grandchild\nAlpha grandchild",
      tags: [NoteTagInput(name: grandchild.name)]
    )
    let leafNote = try service.createNote(
      bodyMarkdown: "# Leaf\nAlpha leaf",
      tags: [NoteTagInput(name: leaf.name)]
    )
    let linkedGrandchildNote = try service.createNote(
      bodyMarkdown: "# Linked Grandchild\nNeighbor only",
      tags: [NoteTagInput(name: grandchild.name)]
    )
    _ = try service.linkNotes(
      from: parentNote.noteId,
      to: linkedGrandchildNote.noteId
    )

    try service.applyNotebookTags(
      notebookId: parentNote.notebookId,
      tags: [parent.name],
      provenance: .human
    )
    try service.applyNotebookTags(
      notebookId: childNote.notebookId,
      tags: [child.name],
      provenance: .human
    )
    try service.applyNotebookTags(
      notebookId: grandchildNote.notebookId,
      tags: [grandchild.name],
      provenance: .human
    )
    try service.applyNotebookTags(
      notebookId: leafNote.notebookId,
      tags: [leaf.name],
      provenance: .human
    )

    XCTAssertEqual(
      Set(try service.listNotes(tagFilter: [parent.name]).map(\.noteId)),
      Set([
        parentNote.noteId,
        childNote.noteId,
        grandchildNote.noteId,
        linkedGrandchildNote.noteId
      ])
    )
    XCTAssertEqual(
      Set(try service.listNotebooks(tagFilter: [parent.name]).map(\.notebookId)),
      Set([parentNote.notebookId, childNote.notebookId, grandchildNote.notebookId])
    )
    XCTAssertEqual(
      Set(try service.searchNotes(query: "Alpha", tagFilter: [parent.name]).map(\.note.noteId)),
      Set([parentNote.noteId, childNote.noteId, grandchildNote.noteId])
    )
    XCTAssertEqual(
      Set(try service.searchNotes(query: "", tagFilter: [parent.name]).map(\.note.noteId)),
      Set([
        parentNote.noteId,
        childNote.noteId,
        grandchildNote.noteId,
        linkedGrandchildNote.noteId
      ])
    )
    XCTAssertEqual(
      Set(try service.searchNotes(query: "Al", tagFilter: [parent.name]).map(\.note.noteId)),
      Set([parentNote.noteId, childNote.noteId, grandchildNote.noteId])
    )
    let linkedResults = try service.searchNotes(
      query: "Alpha",
      tagFilter: [parent.name],
      includeLinked: true
    )
    XCTAssertEqual(
      Set(linkedResults.map(\.note.noteId)),
      Set([
        parentNote.noteId,
        childNote.noteId,
        grandchildNote.noteId,
        linkedGrandchildNote.noteId
      ])
    )
    XCTAssertEqual(
      linkedResults.first { $0.note.noteId == linkedGrandchildNote.noteId }?.isLinkedNeighbor,
      true
    )
    XCTAssertEqual(
      try service.listNotes(tagFilter: [child.name]).map(\.noteId).sorted(),
      [childNote.noteId, grandchildNote.noteId, linkedGrandchildNote.noteId].sorted()
    )
    XCTAssertEqual(try service.listNotes(tagFilter: [leaf.name]).map(\.noteId), [leafNote.noteId])
    XCTAssertTrue(try service.listNotes(tagFilter: ["unknown-tag"]).isEmpty)
    XCTAssertTrue(try service.listNotebooks(tagFilter: ["unknown-tag"]).isEmpty)
  }

  func testCycleRejectionIsAtomicAndDefensiveExpansionTerminates() throws {
    let driver = try makeNoteDriver()
    let service = try NoteService(driver: driver)
    let parent = try service.defineTag(name: "parent")
    let child = try service.defineTag(name: "child", parentTagId: parent.tagId)

    XCTAssertThrowsError(
      try service.defineTag(name: "parent", parentTagId: child.tagId)
    )
    XCTAssertNil(try service.listTags().first { $0.tagId == parent.tagId }?.parentTagId)

    try driver.withDatabase { database in
      try database.execute(
        "UPDATE tags SET parent_tag_id = ? WHERE tag_id = ?",
        bindings: [.text(child.tagId), .text(parent.tagId)]
      )
    }
    let expanded = try driver.withDatabase { database in
      try expandedTagFilterNames([parent.name], in: database)
    }
    XCTAssertEqual(Set(expanded), Set([parent.name, child.name]))
  }

  func testFolderTagsAndTypedProgressRoundTrip() throws {
    let service = try NoteService(driver: makeNoteDriver())
    let folder = try service.defineTag(name: "Work", classId: "folder")
    let notebook = try service.createNotebook(title: "Quarterly Plan")
    let tagged = try service.applyNotebookTags(
      notebookId: notebook.notebookId,
      tags: [folder.name],
      provenance: .human
    )
    XCTAssertEqual(tagged.tags.first?.tag.classId, "folder")
    XCTAssertEqual(tagged.progress, .none)

    for progress in NotebookProgress.allCases {
      let updated = try service.setNotebookProgress(
        notebookId: notebook.notebookId,
        progress: progress
      )
      XCTAssertEqual(updated.progress, progress)
      XCTAssertEqual(try service.getNotebook(notebook.notebookId).progress, progress)
    }
  }
}
