import Foundation
import RielaCore
import RielaNote
import XCTest
@testable import RielaGraphQL

/// Verifies that on the authenticated HTTP note API the audit-attribution
/// identity is always the bearer-verified client and cannot be overridden by
/// request input, and that migration diagnostics are redacted (theme T2,
/// findings F21/F26).
final class NoteGraphQLVerifiedIdentityTests: XCTestCase {
  func testAuthenticatedApplyTagsRejectsExplicitAssignedBy() async throws {
    let service = try makeNoteGraphQLService()
    let executor = NoteGraphQLDocumentExecutor(service: service)
    let note = try service.service.createNote(bodyMarkdown: "# Identity\n\nBody")

    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation ApplyTags($input: ApplyNoteTagsInput!) {
        applyNoteTags(input: $input) { result { accepted } }
      }
      """,
      variables: [
        "input": .object([
          "noteId": .string(note.noteId),
          "tags": .array([.object(["name": .string("topic")])]),
          "assignedBy": .string("client:other")
        ])
      ],
      operationName: "ApplyTags",
      authenticatedClientId: "abc123"
    ))

    XCTAssertTrue(response.handled)
    let message = try errorMessage(response)
    XCTAssertTrue(message.contains("invalidVariable"), message)
    XCTAssertTrue(message.contains("assignedBy"), message)
  }

  func testAuthenticatedApplyTagsPersistsVerifiedIdentity() async throws {
    let service = try makeNoteGraphQLService()
    let executor = NoteGraphQLDocumentExecutor(service: service)
    let note = try service.service.createNote(bodyMarkdown: "# Identity\n\nBody")

    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation ApplyTags($input: ApplyNoteTagsInput!) {
        applyNoteTags(input: $input) { result { accepted } }
      }
      """,
      variables: [
        "input": .object([
          "noteId": .string(note.noteId),
          "tags": .array([.object(["name": .string("topic")])])
        ])
      ],
      operationName: "ApplyTags",
      authenticatedClientId: "abc123"
    ))

    XCTAssertTrue(response.handled)
    XCTAssertNil(response.body["errors"])

    let stored = try service.service.getNote(note.noteId)
    let assignedBy = stored.tags.first(where: { $0.tag.name == "topic" })?.assignedBy
    XCTAssertEqual(assignedBy, "client:abc123")
  }

  func testMigrateAllNoteFilesFailureDiagnosticsAreRedacted() async throws {
    let service = try makeNoteGraphQLService()
    // A configured profile whose uploads fail (500) makes every file migration
    // report a per-file failure; both the failures list and the control-plane
    // diagnostics must equal the fixed redacted constant, not raw error text.
    let profile = S3StorageProfile(
      name: "backup",
      endpoint: URL(string: "https://s3.example.test")!,
      region: "ap-northeast-1",
      bucket: "notes",
      accessKeyId: "access-key",
      secretAccessKey: "secret-key"
    )
    let executor = NoteGraphQLDocumentExecutor(
      service: service,
      s3HTTPClient: FailingS3HTTPClient(),
      s3Profiles: [profile]
    )
    let note = try service.service.createNote(bodyMarkdown: "# File\n\nBody")
    _ = try service.service.attachFile(
      noteId: note.noteId,
      data: Data("payload".utf8),
      mediaType: "text/plain",
      originalFilename: "note.txt"
    )

    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation MigrateAll($input: MigrateAllNoteFilesInput!) {
        migrateAllNoteFiles(input: $input) {
          result { accepted status diagnostics }
          failures { fileId message }
        }
      }
      """,
      variables: ["input": .object(["s3ProfileName": .string("backup")])],
      operationName: "MigrateAll"
    ))

    XCTAssertTrue(response.handled)
    XCTAssertNil(response.body["errors"])
    let failures = try XCTUnwrap(arrayIfPresent(response.body, "data", "migrateAllNoteFiles", "failures"))
    XCTAssertFalse(failures.isEmpty)
    for failure in failures {
      guard case let .object(object) = failure, case let .string(message)? = object["message"] else {
        return XCTFail("expected a failure with a string message")
      }
      XCTAssertEqual(message, "note file migration failed")
    }

    let text = responseText(response.body)
    for leak in ["SELECT", "INSERT", "sqlite", ".db", "/tmp", "no such", "s3.example.test", "secret-key"] {
      XCTAssertFalse(text.localizedCaseInsensitiveContains(leak), "leaked '\(leak)': \(text)")
    }
    // The control-plane diagnostics use the same redacted constant per file.
    XCTAssertTrue(text.contains("note file migration failed"), text)
  }

  // MARK: - helpers

  private func errorMessage(_ response: GraphQLDocumentExecutionResponse) throws -> String {
    guard case let .array(errors)? = response.body["errors"], let first = errors.first,
          case let .object(errorObject) = first, case let .string(message)? = errorObject["message"] else {
      XCTFail("expected an error message, got \(String(describing: response.body))")
      return ""
    }
    return message
  }

  private func responseText(_ body: JSONObject) -> String {
    guard let data = try? JSONEncoder().encode(JSONValue.object(body)),
          let text = String(data: data, encoding: .utf8) else {
      return ""
    }
    return text
  }

  private func arrayIfPresent(_ body: JSONObject, _ keys: String...) -> [JSONValue]? {
    var current: JSONValue = .object(body)
    for key in keys {
      guard case let .object(object) = current, let next = object[key] else {
        return nil
      }
      current = next
    }
    guard case let .array(values) = current else {
      return nil
    }
    return values
  }

  private func makeNoteGraphQLService(function: String = #function) throws -> GraphQLNoteGraphQLService {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp", isDirectory: true)
      .appendingPathComponent("note-graphql-identity-\(function)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    return GraphQLNoteGraphQLService(service: service)
  }
}

private struct FailingS3HTTPClient: S3HTTPClient {
  func send(_ request: S3HTTPRequest) throws -> S3HTTPResponse {
    S3HTTPResponse(statusCode: 500, body: Data("<Error>internal</Error>".utf8))
  }
}
