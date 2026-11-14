import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class NoteCommandTests: XCTestCase {
  func testParsesNoteCommands() throws {
    XCTAssertEqual(
      try RielaArgumentParser().parse(["note", "add", "--body", "# Hello", "--output", "json"]),
      .note(NoteCommand(
        kind: .add,
        options: CLICommandOptions(
          scope: "note",
          command: "add",
          arguments: ["--body", "# Hello", "--output", "json"],
          output: .json
        )
      ))
    )
    XCTAssertEqual(
      try RielaArgumentParser().parse(["note", "add", "--body", "# Hello", "--output=json"]),
      .note(NoteCommand(
        kind: .add,
        options: CLICommandOptions(
          scope: "note",
          command: "add",
          arguments: ["--body", "# Hello", "--output=json"],
          output: .json
        )
      ))
    )
    XCTAssertEqual(
      try RielaArgumentParser().parse(["note", "edit", "note-1", "--body", "# Updated"]),
      .note(NoteCommand(
        kind: .edit,
        options: CLICommandOptions(
          scope: "note",
          command: "edit",
          target: "note-1",
          arguments: ["--body", "# Updated"],
          output: .text
        )
      ))
    )
    XCTAssertEqual(
      try RielaArgumentParser().parse(["note", "delete", "note-1"]),
      .note(NoteCommand(
        kind: .delete,
        options: CLICommandOptions(
          scope: "note",
          command: "delete",
          target: "note-1",
          output: .text
        )
      ))
    )
    XCTAssertEqual(
      try RielaArgumentParser().parse(["note", "notebook", "list", "--output", "table"]),
      .note(NoteCommand(
        kind: .notebook,
        options: CLICommandOptions(
          scope: "note",
          command: "notebook",
          target: "list",
          arguments: ["--output", "table"],
          output: .table
        )
      ))
    )
    XCTAssertEqual(
      try RielaArgumentParser().parse([
        "note", "storage", "migrate", "file-1",
        "--s3-endpoint", "http://127.0.0.1:9000",
        "--s3-region", "ap-northeast-1",
        "--s3-bucket", "notes"
      ]),
      .note(NoteCommand(
        kind: .storage,
        options: CLICommandOptions(
          scope: "note",
          command: "storage",
          target: "migrate",
          arguments: [
            "file-1",
            "--s3-endpoint", "http://127.0.0.1:9000",
            "--s3-region", "ap-northeast-1",
            "--s3-bucket", "notes"
          ],
          output: .text
        )
      ))
    )
    XCTAssertEqual(
      try RielaArgumentParser().parse(["note", "client", "list", "--output", "table"]),
      .note(NoteCommand(
        kind: .client,
        options: CLICommandOptions(
          scope: "note",
          command: "client",
          target: "list",
          arguments: ["--output", "table"],
          output: .table
        )
      ))
    )
  }

  func testNoteReadonlyRequiresExactlyOneValueFlag() async {
    let app = RielaCLIApplication()

    let missingValue = await app.run(["note", "readonly", "note-1"])
    XCTAssertEqual(missingValue.exitCode, .failure)
    XCTAssertTrue(missingValue.stderr.contains("note readonly requires exactly one"))

    let conflictingValues = await app.run(["note", "readonly", "note-1", "--on", "--off"])
    XCTAssertEqual(conflictingValues.exitCode, .failure)
    XCTAssertTrue(conflictingValues.stderr.contains("note readonly requires exactly one"))
  }

  func testNoteListTextFailurePrintsDiagnostics() async throws {
    let noteRoot = try makeNoteCommandRoot()
    defer {
      try? FileManager.default.removeItem(atPath: noteRoot)
    }
    let app = RielaCLIApplication()

    let result = await app.run([
      "note", "list",
      "--notebook", "missing-notebook"
    ], environment: ["RIELA_NOTE_ROOT": noteRoot])

    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stdout.contains("requested note resource was not found"), result.stdout + result.stderr)
  }

  func testNoteAddRejectsPositionalArgument() async throws {
    let noteRoot = try makeNoteCommandRoot()
    defer {
      try? FileManager.default.removeItem(atPath: noteRoot)
    }
    let app = RielaCLIApplication()

    let result = await app.run([
      "note", "add", "ignored-target",
      "--body", "Alpha body"
    ], environment: ["RIELA_NOTE_ROOT": noteRoot])

    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(
      result.stderr.contains("note add does not accept positional argument 'ignored-target'"),
      result.stderr + result.stdout
    )
  }

  func testNoteTagRejectsMixedApplyAndRemoveOperations() async throws {
    let noteRoot = try makeNoteCommandRoot()
    defer {
      try? FileManager.default.removeItem(atPath: noteRoot)
    }
    let app = RielaCLIApplication()
    let environment = ["RIELA_NOTE_ROOT": noteRoot]

    let add = await app.run([
      "note", "add",
      "--body", "Alpha body",
      "--tag", "research",
      "--output", "json"
    ], environment: environment)
    XCTAssertEqual(add.exitCode, .success, add.stderr + add.stdout)
    let note = try object(jsonObject(add.stdout)["note"], field: "note")
    let noteId = try string(note["noteId"], field: "note.noteId")

    let result = await app.run([
      "note", "tag", noteId,
      "--add", "archive",
      "--remove", "research"
    ], environment: environment)

    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(
      result.stderr.contains("note tag cannot combine add/apply and remove operations"),
      result.stderr + result.stdout
    )

    let researchSearch = await app.run([
      "note", "search", "Alpha",
      "--tag", "research",
      "--output", "json"
    ], environment: environment)
    XCTAssertEqual(researchSearch.exitCode, .success, researchSearch.stderr + researchSearch.stdout)
    XCTAssertEqual(try array(jsonObject(researchSearch.stdout)["value"], field: "research search value").count, 1)

    let archiveSearch = await app.run([
      "note", "search", "Alpha",
      "--tag", "archive",
      "--output", "json"
    ], environment: environment)
    XCTAssertEqual(archiveSearch.exitCode, .success, archiveSearch.stderr + archiveSearch.stdout)
    XCTAssertEqual(try array(jsonObject(archiveSearch.stdout)["value"], field: "archive search value").count, 0)
  }

  func testNoteNotebookListAppliesTagFilter() async throws {
    let noteRoot = try makeNoteCommandRoot()
    defer {
      try? FileManager.default.removeItem(atPath: noteRoot)
    }
    let app = RielaCLIApplication()
    let environment = ["RIELA_NOTE_ROOT": noteRoot]

    let imported = await app.run([
      "note", "notebook", "create", "Imported",
      "--kind-tag", "notebook-kind:imported-material",
      "--output", "json"
    ], environment: environment)
    XCTAssertEqual(imported.exitCode, .success, imported.stderr + imported.stdout)
    let importedId = try string(
      object(jsonObject(imported.stdout)["notebook"], field: "imported notebook")["notebookId"],
      field: "imported notebook.notebookId"
    )

    let memo = await app.run([
      "note", "notebook", "create", "Memo",
      "--kind-tag", "notebook-kind:user-memo",
      "--output", "json"
    ], environment: environment)
    XCTAssertEqual(memo.exitCode, .success, memo.stderr + memo.stdout)

    let list = await app.run([
      "note", "notebook", "list",
      "--tag", "notebook-kind:imported-material",
      "--output", "json"
    ], environment: environment)

    XCTAssertEqual(list.exitCode, .success, list.stderr + list.stdout)
    let values = try array(jsonObject(list.stdout)["value"], field: "notebook list value")
    XCTAssertEqual(values.count, 1)
    let listedNotebook = try object(try XCTUnwrap(values.first), field: "listed notebook")
    XCTAssertEqual(try string(listedNotebook["notebookId"], field: "listed notebook.notebookId"), importedId)
  }

  func testNoteCommandRoundTripUsesNoteRoot() async throws {
    let noteRoot = try makeNoteCommandRoot()
    defer {
      try? FileManager.default.removeItem(atPath: noteRoot)
    }
    NoteCommandS3URLProtocol.reset()
    URLProtocol.registerClass(NoteCommandS3URLProtocol.self)
    defer {
      URLProtocol.unregisterClass(NoteCommandS3URLProtocol.self)
    }
    let app = RielaCLIApplication()
    let environment = [
      "RIELA_NOTE_ROOT": noteRoot,
      "NOTE_TEST_ACCESS_KEY_ID": "access-key",
      "NOTE_TEST_SECRET_ACCESS_KEY": "secret-key"
    ]

    let add = await app.run([
      "note", "add",
      "--body", "Alpha body",
      "--title", "CLI Note",
      "--tag", "research",
      "--output=json"
    ], environment: environment)
    XCTAssertEqual(add.exitCode, .success)
    let addObject = try jsonObject(add.stdout)
    let note = try object(addObject["note"], field: "note")
    let noteId = try string(note["noteId"], field: "note.noteId")
    XCTAssertEqual(try string(note["title"], field: "note.title"), "CLI Note")
    XCTAssertEqual(try string(note["bodyMarkdown"], field: "note.bodyMarkdown"), "Alpha body")

    let search = await app.run([
      "note", "search", "Alpha",
      "--tag", "research",
      "--output", "json"
    ], environment: environment)
    XCTAssertEqual(search.exitCode, .success)
    let searchObject = try jsonObject(search.stdout)
    let searchValues = try array(searchObject["value"], field: "value")
    let firstSearchValue = try XCTUnwrap(searchValues.first)
    XCTAssertEqual(try string(object(object(firstSearchValue, field: "search[0]")["note"], field: "search[0].note")["noteId"], field: "search noteId"), noteId)

    let list = await app.run([
      "note", "list",
      "--tag", "research",
      "--output", "json"
    ], environment: environment)
    XCTAssertEqual(list.exitCode, .success)
    let listed = try array(jsonObject(list.stdout)["value"], field: "note list value")
    let firstListedNote = try XCTUnwrap(listed.first)
    XCTAssertEqual(try string(object(firstListedNote, field: "listed note")["noteId"], field: "listed noteId"), noteId)

    let archiveTag = await app.run([
      "note", "tag", noteId,
      "--add", "archive",
      "--output", "json"
    ], environment: environment)
    XCTAssertEqual(archiveTag.exitCode, .success, archiveTag.stderr + archiveTag.stdout)
    let tagObject = try jsonObject(archiveTag.stdout)
    XCTAssertEqual(try array(tagObject["applied"], field: "applied").count, 1)

    let removeResearchTag = await app.run([
      "note", "tag", noteId,
      "--remove", "research",
      "--output", "json"
    ], environment: environment)
    XCTAssertEqual(removeResearchTag.exitCode, .success, removeResearchTag.stderr + removeResearchTag.stdout)
    let removeTagObject = try jsonObject(removeResearchTag.stdout)
    XCTAssertEqual(try array(removeTagObject["removed"], field: "removed").count, 1)

    let archiveSearch = await app.run([
      "note", "search", "Alpha",
      "--tag", "archive",
      "--output", "json"
    ], environment: environment)
    XCTAssertEqual(archiveSearch.exitCode, .success)
    XCTAssertEqual(try array(jsonObject(archiveSearch.stdout)["value"], field: "archive search value").count, 1)

    let comment = await app.run([
      "note", "comment", noteId,
      "--body", "Looks ready."
    ], environment: environment)
    XCTAssertEqual(comment.exitCode, .success)
    XCTAssertTrue(comment.stdout.contains("added comment"))

    let sourceFile = URL(fileURLWithPath: noteRoot, isDirectory: true).appendingPathComponent("source.txt")
    try "attachment".write(to: sourceFile, atomically: true, encoding: .utf8)
    let attach = await app.run([
      "note", "attach", noteId,
      sourceFile.path,
      "--media-type", "text/plain",
      "--output", "json"
    ], environment: environment)
    XCTAssertEqual(attach.exitCode, .success)
    let attachObject = try jsonObject(attach.stdout)
    let attachedFile = try object(attachObject["file"], field: "file")
    XCTAssertFalse(try string(attachedFile["fileId"], field: "file.fileId").isEmpty)
    let localPath = try string(attachedFile["localPath"], field: "file.localPath")
    let storedURL = URL(fileURLWithPath: noteRoot, isDirectory: true)
      .appendingPathComponent("files", isDirectory: true)
      .appendingPathComponent(localPath)
    XCTAssertEqual(try String(contentsOf: storedURL, encoding: .utf8), "attachment")

    let migrate = await app.run([
      "note", "storage", "migrate", "--all",
      "--to", "s3",
      "--s3-endpoint", "https://cli-s3.test",
      "--s3-region", "ap-northeast-1",
      "--s3-bucket", "notes",
      "--s3-key-prefix", "cli",
      "--s3-access-key-id-env", "NOTE_TEST_ACCESS_KEY_ID",
      "--s3-secret-access-key-env", "NOTE_TEST_SECRET_ACCESS_KEY"
    ], environment: environment)
    XCTAssertEqual(migrate.exitCode, .success, migrate.stderr + migrate.stdout)
    XCTAssertTrue(migrate.stdout.contains("migrated 1 file(s)"), migrate.stderr + migrate.stdout)
    XCTAssertEqual(NoteCommandS3URLProtocol.methods(), ["PUT"])

    let edit = await app.run([
      "note", "edit", noteId,
      "--body", "# CLI Note\n\nUpdated body"
    ], environment: environment)
    XCTAssertEqual(edit.exitCode, .success)
    XCTAssertTrue(edit.stdout.contains("updated note"))

    let append = await app.run([
      "note", "edit", noteId,
      "--append",
      "--body", "Appended body"
    ], environment: environment)
    XCTAssertEqual(append.exitCode, .success)
    XCTAssertTrue(append.stdout.contains("updated note"))

    let show = await app.run(["note", "show", noteId], environment: environment)
    XCTAssertEqual(show.exitCode, .success)
    XCTAssertTrue(show.stdout.contains("Updated body"))
    XCTAssertTrue(show.stdout.contains("Appended body"))

    let notebooks = await app.run(["note", "notebook", "list"], environment: environment)
    XCTAssertEqual(notebooks.exitCode, .success)
    XCTAssertTrue(notebooks.stdout.contains("CLI Note"))

    let delete = await app.run(["note", "delete", noteId], environment: environment)
    XCTAssertEqual(delete.exitCode, .success)
    XCTAssertTrue(delete.stdout.contains("deleted note"))
  }

  func testNoteClientCommandsRegisterListAndRevoke() async throws {
    let noteRoot = try makeNoteCommandRoot()
    defer {
      try? FileManager.default.removeItem(atPath: noteRoot)
    }
    let app = RielaCLIApplication()
    let environment = ["RIELA_NOTE_ROOT": noteRoot]

    let register = await app.run([
      "note", "client", "register",
      "--display-name", "iPad",
      "--output", "json"
    ], environment: environment)
    XCTAssertEqual(register.exitCode, .success, register.stderr + register.stdout)
    let registered = try jsonObject(register.stdout)
    let clientId = try string(object(registered["client"], field: "client")["clientId"], field: "client.clientId")
    let bearerToken = try string(registered["bearerToken"], field: "bearerToken")
    XCTAssertTrue(bearerToken.hasPrefix("rn_"))
    XCTAssertEqual(bearerToken.count, 46)
    XCTAssertEqual(try string(registered["registrationMode"], field: "registrationMode"), "challenge")

    let list = await app.run(["note", "client", "list"], environment: environment)
    XCTAssertEqual(list.exitCode, .success)
    XCTAssertTrue(list.stdout.contains(clientId))
    XCTAssertTrue(list.stdout.contains("iPad"))

    let revoke = await app.run(["note", "client", "revoke", clientId], environment: environment)
    XCTAssertEqual(revoke.exitCode, .success)
    XCTAssertTrue(revoke.stdout.contains("revoked client \(clientId)"))

    let activeList = await app.run(["note", "client", "list"], environment: environment)
    XCTAssertEqual(activeList.exitCode, .success)
    XCTAssertFalse(activeList.stdout.contains(clientId))

    let revokedList = await app.run(["note", "client", "list", "--include-revoked"], environment: environment)
    XCTAssertEqual(revokedList.exitCode, .success)
    XCTAssertTrue(revokedList.stdout.contains("revoked"))
    XCTAssertTrue(revokedList.stdout.contains(clientId))
  }

  func testNoteClientRegisterDirectModeIsExplicit() async throws {
    let noteRoot = try makeNoteCommandRoot()
    defer {
      try? FileManager.default.removeItem(atPath: noteRoot)
    }
    let app = RielaCLIApplication()
    let environment = ["RIELA_NOTE_ROOT": noteRoot]

    let register = await app.run([
      "note", "client", "register",
      "--display-name", "Local admin",
      "--direct",
      "--output", "json"
    ], environment: environment)

    XCTAssertEqual(register.exitCode, .success, register.stderr + register.stdout)
    let registered = try jsonObject(register.stdout)
    XCTAssertEqual(try string(registered["registrationMode"], field: "registrationMode"), "direct")
    let bearerToken = try string(registered["bearerToken"], field: "bearerToken")
    XCTAssertTrue(bearerToken.hasPrefix("rn_"))
    XCTAssertEqual(bearerToken.count, 46)
  }

  func testNoteStorageMigrateRequiresExplicitFileIdOrAll() async throws {
    let noteRoot = try makeNoteCommandRoot()
    defer {
      try? FileManager.default.removeItem(atPath: noteRoot)
    }
    let app = RielaCLIApplication()
    let environment = ["RIELA_NOTE_ROOT": noteRoot]

    let missingTarget = await app.run([
      "note", "storage", "migrate",
      "--to", "s3"
    ], environment: environment)
    XCTAssertEqual(missingTarget.exitCode, .failure)
    XCTAssertTrue(
      (missingTarget.stderr + missingTarget.stdout).contains("requires a file id or --all"),
      missingTarget.stderr + missingTarget.stdout
    )

    let conflictingTarget = await app.run([
      "note", "storage", "migrate", "file-1",
      "--all",
      "--to", "s3"
    ], environment: environment)
    XCTAssertEqual(conflictingTarget.exitCode, .failure)
    XCTAssertTrue(
      (conflictingTarget.stderr + conflictingTarget.stdout).contains("cannot combine a file id with --all"),
      conflictingTarget.stderr + conflictingTarget.stdout
    )
  }

  func testNoteNotebookCommandsUseGraphQLDocuments() async throws {
    let noteRoot = try makeNoteCommandRoot()
    defer {
      try? FileManager.default.removeItem(atPath: noteRoot)
    }
    let app = RielaCLIApplication()
    let environment = ["RIELA_NOTE_ROOT": noteRoot]

    let create = await app.run([
      "note", "notebook", "create", "Research Inbox",
      "--kind-tag", "notebook-kind:user-memo",
      "--output", "json"
    ], environment: environment)
    XCTAssertEqual(create.exitCode, .success, create.stderr + create.stdout)
    let payload = try jsonObject(create.stdout)
    let notebook = try object(payload["notebook"], field: "notebook")
    let notebookId = try string(notebook["notebookId"], field: "notebook.notebookId")

    let show = await app.run(["note", "notebook", "show", notebookId], environment: environment)
    XCTAssertEqual(show.exitCode, .success)
    XCTAssertTrue(show.stdout.contains("Research Inbox"))

    let delete = await app.run(["note", "notebook", "delete", notebookId], environment: environment)
    XCTAssertEqual(delete.exitCode, .success)
    XCTAssertTrue(delete.stdout.contains("deleted notebook \(notebookId)"))

    let aliasCreate = await app.run([
      "note", "notebook", "create", "Delete Alias",
      "--output", "json"
    ], environment: environment)
    XCTAssertEqual(aliasCreate.exitCode, .success, aliasCreate.stderr + aliasCreate.stdout)
    let aliasPayload = try jsonObject(aliasCreate.stdout)
    let aliasNotebookId = try string(
      object(aliasPayload["notebook"], field: "alias notebook")["notebookId"],
      field: "alias notebook.notebookId"
    )

    let aliasDelete = await app.run(["note", "delete", "--notebook", aliasNotebookId], environment: environment)
    XCTAssertEqual(aliasDelete.exitCode, .success)
    XCTAssertTrue(aliasDelete.stdout.contains("deleted notebook \(aliasNotebookId)"))
  }

  func testScopedGraphQLExecuteRunsNoteDocument() async throws {
    let noteRoot = try makeNoteCommandRoot()
    defer {
      try? FileManager.default.removeItem(atPath: noteRoot)
    }
    let app = RielaCLIApplication()

    let create = await app.run([
      "graphql", "execute",
      "--query", """
      mutation CreateNote($input: CreateNoteInput!) {
        createNote(input: $input) { result { accepted status diagnostics } note { noteId bodyMarkdown } }
      }
      """,
      "--variables", ##"{"input":{"bodyMarkdown":"# GraphQL CLI\n\nAlpha from document"}}"##,
      "--note-root", noteRoot,
      "--operation-name", "CreateNote",
      "--output", "json"
    ])

    XCTAssertEqual(create.exitCode, .success, create.stderr + create.stdout)
    let scoped = try JSONDecoder().decode(ScopedParityCommandResult.self, from: Data(create.stdout.utf8))
    XCTAssertEqual(scoped.status, "ok")
    let response = try jsonObject(try XCTUnwrap(scoped.records.first))
    let data = try object(response["data"], field: "data")
    let createNote = try object(data["createNote"], field: "data.createNote")
    let result = try object(createNote["result"], field: "data.createNote.result")
    XCTAssertEqual(result["accepted"], .bool(true))
    let note = try object(createNote["note"], field: "data.createNote.note")
    XCTAssertFalse(try string(note["noteId"], field: "note.noteId").isEmpty)
    XCTAssertEqual(try string(note["bodyMarkdown"], field: "note.bodyMarkdown"), "# GraphQL CLI\n\nAlpha from document")
  }

  private func makeNoteCommandRoot(function: String = #function) throws -> String {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/RielaCLITests", isDirectory: true)
      .appendingPathComponent("NoteCommandTests", isDirectory: true)
      .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.path
  }

  private func jsonObject(_ text: String?) throws -> JSONObject {
    guard let text, let data = text.data(using: .utf8) else {
      throw XCTSkip("missing JSON text")
    }
    guard case let .object(object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
      throw XCTSkip("expected JSON object")
    }
    return object
  }

  private func object(_ value: JSONValue?, field: String) throws -> JSONObject {
    guard case let .object(object)? = value else {
      XCTFail("expected \(field) object")
      return [:]
    }
    return object
  }

  private func array(_ value: JSONValue?, field: String) throws -> [JSONValue] {
    guard case let .array(array)? = value else {
      XCTFail("expected \(field) array")
      return []
    }
    return array
  }

  private func string(_ value: JSONValue?, field: String) throws -> String {
    guard case let .string(string)? = value else {
      XCTFail("expected \(field) string")
      return ""
    }
    return string
  }
}

private final class NoteCommandS3URLProtocol: URLProtocol {
  private static let state = NoteCommandS3URLProtocolState()

  override static func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "cli-s3.test"
  }

  override static func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let requestURL = request.url, let method = request.httpMethod else {
      finish(statusCode: 400)
      return
    }
    Self.state.lock()
    Self.state.record(method: method)
    switch method {
    case "PUT":
      Self.state.store(data: requestBodyData(), path: requestURL.path)
      Self.state.unlock()
      finish(statusCode: 200)
    case "GET":
      let data = Self.state.data(path: requestURL.path)
      Self.state.unlock()
      guard let data else {
        finish(statusCode: 404)
        return
      }
      finish(statusCode: 200, data: data)
    default:
      Self.state.unlock()
      finish(statusCode: 405)
    }
  }

  override func stopLoading() {}

  static func reset() {
    state.reset()
  }

  static func methods() -> [String] {
    state.methods()
  }

  private func finish(statusCode: Int, data: Data = Data()) {
    guard let url = request.url,
          let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
          ) else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if !data.isEmpty {
      client?.urlProtocol(self, didLoad: data)
    }
    client?.urlProtocolDidFinishLoading(self)
  }

  private func requestBodyData() -> Data {
    if let body = request.httpBody {
      return body
    }
    guard let stream = request.httpBodyStream else {
      return Data()
    }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    stream.open()
    defer {
      stream.close()
    }
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count <= 0 {
        break
      }
      data.append(buffer, count: count)
    }
    return data
  }
}

private final class NoteCommandS3URLProtocolState: @unchecked Sendable {
  private let lockValue = NSLock()
  private var objects: [String: Data] = [:]
  private var recordedMethods: [String] = []

  func lock() {
    lockValue.lock()
  }

  func unlock() {
    lockValue.unlock()
  }

  func record(method: String) {
    recordedMethods.append(method)
  }

  func store(data: Data, path: String) {
    objects[path] = data
  }

  func data(path: String) -> Data? {
    objects[path]
  }

  func reset() {
    lockValue.lock()
    defer { lockValue.unlock() }
    objects = [:]
    recordedMethods = []
  }

  func methods() -> [String] {
    lockValue.lock()
    defer { lockValue.unlock() }
    return recordedMethods
  }
}
