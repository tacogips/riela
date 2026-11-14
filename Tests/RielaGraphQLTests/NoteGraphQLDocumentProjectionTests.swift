import Foundation
import RielaCore
import RielaNote
import XCTest
@testable import RielaGraphQL

final class NoteGraphQLDocumentProjectionTests: XCTestCase {
  func testDocumentExecutorProjectsSelectionsAndDoesNotTreatVariablesAsArguments() async throws {
    let service = try makeNoteGraphQLService()
    let executor = NoteGraphQLDocumentExecutor(service: service)
    let note = try service.service.createNote(bodyMarkdown: "# Projected\n\nHidden body")

    let projected = await executor.execute(GraphQLDocumentRequest(
      query: """
      query Projected($noteId: String!) {
        note(noteId: $noteId) {
          result { accepted }
          value { __typename noteId title }
        }
      }
      """,
      variables: ["noteId": .string(note.noteId)],
      operationName: "Projected"
    ))

    XCTAssertTrue(projected.handled)
    let payload = try graphQLPayload(projected.body, field: "note")
    let result = try objectValue(payload["result"], field: "note.result")
    XCTAssertEqual(result["accepted"], .bool(true))
    XCTAssertNil(result["status"])
    let value = try objectValue(payload["value"], field: "note.value")
    XCTAssertEqual(value["__typename"], .string("Note"))
    XCTAssertEqual(value["noteId"], .string(note.noteId))
    XCTAssertEqual(value["title"], .string("Projected"))
    XCTAssertNil(value["bodyMarkdown"])

    let missingArgument = await executor.execute(GraphQLDocumentRequest(
      query: "mutation DeleteWithoutArgument { deleteNote { accepted status diagnostics } }",
      variables: ["noteId": .string(note.noteId)],
      operationName: "DeleteWithoutArgument"
    ))

    XCTAssertTrue(missingArgument.handled)
    let errors = try arrayValue(missingArgument.body["errors"], field: "delete errors")
    let error = try objectValue(errors.first, field: "delete errors[0]")
    XCTAssertTrue(
      try stringValue(error["message"], field: "delete errors[0].message")
        .contains("missingVariable: noteId")
    )
    XCTAssertEqual(try service.service.getNote(note.noteId).noteId, note.noteId)
  }

  func testDocumentExecutorRejectsObjectFieldsWithoutSelections() async throws {
    let service = try makeNoteGraphQLService()
    let executor = NoteGraphQLDocumentExecutor(service: service)

    let response = await executor.execute(GraphQLDocumentRequest(
      query: "query { notes { result { accepted } value } }"
    ))

    XCTAssertTrue(response.handled)
    let errors = try arrayValue(response.body["errors"], field: "empty object selection errors")
    let error = try objectValue(errors.first, field: "empty object selection errors[0]")
    XCTAssertTrue(
      try stringValue(error["message"], field: "empty object selection errors[0].message")
        .contains("notes.value requires nested selections")
    )
  }

  private func makeNoteGraphQLService(function: String = #function) throws -> GraphQLNoteGraphQLService {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp", isDirectory: true)
      .appendingPathComponent("note-graphql-projection-\(function)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    return GraphQLNoteGraphQLService(service: service)
  }

  private func graphQLPayload(_ body: JSONObject, field: String) throws -> JSONObject {
    let data = try objectValue(body["data"], field: "data")
    return try objectValue(data[field], field: field)
  }

  private func objectValue(_ value: JSONValue?, field: String) throws -> JSONObject {
    guard case let .object(object)? = value else {
      XCTFail("expected \(field) object")
      return [:]
    }
    return object
  }

  private func arrayValue(_ value: JSONValue?, field: String) throws -> [JSONValue] {
    guard case let .array(array)? = value else {
      XCTFail("expected \(field) array")
      return []
    }
    return array
  }

  private func stringValue(_ value: JSONValue?, field: String) throws -> String {
    guard case let .string(string)? = value else {
      XCTFail("expected \(field) string")
      return ""
    }
    return string
  }
}
