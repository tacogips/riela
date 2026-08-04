import Foundation
import RielaCore
import RielaNote
import XCTest
@testable import RielaCLI

extension NoteAddonTests {
  func testKanbanTaskCreateIsIdempotentAndShapesFanoutItems() async throws {
    let noteRoot = try makeNoteAddonRoot()
    defer {
      try? FileManager.default.removeItem(atPath: noteRoot)
    }
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": noteRoot])
    let config: JSONObject = [
      "folderTagName": .string("orchestrations/demo-run"),
      "runLabel": .string("demo"),
      "tasks": .array([
        .object([
          "taskKey": .string("first-card"),
          "title": .string("First card"),
          "briefMarkdown": .string("Do the first thing."),
          "acceptanceMarkdown": .string("- done well")
        ]),
        .object([
          "taskKey": .string("second-card"),
          "title": .string("Second card"),
          "briefMarkdown": .string("Do the second thing.")
        ])
      ])
    ]

    let first = try await resolver.execute(
      noteInput(name: "riela/note-kanban-task-create", config: config),
      context: AdapterExecutionContext()
    )
    XCTAssertEqual(first.payload["folderTagName"], .string("demo-run"))
    let firstFolderTagId = try stringValue(first.payload["folderTagId"], field: "folderTagId")
    let firstTasks = try arrayValue(first.payload["tasks"], field: "tasks").map(objectValue)
    XCTAssertEqual(firstTasks.count, 2)
    XCTAssertEqual(firstTasks.map { $0["taskKey"] }, [.string("first-card"), .string("second-card")])
    XCTAssertEqual(firstTasks.map { $0["progress"] }, [.string("pending"), .string("pending")])
    XCTAssertEqual(firstTasks.map { $0["reused"] }, [.bool(false), .bool(false)])
    let firstNotebookIds = try firstTasks.map { try stringValue($0["notebookId"], field: "notebookId") }

    var duplicateBranchConfig = config
    duplicateBranchConfig["folderTagName"] = .string("archive/demo-run")
    let duplicateBranch = try await resolver.execute(
      noteInput(name: "riela/note-kanban-task-create", config: duplicateBranchConfig),
      context: AdapterExecutionContext()
    )
    let duplicateFolderTagId = try stringValue(
      duplicateBranch.payload["folderTagId"],
      field: "duplicate folderTagId"
    )
    XCTAssertNotEqual(duplicateFolderTagId, firstFolderTagId)
    let duplicateTasks = try arrayValue(
      duplicateBranch.payload["tasks"],
      field: "duplicate tasks"
    ).map(objectValue)
    XCTAssertEqual(duplicateTasks.map { $0["reused"] }, [.bool(false), .bool(false)])
    let duplicateNotebookIds = try duplicateTasks.map {
      try stringValue($0["notebookId"], field: "duplicate notebookId")
    }
    XCTAssertTrue(Set(duplicateNotebookIds).isDisjoint(with: firstNotebookIds))

    let second = try await resolver.execute(
      noteInput(name: "riela/note-kanban-task-create", config: config),
      context: AdapterExecutionContext()
    )
    XCTAssertEqual(second.payload["folderTagId"], .string(firstFolderTagId))
    let secondTasks = try arrayValue(second.payload["tasks"], field: "tasks").map(objectValue)
    XCTAssertEqual(secondTasks.map { $0["reused"] }, [.bool(true), .bool(true)])
    XCTAssertEqual(
      try secondTasks.map { try stringValue($0["notebookId"], field: "notebookId") },
      firstNotebookIds
    )

    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot))
    let tags = try service.listTags()
    let parentTag = try XCTUnwrap(tags.first { $0.name == "orchestrations" })
    let folderTag = try XCTUnwrap(tags.first {
      $0.name == "demo-run" && $0.parentTagId == parentTag.tagId
    })
    XCTAssertEqual(folderTag.classId, "folder")
    XCTAssertEqual(folderTag.tagId, firstFolderTagId)
    XCTAssertEqual(try service.listNotebooks(tagFilterIdGroups: [[folderTag.tagId]]).count, 2)
    XCTAssertEqual(try service.listNotebooks(tagFilterIdGroups: [[duplicateFolderTagId]]).count, 2)

    let firstBoard = try await resolver.execute(
      noteInput(name: "riela/note-kanban-board", config: [
        "folderTagId": .string(firstFolderTagId)
      ]),
      context: AdapterExecutionContext()
    )
    let duplicateBoard = try await resolver.execute(
      noteInput(name: "riela/note-kanban-board", config: [
        "folderTagId": .string(duplicateFolderTagId)
      ]),
      context: AdapterExecutionContext()
    )
    XCTAssertEqual(firstBoard.payload["folderTagId"], .string(firstFolderTagId))
    XCTAssertEqual(duplicateBoard.payload["folderTagId"], .string(duplicateFolderTagId))
    XCTAssertEqual(try kanbanNotebookIds(from: firstBoard), Set(firstNotebookIds))
    XCTAssertEqual(try kanbanNotebookIds(from: duplicateBoard), Set(duplicateNotebookIds))

    do {
      _ = try await resolver.execute(
        noteInput(name: "riela/note-kanban-board", config: [
          "tagName": .string("demo-run")
        ]),
        context: AdapterExecutionContext()
      )
      XCTFail("expected the legacy duplicate folder name to be ambiguous")
    } catch {
      XCTAssertTrue(String(describing: error).contains("ambiguous"))
    }
  }
}
