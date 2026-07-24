import Foundation
import RielaCore
import RielaNote
@testable import RielaGraphQL
import XCTest

final class NoteGraphQLHierarchyProgressTests: XCTestCase {
  func testGraphQLProjectsHierarchyProgressFolderAndExpandedNotebookFilters() async throws {
    let service = try makeHierarchyGraphQLService()
    let parentResult = await service.defineTag(
      GraphQLDefineNoteTagInput(name: "portfolio", classId: "topic")
    )
    let parentId = try XCTUnwrap(parentResult.tag?.tagId)
    let childResult = await service.defineTag(
      GraphQLDefineNoteTagInput(
        name: "project",
        classId: "topic",
        parentTagId: parentId
      )
    )
    XCTAssertEqual(childResult.tag?.parentTagId, parentId)

    let notebookResult = await service.createNotebook(
      GraphQLCreateNotebookInput(title: "Project Notebook")
    )
    let notebookId = try XCTUnwrap(notebookResult.notebook?.notebookId)
    let tagged = await service.applyNotebookTags(
      GraphQLApplyNotebookTagsInput(
        notebookId: notebookId,
        tags: ["project"],
        provenance: "human",
        assignedBy: "graphql-hierarchy-test"
      )
    )
    XCTAssertTrue(tagged.result.accepted)

    let progressed = await service.setNotebookProgress(
      notebookId: notebookId,
      progress: NotebookProgress.progress.rawValue
    )
    XCTAssertEqual(progressed.notebook?.progress, .progress)

    let parentFiltered = await service.notebooks(tagFilter: ["portfolio"])
    XCTAssertEqual(parentFiltered.value?.map(\.notebookId), [notebookId])
    XCTAssertEqual(parentFiltered.value?.first?.progress, .progress)

    let folderResult = await service.defineTag(
      GraphQLDefineNoteTagInput(name: "Work", classId: "folder")
    )
    XCTAssertEqual(folderResult.tag?.classId, "folder")
    let folderTagged = await service.applyNotebookTags(
      GraphQLApplyNotebookTagsInput(
        notebookId: notebookId,
        tags: ["Work"],
        provenance: "human",
        assignedBy: "graphql-hierarchy-test"
      )
    )
    XCTAssertTrue(
      folderTagged.notebook?.tags.contains {
        $0.tag.name == "Work" && $0.tag.classId == "folder"
      } == true
    )
  }

  func testDocumentExecutorRunsSetNotebookProgressAndProjectsNewFields() async throws {
    let service = try makeHierarchyGraphQLService()
    let parent = await service.defineTag(GraphQLDefineNoteTagInput(name: "root"))
    let parentId = try XCTUnwrap(parent.tag?.tagId)
    _ = await service.defineTag(
      GraphQLDefineNoteTagInput(name: "child", parentTagId: parentId)
    )
    let created = await service.createNotebook(GraphQLCreateNotebookInput(title: "Board Card"))
    let notebookId = try XCTUnwrap(created.notebook?.notebookId)
    _ = await service.applyNotebookTags(
      GraphQLApplyNotebookTagsInput(notebookId: notebookId, tags: ["child"])
    )
    let executor = NoteGraphQLDocumentExecutor(service: service)

    let mutation = await executor.execute(
      GraphQLDocumentRequest(
        query: """
        mutation SetProgress($notebookId: String!, $progress: NotebookProgress!) {
          setNotebookProgress(notebookId: $notebookId, progress: $progress) {
            result { accepted status }
            notebook { notebookId progress tags { tag { name parentTagId } } }
          }
        }
        """,
        variables: [
          "notebookId": .string(notebookId),
          "progress": .string("done")
        ],
        operationName: "SetProgress"
      )
    )

    XCTAssertTrue(mutation.handled)
    XCTAssertEqual(mutation.status, 200)
    let mutationPayload = try payloadObject(mutation.body, field: "setNotebookProgress")
    let notebook = try objectValue(mutationPayload["notebook"], field: "notebook")
    XCTAssertEqual(notebook["progress"], .string("done"))

    let invalidMutation = await executor.execute(
      GraphQLDocumentRequest(
        query: """
        mutation RejectInvalidProgress($notebookId: String!, $progress: NotebookProgress!) {
          setNotebookProgress(notebookId: $notebookId, progress: $progress) {
            result { accepted status }
            notebook { notebookId progress }
          }
        }
        """,
        variables: [
          "notebookId": .string(notebookId),
          "progress": .string("blocked")
        ],
        operationName: "RejectInvalidProgress"
      )
    )
    let invalidPayload = try payloadObject(
      invalidMutation.body,
      field: "setNotebookProgress"
    )
    let invalidResult = try objectValue(invalidPayload["result"], field: "result")
    XCTAssertEqual(invalidResult["accepted"], .bool(false))
    XCTAssertEqual(invalidResult["status"], .string("invalid_request"))
    let persistedAfterInvalid = await service.notebook(notebookId: notebookId)
    XCTAssertEqual(persistedAfterInvalid.value?.progress, .done)

    let query = await executor.execute(
      GraphQLDocumentRequest(
        query: """
        query ParentNotebooks($tagFilter: [String!]) {
          notebooks(tagFilter: $tagFilter) {
            result { accepted }
            value { notebookId progress tags { tag { name parentTagId } } }
          }
        }
        """,
        variables: ["tagFilter": .array([.string("root")])],
        operationName: "ParentNotebooks"
      )
    )
    XCTAssertEqual(query.status, 200)
    let queryPayload = try payloadObject(query.body, field: "notebooks")
    guard case let .array(values)? = queryPayload["value"],
          case let .object(projectedNotebook) = values.first else {
      return XCTFail("expected a projected notebook")
    }
    XCTAssertEqual(projectedNotebook["notebookId"], .string(notebookId))
    XCTAssertEqual(projectedNotebook["progress"], .string("done"))
  }

  private func makeHierarchyGraphQLService(
    function: String = #function
  ) throws -> GraphQLNoteGraphQLService {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/NoteGraphQLHierarchyProgressTests", isDirectory: true)
      .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let noteService = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    return GraphQLNoteGraphQLService(service: noteService)
  }

  private func payloadObject(
    _ body: JSONObject,
    field: String
  ) throws -> JSONObject {
    let data = try objectValue(body["data"], field: "data")
    return try objectValue(data[field], field: field)
  }

  private func objectValue(
    _ value: JSONValue?,
    field: String
  ) throws -> JSONObject {
    guard case let .object(object)? = value else {
      throw NSError(
        domain: "NoteGraphQLHierarchyProgressTests",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "expected object at \(field)"]
      )
    }
    return object
  }
}
