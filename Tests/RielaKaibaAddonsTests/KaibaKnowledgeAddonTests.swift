import Foundation
import KaibaClient
import RielaAddonSupport
import RielaCore
import XCTest
@testable import RielaKaibaAddons

final class KaibaKnowledgeAddonTests: XCTestCase {
  func testEveryRegisteredNoteAddonUsesOnlyTheInjectedHTTPClientAndExactCompatibilityPayload() async throws {
    let transport = KaibaHTTPFixture()
    let client = try fixtureKaibaClient(transport)
    let source = try temporaryTextFile()
    defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
    let inputs = noteInputs(documentPath: source.path)
    for addon in inputs {
      let output = try await KaibaAddonCatalog.executeForTesting(addon, client: client, environment: [:])
      XCTAssertEqual(output.payload["status"], .string("ok"), addon.addon.name)
      XCTAssertEqual(
        Set(output.payload.keys),
        expectedPayloadKeys(for: addon.addon.name),
        addon.addon.name
      )
      assertExactCompatibilityValueShape(output.payload, addonName: addon.addon.name)
    }
    XCTAssertGreaterThanOrEqual(transport.requests.count, inputs.count)
  }

  func testDocumentImportRejectsAPathOutsideConfiguredRoot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let allowed = root.appendingPathComponent("allowed")
    let outside = root.appendingPathComponent("outside.txt")
    try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
    try Data("fixture".utf8).write(to: outside)
    defer { try? FileManager.default.removeItem(at: root) }
    do {
      _ = try await execute("kaiba/document-import", client: fixtureKaibaClient(), config: [
        "localFileRoot": .string(allowed.path), "path": .string(outside.path)
      ])
      XCTFail("expected an out-of-root rejection")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .invalidInput)
      XCTAssertTrue(error.message.contains("outside allowed root"))
    }
  }

  func testDocumentImportRejectsSymlinkEscapesAndOversizedFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let allowed = root.appendingPathComponent("allowed")
    let outside = root.appendingPathComponent("outside.txt")
    let link = allowed.appendingPathComponent("escape.txt")
    try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
    try Data("outside".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    defer { try? FileManager.default.removeItem(at: root) }
    await assertInvalidDocument(config: ["localFileRoot": .string(allowed.path), "path": .string(link.path)])

    let oversized = allowed.appendingPathComponent("large.txt")
    try Data(repeating: 0, count: 8 * 1024 * 1024 + 1).write(to: oversized)
    await assertInvalidDocument(config: ["localFileRoot": .string(allowed.path), "path": .string(oversized.path)])
  }

  func testProjectionExcludesProviderDiagnosticsAndLocalPaths() async throws {
    let output = try await execute("kaiba/note-attachments", client: fixtureKaibaClient(), config: ["noteId": .string("note-1")])
    XCTAssertNil(output.payload["diagnostics"])
    guard case let .array(files)? = output.payload["files"], case let .object(file)? = files.first else {
      return XCTFail("expected projected file")
    }
    XCTAssertNil(file["localPath"])
  }

  func testHTTPProjectionsPreserveEstablishedTopLevelIdentifiers() async throws {
    let client = try fixtureKaibaClient()
    let create = try await execute("kaiba/note-create", client: client, config: ["bodyMarkdown": .string("body")])
    XCTAssertEqual(create.payload["noteId"], .string("note-1"))
    XCTAssertEqual(create.payload["notebookId"], .string("notebook-1"))

    let get = try await execute("kaiba/note-get", client: client, config: ["noteId": .string("note-1")])
    XCTAssertNotNil(get.payload["comments"])
    XCTAssertNotNil(get.payload["links"])
    XCTAssertNotNil(get.payload["files"])

    let attachment = try await execute("kaiba/note-attach-file", client: client, config: [
      "noteId": .string("note-1"), "contentText": .string("file")
    ])
    XCTAssertEqual(attachment.payload["noteId"], .string("note-1"))
    XCTAssertEqual(attachment.payload["fileId"], .string("file-1"))

    let comment = try await execute("kaiba/note-comment-add", client: client, config: [
      "noteId": .string("note-1"), "bodyMarkdown": .string("comment")
    ])
    XCTAssertEqual(comment.payload["commentId"], .string("comment-1"))

    let tags = try await execute("kaiba/note-tag-apply", client: client, config: [
      "noteId": .string("note-1"), "tags": .array([.string("fixture")])
    ])
    XCTAssertNotNil(tags.payload["tags"])

    let notebookFiles = try await execute("kaiba/note-attachments", client: client, config: [
      "notebookId": .string("notebook-1")
    ])
    XCTAssertEqual(notebookFiles.payload["notebookId"], .string("notebook-1"))
  }

  func testNotebookAndDocumentIngestReplayAfterLostResponses() async throws {
    let transport = KaibaHTTPFixture(lostResponseOperations: ["KaibaIngestNotebookPages"])
    let client = try fixtureKaibaClient(transport)
    let source = try temporaryTextFile()
    defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

    let notebook = ingestInput(
      name: "kaiba/notebook-ingest-pages",
      config: ["pages": .array([.object(["bodyMarkdown": .string("notebook")])])],
      operation: "notebook"
    )
    try await assertLostResponse(for: notebook, client: client)
    try await assertSuccess(for: notebook, client: client)
    try await assertSuccess(for: notebook, client: client)

    let document = ingestInput(
      name: "kaiba/document-import",
      config: [
        "path": .string(source.path),
        "translate": .bool(true),
        "translatedPages": .array([.object(["bodyMarkdown": .string("translated")])])
      ],
      operation: "document"
    )
    try await assertLostResponse(for: document, client: client)
    try await assertLostResponse(for: document, client: client)
    try await assertSuccess(for: document, client: client)
    try await assertSuccess(for: document, client: client)

    let requests = ingestRequests(from: transport)
    XCTAssertEqual(requests.count, 10)
    let groups = Dictionary(grouping: requests, by: \.idempotencyKey)
    XCTAssertEqual(groups.count, 3)
    XCTAssertNotEqual(groups.keys.first, groups.keys.dropFirst().first)
    for requests in groups.values {
      XCTAssertGreaterThanOrEqual(requests.count, 3)
      XCTAssertEqual(Set(requests.map(\.body)).count, 1)
    }
    XCTAssertTrue(requests.contains { $0.body.contains("sourceDocument") })

    let conflicting = ingestInput(
      name: "kaiba/notebook-ingest-pages",
      config: [
        "idempotencyKey": .string("cross-run-key"),
        "pages": .array([.object(["bodyMarkdown": .string("first")])])
      ],
      operation: "cross-run"
    )
    try await assertLostResponse(for: conflicting, client: client)
    try await assertSuccess(for: conflicting, client: client)
    let changed = ingestInput(
      name: "kaiba/notebook-ingest-pages",
      config: [
        "idempotencyKey": .string("cross-run-key"),
        "pages": .array([.object(["bodyMarkdown": .string("changed")])])
      ],
      operation: "new-run"
    )
    try await assertProviderFailure(for: changed, client: client)
  }

  private func assertLostResponse(
    for input: WorkflowAddonExecutionInput,
    client: KaibaClient
  ) async throws {
    do {
      _ = try await KaibaAddonCatalog.executeForTesting(input, client: client, environment: [:])
      XCTFail("expected a lost response")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .providerError)
    }
  }

  private func assertSuccess(
    for input: WorkflowAddonExecutionInput,
    client: KaibaClient
  ) async throws {
    let output = try await KaibaAddonCatalog.executeForTesting(input, client: client, environment: [:])
    XCTAssertEqual(output.payload["status"], .string("ok"))
  }

  private func assertProviderFailure(
    for input: WorkflowAddonExecutionInput,
    client: KaibaClient
  ) async throws {
    do {
      _ = try await KaibaAddonCatalog.executeForTesting(input, client: client, environment: [:])
      XCTFail("expected an idempotency conflict")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .providerError)
    }
  }

  private func ingestRequests(from transport: KaibaHTTPFixture) -> [(idempotencyKey: String, body: String)] {
    transport.requests.compactMap { request in
      let body = String(bytes: request.body, encoding: .utf8) ?? ""
      guard body.contains("KaibaIngestNotebookPages"),
            let data = body.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let variables = root["variables"] as? [String: Any],
            let input = variables["input"] as? [String: Any],
            let key = input["idempotencyKey"] as? String else {
        return nil
      }
      return (key, body)
    }
  }

  private func ingestInput(
    name: String,
    config: JSONObject,
    operation: String
  ) -> WorkflowAddonExecutionInput {
    .init(
      workflowId: "kaiba-knowledge-test",
      stepId: operation,
      nodeId: operation,
      addon: .init(name: name, version: "1", config: config),
      executionIdentity: .init(
        workflowExecutionId: "knowledge-replay",
        stepExecutionId: operation,
        operationExecutionId: operation,
        attempt: 1
      )
    )
  }

  private func execute(_ name: String, client: KaibaClient, config: JSONObject) async throws -> AdapterExecutionOutput {
    try await KaibaAddonCatalog.executeForTesting(
      .init(workflowId: "kaiba-knowledge-test", stepId: "knowledge", nodeId: "knowledge", addon: .init(name: name, version: "1", config: config)),
      client: client,
      environment: [:]
    )
  }

  private func assertInvalidDocument(config: JSONObject) async {
    do {
      _ = try await execute("kaiba/document-import", client: try fixtureKaibaClient(), config: config)
      XCTFail("expected document validation failure")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .invalidInput)
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  private func noteInputs(documentPath: String) -> [WorkflowAddonExecutionInput] {
    let transcript: JSONValue = .array([.object(["userMarkdown": .string("question"), "assistantMarkdown": .string("answer")])])
    let pages: JSONValue = .array([.object(["bodyMarkdown": .string("page")])])
    let base: [(String, JSONObject)] = [
      ("kaiba/note-create", ["bodyMarkdown": .string("body")]),
      ("kaiba/note-update", ["noteId": .string("note-1"), "bodyMarkdown": .string("body")]),
      ("kaiba/note-get", ["noteId": .string("note-1")]),
      ("kaiba/note-search", ["query": .string("fixture")]),
      ("kaiba/note-tag-search", ["tags": .array([.string("fixture")])]),
      ("kaiba/note-graph-neighbors", ["noteId": .string("note-1")]),
      ("kaiba/note-chain", ["noteId": .string("note-1")]),
      ("kaiba/note-tag-apply", ["noteId": .string("note-1"), "tags": .array([.string("fixture")])]),
      ("kaiba/note-attach-file", ["noteId": .string("note-1"), "contentText": .string("file")]),
      ("kaiba/note-attachments", ["noteId": .string("note-1")]),
      ("kaiba/note-memos", ["noteId": .string("note-1")]),
      ("kaiba/note-graphql-document", ["query": .string("query Fixture { fixture }")]),
      ("kaiba/note-graphql-remote", ["query": .string("query Fixture { fixture }")]),
      ("kaiba/note-comment-add", ["noteId": .string("note-1"), "bodyMarkdown": .string("comment")]),
      ("kaiba/notebook-ingest-pages", ["pages": pages]),
      ("kaiba/document-import", ["path": .string(documentPath)]),
      ("kaiba/note-conversation-save", ["title": .string("Conversation"), "transcript": transcript])
    ]
    return base.map { name, config in
      .init(
        workflowId: "kaiba-knowledge-test", stepId: name, nodeId: name,
        addon: .init(name: name, version: "1", config: config),
        executionIdentity: .init(
          workflowExecutionId: "knowledge-run", stepExecutionId: name,
          operationExecutionId: name, attempt: 1
        )
      )
    }
  }

  private func expectedPayloadKeys(for addonName: String) -> Set<String> {
    let envelope: Set<String> = ["status", "addon", "operation", "stepId"]
    let note = envelope.union(["noteId", "notebookId", "note"])
    let notebook = envelope.union(["notebookId", "notebook", "notes", "noteIds"])
    switch addonName {
    case "kaiba/note-create", "kaiba/note-update":
      return note
    case "kaiba/note-tag-apply":
      return note.union(["tags"])
    case "kaiba/note-attach-file":
      return envelope.union(["noteId", "fileId", "file"])
    case "kaiba/note-comment-add":
      return envelope.union(["noteId", "commentId", "comment"])
    case "kaiba/note-conversation-save":
      return notebook
    case "kaiba/note-get":
      return envelope.union(["noteId", "notebookId", "note", "comments", "links", "files"])
    case "kaiba/note-search":
      return envelope.union(["results", "noteIds", "resultCount"])
    case "kaiba/note-tag-search":
      return envelope.union(["notes", "noteIds", "resultCount", "tagFilter"])
    case "kaiba/note-graph-neighbors":
      return envelope.union(["results", "noteIds", "resultCount", "seedNoteIds", "retrievalNoteIds"])
    case "kaiba/note-chain":
      return envelope.union(["results", "resultCount", "seedNoteIds", "chains"])
    case "kaiba/note-attachments":
      return envelope.union(["noteId", "attachments", "files", "fileCount"])
    case "kaiba/note-memos":
      return envelope.union(["noteId", "memos", "memoCount", "agentMemos", "agentMemoCount"])
    case "kaiba/note-graphql-document", "kaiba/note-graphql-remote":
      return envelope.union([
        "handled", "statusCode", "body", "fieldName", "fieldPayload", "result", "note",
        "notebook", "notes", "file", "noteFiles", "notebookFiles", "comment"
      ])
    case "kaiba/notebook-ingest-pages":
      return notebook.union(["pageCount", "sourceDocument", "pageImages"])
    case "kaiba/document-import":
      return notebook.union(["noteCount", "sourceFile", "ocrRequested", "translationRequested"])
    default:
      XCTFail("missing compatibility contract for \(addonName)")
      return []
    }
  }

  private func assertExactCompatibilityValueShape(_ payload: JSONObject, addonName: String) {
    XCTAssertEqual(payload["status"], .string("ok"), addonName)
    XCTAssertEqual(payload["addon"], .string(addonName), addonName)
    XCTAssertNil(payload["diagnostics"], addonName)
    XCTAssertNil(payload["noteRoot"], addonName)
    XCTAssertNil(payload["databasePath"], addonName)

    switch addonName {
    case "kaiba/note-create", "kaiba/note-update", "kaiba/note-tag-apply":
      assertFixtureNote(payload["note"], addonName: addonName)
      XCTAssertEqual(payload["noteId"], .string("note-1"), addonName)
      XCTAssertEqual(payload["notebookId"], .string("notebook-1"), addonName)
      if addonName == "kaiba/note-tag-apply" {
        XCTAssertEqual(payload["tags"], .array([]), addonName)
      }
    case "kaiba/note-get":
      assertFixtureNote(payload["note"], addonName: addonName)
      assertExactArray(payload["comments"], count: 1, addonName: addonName) { value in
        self.assertFixtureComment(value, addonName: addonName)
      }
      XCTAssertEqual(payload["links"], .array([]), addonName)
      assertExactArray(payload["files"], count: 1, addonName: addonName) { value in
        self.assertFixtureAttachment(value, noteID: "note-1", notebookID: "notebook-1", role: "related", includePosition: true, addonName: addonName)
      }
    case "kaiba/note-search":
      assertFixtureSearchResult(payload["results"], addonName: addonName)
      XCTAssertEqual(payload["noteIds"], .array([.string("note-1")]), addonName)
      XCTAssertEqual(payload["resultCount"], .number(1), addonName)
    case "kaiba/note-graph-neighbors":
      assertFixtureNeighbor(payload["results"], addonName: addonName)
      XCTAssertEqual(payload["noteIds"], .array([.string("note-1")]), addonName)
      XCTAssertEqual(payload["seedNoteIds"], .array([.string("note-1")]), addonName)
      XCTAssertEqual(payload["retrievalNoteIds"], .array([.string("note-1")]), addonName)
      XCTAssertEqual(payload["resultCount"], .number(1), addonName)
    case "kaiba/note-chain":
      assertFixtureNeighbor(payload["results"], addonName: addonName)
      assertFixtureNeighbor(payload["chains"], addonName: addonName)
      XCTAssertEqual(payload["seedNoteIds"], .array([.string("note-1")]), addonName)
      XCTAssertEqual(payload["resultCount"], .number(1), addonName)
    case "kaiba/note-tag-search":
      assertExactArray(payload["notes"], count: 1, addonName: addonName) { value in
        self.assertFixtureNote(value, addonName: addonName)
      }
      XCTAssertEqual(payload["noteIds"], .array([.string("note-1")]), addonName)
      XCTAssertEqual(payload["tagFilter"], .array([.string("fixture")]), addonName)
      XCTAssertEqual(payload["resultCount"], .number(1), addonName)
    case "kaiba/note-attach-file":
      XCTAssertEqual(payload["noteId"], .string("note-1"), addonName)
      XCTAssertEqual(payload["fileId"], .string("file-1"), addonName)
      assertFixtureAttachment(payload["file"], noteID: "note-1", role: "related", includePosition: true, addonName: addonName)
    case "kaiba/note-attachments":
      XCTAssertEqual(payload["noteId"], .string("note-1"), addonName)
      assertExactArray(payload["attachments"], count: 1, addonName: addonName) { value in
        self.assertFixtureAttachment(value, noteID: "note-1", notebookID: "notebook-1", role: "related", includePosition: true, addonName: addonName)
      }
      assertExactArray(payload["files"], count: 1, addonName: addonName) { value in
        self.assertFixtureFile(value, addonName: addonName)
      }
      XCTAssertEqual(payload["fileCount"], .number(1), addonName)
    case "kaiba/note-memos":
      XCTAssertEqual(payload["noteId"], .string("note-1"), addonName)
      assertExactArray(payload["memos"], count: 1, addonName: addonName) { value in
        self.assertFixtureComment(value, addonName: addonName)
      }
      assertExactArray(payload["agentMemos"], count: 1, addonName: addonName) { value in
        self.assertFixtureComment(value, addonName: addonName)
      }
      XCTAssertEqual(payload["memoCount"], .number(1), addonName)
      XCTAssertEqual(payload["agentMemoCount"], .number(1), addonName)
    case "kaiba/note-graphql-document", "kaiba/note-graphql-remote":
      XCTAssertEqual(payload["handled"], .bool(true), addonName)
      XCTAssertEqual(payload["statusCode"], .number(200), addonName)
      XCTAssertEqual(payload["fieldName"], .string("root"), addonName)
      assertGraphQLPayload(payload, addonName: addonName)
    case "kaiba/note-comment-add":
      XCTAssertEqual(payload["noteId"], .string("note-1"), addonName)
      XCTAssertEqual(payload["commentId"], .string("comment-1"), addonName)
      assertFixtureComment(payload["comment"], addonName: addonName)
    case "kaiba/notebook-ingest-pages", "kaiba/document-import", "kaiba/note-conversation-save":
      XCTAssertEqual(payload["notebookId"], .string("notebook-1"), addonName)
      assertFixtureNotebook(payload["notebook"], addonName: addonName)
      assertExactArray(payload["notes"], count: 1, addonName: addonName) { value in
        self.assertFixtureNote(value, addonName: addonName)
      }
      XCTAssertEqual(payload["noteIds"], .array([.string("note-1")]), addonName)
      if addonName == "kaiba/notebook-ingest-pages" {
        XCTAssertEqual(payload["pageCount"], .number(1), addonName)
        assertFixtureAttachment(payload["sourceDocument"], notebookID: "notebook-1", role: "source-document", includePosition: false, addonName: addonName)
        XCTAssertEqual(payload["pageImages"], .array([]), addonName)
      }
      if addonName == "kaiba/document-import" {
        XCTAssertEqual(payload["noteCount"], .number(1), addonName)
        assertFixtureFile(payload["sourceFile"], addonName: addonName)
        XCTAssertEqual(payload["ocrRequested"], .bool(false), addonName)
        XCTAssertEqual(payload["translationRequested"], .bool(false), addonName)
      }
    default:
      XCTFail("missing value contract for \(addonName)")
    }
  }

  private func assertFixtureNote(_ value: JSONValue?, addonName: String) {
    let object = assertObject(value, keys: ["noteId", "notebookId", "noteNumber", "title", "bodyMarkdown", "readOnly", "createdAt", "updatedAt", "metaJSON", "tags"], addonName: addonName)
    XCTAssertEqual(object["noteId"], .string("note-1"), addonName)
    XCTAssertEqual(object["notebookId"], .string("notebook-1"), addonName)
    XCTAssertEqual(object["noteNumber"], .number(1), addonName)
    XCTAssertEqual(object["title"], .string("Fixture"), addonName)
    XCTAssertEqual(object["bodyMarkdown"], .string("# fixture\n\nbody"), addonName)
    XCTAssertEqual(object["readOnly"], .bool(false), addonName)
    XCTAssertEqual(object["createdAt"], .string("2026-01-01T00:00:00Z"), addonName)
    XCTAssertEqual(object["updatedAt"], .string("2026-01-01T00:00:00Z"), addonName)
    XCTAssertEqual(object["metaJSON"], .null, addonName)
    XCTAssertEqual(object["tags"], .array([]), addonName)
  }

  private func assertFixtureNotebook(_ value: JSONValue?, addonName: String) {
    let object = assertObject(value, keys: ["notebookId", "title", "readOnly", "createdAt", "updatedAt", "metaJSON", "tags", "noteCount"], addonName: addonName)
    XCTAssertEqual(object["notebookId"], .string("notebook-1"), addonName)
    XCTAssertEqual(object["title"], .string("Fixture Notebook"), addonName)
    XCTAssertEqual(object["readOnly"], .bool(false), addonName)
    XCTAssertEqual(object["createdAt"], .string("2026-01-01T00:00:00Z"), addonName)
    XCTAssertEqual(object["updatedAt"], .string("2026-01-01T00:00:00Z"), addonName)
    XCTAssertEqual(object["metaJSON"], .null, addonName)
    XCTAssertEqual(object["tags"], .array([]), addonName)
    XCTAssertEqual(object["noteCount"], .number(1), addonName)
  }

  private func assertFixtureAttachment(
    _ value: JSONValue?, noteID: String? = nil, notebookID: String? = nil, role: String,
    includePosition: Bool, addonName: String
  ) {
    var keys: Set<String> = ["file", "role"]
    if noteID != nil { keys.insert("noteId") }
    if notebookID != nil { keys.insert("notebookId") }
    if includePosition { keys.insert("position") }
    let object = assertObject(value, keys: keys, addonName: addonName)
    if let noteID { XCTAssertEqual(object["noteId"], .string(noteID), addonName) }
    if let notebookID { XCTAssertEqual(object["notebookId"], .string(notebookID), addonName) }
    XCTAssertEqual(object["role"], .string(role), addonName)
    if includePosition { XCTAssertEqual(object["position"], .number(0), addonName) }
    assertFixtureFile(object["file"], addonName: addonName)
  }

  private func assertFixtureFile(_ value: JSONValue?, addonName: String) {
    let object = assertObject(value, keys: ["fileId", "storageKind", "s3URL", "mediaType", "byteSize", "sha256", "originalFilename", "createdAt", "migratedAt"], addonName: addonName)
    XCTAssertEqual(object["fileId"], .string("file-1"), addonName)
    XCTAssertEqual(object["storageKind"], .string("local"), addonName)
    XCTAssertEqual(object["s3URL"], .null, addonName)
    XCTAssertEqual(object["mediaType"], .string("text/plain"), addonName)
    XCTAssertEqual(object["byteSize"], .number(7), addonName)
    XCTAssertEqual(object["sha256"], .string("abc"), addonName)
    XCTAssertEqual(object["originalFilename"], .string("fixture.txt"), addonName)
    XCTAssertEqual(object["createdAt"], .string("2026-01-01T00:00:00Z"), addonName)
    XCTAssertEqual(object["migratedAt"], .null, addonName)
  }

  private func assertFixtureComment(_ value: JSONValue?, addonName: String) {
    let object = assertObject(value, keys: ["commentId", "noteId", "notebookId", "bodyMarkdown", "author", "createdAt"], addonName: addonName)
    XCTAssertEqual(object["commentId"], .string("comment-1"), addonName)
    XCTAssertEqual(object["noteId"], .string("note-1"), addonName)
    XCTAssertEqual(object["notebookId"], .null, addonName)
    XCTAssertEqual(object["bodyMarkdown"], .string("Agent fixture"), addonName)
    XCTAssertEqual(object["author"], .string("assistant"), addonName)
    XCTAssertEqual(object["createdAt"], .string("2026-01-01T00:00:00Z"), addonName)
  }

  private func assertFixtureSearchResult(_ value: JSONValue?, addonName: String) {
    assertExactArray(value, count: 1, addonName: addonName) { item in
      let object = self.assertObject(item, keys: ["note", "noteId", "notebookId", "snippet", "rank", "matchedTags", "isLinkedNeighbor", "termCoverage"], addonName: addonName)
      self.assertFixtureNote(object["note"], addonName: addonName)
      XCTAssertEqual(object["noteId"], .string("note-1"), addonName)
      XCTAssertEqual(object["notebookId"], .string("notebook-1"), addonName)
      XCTAssertEqual(object["snippet"], .string("fixture match"), addonName)
      XCTAssertEqual(object["rank"], .number(1), addonName)
      XCTAssertEqual(object["matchedTags"], .array([]), addonName)
      XCTAssertEqual(object["isLinkedNeighbor"], .bool(false), addonName)
      XCTAssertEqual(object["termCoverage"], .number(1), addonName)
    }
  }

  private func assertFixtureNeighbor(_ value: JSONValue?, addonName: String) {
    assertExactArray(value, count: 1, addonName: addonName) { item in
      let object = self.assertObject(item, keys: ["seedNoteId", "note", "noteId", "targetNoteId", "edgeKind", "weight", "hopCount", "pathNoteIds"], addonName: addonName)
      self.assertFixtureNote(object["note"], addonName: addonName)
      XCTAssertEqual(object["seedNoteId"], .string("note-1"), addonName)
      XCTAssertEqual(object["noteId"], .string("note-1"), addonName)
      XCTAssertEqual(object["targetNoteId"], .string("note-1"), addonName)
      XCTAssertEqual(object["edgeKind"], .string("related"), addonName)
      XCTAssertEqual(object["weight"], .number(1), addonName)
      XCTAssertEqual(object["hopCount"], .number(1), addonName)
      XCTAssertEqual(object["pathNoteIds"], .array([.string("note-1"), .string("note-2")]), addonName)
    }
  }

  private func assertGraphQLPayload(_ payload: JSONObject, addonName: String) {
    let body = assertObject(payload["body"], keys: ["data"], addonName: addonName)
    let data = assertObject(body["data"], keys: ["root"], addonName: addonName)
    let root = assertObject(data["root"], keys: ["result", "note", "notebook", "notes", "file", "noteFiles", "notebookFiles", "comment"], addonName: addonName)
    XCTAssertEqual(payload["fieldPayload"], .object(root), addonName)
    assertRawFixtureNote(payload["note"], addonName: addonName)
    assertRawFixtureNotebook(payload["notebook"], addonName: addonName)
    assertExactArray(payload["notes"], count: 1, addonName: addonName) { self.assertRawFixtureNote($0, addonName: addonName) }
    assertRawFixtureFile(payload["file"], addonName: addonName)
    assertExactArray(payload["noteFiles"], count: 1, addonName: addonName) { self.assertRawFixtureAttachment($0, noteID: "note-1", role: "related", includePosition: true, addonName: addonName) }
    assertExactArray(payload["notebookFiles"], count: 1, addonName: addonName) { self.assertRawFixtureAttachment($0, notebookID: "notebook-1", role: "source-document", includePosition: false, addonName: addonName) }
    assertRawFixtureComment(payload["comment"], addonName: addonName)
    let result = assertObject(payload["result"], keys: ["accepted", "status"], addonName: addonName)
    XCTAssertEqual(result["accepted"], .bool(true), addonName)
    XCTAssertEqual(result["status"], .string("ok"), addonName)
  }

  private func assertRawFixtureNote(_ value: JSONValue?, addonName: String) {
    let object = assertObject(value, keys: ["noteId", "notebookId", "noteNumber", "title", "bodyMarkdown", "readOnly", "createdAt", "updatedAt", "metaJSON", "tags", "createdBy", "updatedBy"], addonName: addonName)
    XCTAssertEqual(object["noteId"], .string("note-1"), addonName)
    XCTAssertEqual(object["notebookId"], .string("notebook-1"), addonName)
    XCTAssertEqual(object["noteNumber"], .number(1), addonName)
    XCTAssertEqual(object["title"], .string("Fixture"), addonName)
    XCTAssertEqual(object["bodyMarkdown"], .string("# fixture\n\nbody"), addonName)
    XCTAssertEqual(object["readOnly"], .bool(false), addonName)
    XCTAssertEqual(object["metaJSON"], .null, addonName)
    XCTAssertEqual(object["tags"], .array([]), addonName)
    XCTAssertEqual(object["createdBy"], .null, addonName)
    XCTAssertEqual(object["updatedBy"], .null, addonName)
  }

  private func assertRawFixtureNotebook(_ value: JSONValue?, addonName: String) {
    let keys: Set<String> = [
      "notebookId", "title", "readOnly", "createdAt", "updatedAt", "metaJSON", "tags",
      "firstNotePreview", "noteCount", "libraryId", "ownerUserId", "createdBy", "updatedBy"
    ]
    let object = assertObject(value, keys: keys, addonName: addonName)
    XCTAssertEqual(object["notebookId"], .string("notebook-1"), addonName)
    XCTAssertEqual(object["title"], .string("Fixture Notebook"), addonName)
    XCTAssertEqual(object["readOnly"], .bool(false), addonName)
    XCTAssertEqual(object["tags"], .array([]), addonName)
    XCTAssertEqual(object["noteCount"], .number(1), addonName)
    XCTAssertEqual(object["firstNotePreview"], .null, addonName)
    XCTAssertEqual(object["libraryId"], .null, addonName)
    XCTAssertEqual(object["ownerUserId"], .null, addonName)
    XCTAssertEqual(object["createdBy"], .null, addonName)
    XCTAssertEqual(object["updatedBy"], .null, addonName)
  }

  private func assertRawFixtureFile(_ value: JSONValue?, addonName: String) {
    let object = assertObject(value, keys: ["fileId", "storageKind", "s3Profile", "s3Bucket", "s3Key", "mediaType", "byteSize", "sha256", "originalFilename", "createdAt", "migratedAt"], addonName: addonName)
    XCTAssertEqual(object["fileId"], .string("file-1"), addonName)
    XCTAssertEqual(object["storageKind"], .string("local"), addonName)
    XCTAssertEqual(object["s3Profile"], .null, addonName)
    XCTAssertEqual(object["s3Bucket"], .null, addonName)
    XCTAssertEqual(object["s3Key"], .null, addonName)
    XCTAssertEqual(object["mediaType"], .string("text/plain"), addonName)
    XCTAssertEqual(object["byteSize"], .number(7), addonName)
    XCTAssertEqual(object["sha256"], .string("abc"), addonName)
    XCTAssertEqual(object["originalFilename"], .string("fixture.txt"), addonName)
    XCTAssertEqual(object["migratedAt"], .null, addonName)
  }

  private func assertRawFixtureAttachment(
    _ value: JSONValue?, noteID: String? = nil, notebookID: String? = nil, role: String,
    includePosition: Bool, addonName: String
  ) {
    var keys: Set<String> = ["file", "role"]
    if noteID != nil { keys.insert("noteId") }
    if notebookID != nil { keys.insert("notebookId") }
    if includePosition { keys.insert("position") }
    let object = assertObject(value, keys: keys, addonName: addonName)
    if let noteID { XCTAssertEqual(object["noteId"], .string(noteID), addonName) }
    if let notebookID { XCTAssertEqual(object["notebookId"], .string(notebookID), addonName) }
    XCTAssertEqual(object["role"], .string(role), addonName)
    if includePosition { XCTAssertEqual(object["position"], .number(0), addonName) }
    assertRawFixtureFile(object["file"], addonName: addonName)
  }

  private func assertRawFixtureComment(_ value: JSONValue?, addonName: String) {
    let object = assertObject(value, keys: ["commentId", "noteId", "notebookId", "bodyMarkdown", "author", "createdAt"], addonName: addonName)
    XCTAssertEqual(object["commentId"], .string("comment-1"), addonName)
    XCTAssertEqual(object["noteId"], .string("note-1"), addonName)
    XCTAssertEqual(object["notebookId"], .null, addonName)
    XCTAssertEqual(object["bodyMarkdown"], .string("Agent fixture"), addonName)
    XCTAssertEqual(object["author"], .string("assistant"), addonName)
  }

  private func assertExactArray(
    _ value: JSONValue?, count: Int, addonName: String, element: (JSONValue) -> Void
  ) {
    guard case let .array(values) = value else { return XCTFail("\(addonName) expected an array") }
    XCTAssertEqual(values.count, count, addonName)
    values.forEach(element)
  }

  private func assertObject(_ value: JSONValue?, keys: Set<String>, addonName: String) -> JSONObject {
    guard case let .object(object) = value else {
      XCTFail("\(addonName) expected an object")
      return [:]
    }
    XCTAssertEqual(Set(object.keys), keys, addonName)
    XCTAssertNil(object["localPath"], addonName)
    XCTAssertNil(object["diagnostics"], addonName)
    return object
  }

  private func temporaryTextFile() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("fixture.txt")
    try Data("fixture document".utf8).write(to: file)
    return file
  }
}
