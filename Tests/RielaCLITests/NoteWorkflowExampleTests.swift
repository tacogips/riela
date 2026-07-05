import Foundation
import RielaCore
import RielaNote
import XCTest
@testable import RielaCLI

final class NoteWorkflowExampleTests: XCTestCase {
  func testAutoTaggingWorkflowAppliesAITagsToExistingNote() async throws {
    let noteRoot = try makeNoteWorkflowRoot()
    defer { try? FileManager.default.removeItem(atPath: noteRoot) }
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot))
    let body = "# Auto Tag Target\n\nResearch note body."
    let note = try service.createNote(bodyMarkdown: body)

    let result = try await runWorkflow(
      "note-auto-tagging",
      variables: [
        "noteRoot": .string(noteRoot),
        "noteId": .string(note.noteId),
        "noteBodyMarkdown": .string(body),
        "trigger": .string("note-created")
      ]
    )

    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.rootOutput?["noteId"], .string(note.noteId))
    let tagged = try service.getNote(note.noteId)
    XCTAssertEqual(Set(tagged.tags.map(\.tag.name)), ["research", "auto-tagged"])
    XCTAssertEqual(Set(tagged.tags.map(\.provenance)), [.ai])
  }

  func testQuickMemoWorkflowCreatesMemoNotebookAndFixedTag() async throws {
    let noteRoot = try makeNoteWorkflowRoot()
    defer { try? FileManager.default.removeItem(atPath: noteRoot) }

    let result = try await runWorkflow(
      "note-quick-memo",
      variables: [
        "noteRoot": .string(noteRoot),
        "workflowInput": .object([
          "text": .string("# Quick memo\n\nRemember the Riela Note design."),
          "notebookTitle": .string("Quick Memos")
        ])
      ]
    )

    XCTAssertEqual(result.status, .completed)
    let noteId = try string(result.rootOutput?["noteId"], field: "noteId")
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot))
    let note = try service.getNote(noteId)
    XCTAssertEqual(note.title, "Quick memo")
    XCTAssertEqual(note.tags.map(\.tag.name), ["ノート"])
    let notebook = try service.getNotebook(note.notebookId)
    XCTAssertEqual(notebook.tags.map(\.tag.name), ["notebook-kind:user-memo"])
  }

  func testPDFIngestWorkflowCreatesImportedNotebookPages() async throws {
    let noteRoot = try makeNoteWorkflowRoot()
    defer { try? FileManager.default.removeItem(atPath: noteRoot) }

    let result = try await runWorkflow(
      "note-pdf-ingest",
      variables: [
        "noteRoot": .string(noteRoot),
        "workflowInput": .object([
          "title": .string("Imported PDF"),
          "sourceDocumentRef": .string("file:///tmp/source.pdf")
        ])
      ]
    )

    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.rootOutput?["pageCount"], .number(2))
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot))
    let notebooks = try service.listNotebooks()
    XCTAssertEqual(notebooks.count, 1)
    XCTAssertEqual(notebooks.first?.tags.map(\.tag.name), ["notebook-kind:imported-material"])
    XCTAssertEqual(try service.searchNotes(query: "Alpha OCR").count, 1)
    XCTAssertEqual(try service.searchNotes(query: "Beta OCR").count, 1)
  }

  func testYouTubeTranscriptWorkflowCreatesNoteAndRelatedVideoAttachment() async throws {
    let noteRoot = try makeNoteWorkflowRoot()
    defer { try? FileManager.default.removeItem(atPath: noteRoot) }
    let videoURL = "https://youtu.be/example"
    let videoData = Data("mock video bytes".utf8)
    let videoFile = URL(fileURLWithPath: noteRoot, isDirectory: true).appendingPathComponent("youtube-video.mp4")
    try videoData.write(to: videoFile)

    let result = try await runWorkflow(
      "note-youtube-transcript",
      variables: [
        "noteRoot": .string(noteRoot),
        "workflowInput": .object([
          "title": .string("Video Notes"),
          "videoUrl": .string(videoURL),
          "videoFilePath": .string(videoFile.path)
        ])
      ]
    )

    XCTAssertEqual(result.status, .completed)
    let noteId = try string(result.rootOutput?["noteId"], field: "noteId")
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot))
    let note = try service.getNote(noteId)
    XCTAssertEqual(note.tags.map(\.tag.name), ["youtube"])
    let files = try service.listFiles(noteId: noteId)
    XCTAssertEqual(files.count, 1)
    XCTAssertEqual(files.first?.role, .related)
    XCTAssertEqual(files.first?.file.mediaType, "video/mp4")
    let fileId = try XCTUnwrap(files.first?.file.fileId)
    XCTAssertEqual(try service.resolveFileContent(fileId: fileId), videoData)
  }

  func testNoteAgentWorkflowReturnsCitedAnswerFromSearchCandidates() async throws {
    let noteRoot = try makeNoteWorkflowRoot()
    defer { try? FileManager.default.removeItem(atPath: noteRoot) }
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot))
    let note = try service.createNote(
      bodyMarkdown: "# Architecture Note\n\nSource-backed notebooks stay searchable for the note agent."
    )
    _ = try service.createNote(
      bodyMarkdown: "# Duplicate Architecture Note\n\nSource-backed notebooks should be hidden by the workflow limit."
    )
    let scenarioPath = try makeNoteAgentScenario(noteId: note.noteId)

    let result = try await runWorkflow(
      "note-agent",
      variables: [
        "noteRoot": .string(noteRoot),
        "workflowInput": .object([
          "query": .string("source-backed notebooks"),
          "limit": .number(1)
        ])
      ],
      mockScenarioPath: scenarioPath.path
    )

    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(try string(result.rootOutput?["answerMarkdown"], field: "answerMarkdown"), "Architecture answer")
    let citations = try array(result.rootOutput?["citations"], field: "citations")
    let citation = try object(citations.first, field: "citations[0]")
    XCTAssertEqual(citation["noteId"], .string(note.noteId))
    XCTAssertEqual(try service.getNote(note.noteId).noteId, note.noteId)
    let retrieval = try XCTUnwrap(result.session.executions.first { $0.stepId == "retrieve-notes" })
    XCTAssertEqual(retrieval.acceptedOutput?.payload["resultCount"], .number(1))
  }

  func testNoteConfigAgentWorkflowAppliesAuditableConfigThroughGraphQL() async throws {
    let noteRoot = try makeNoteWorkflowRoot()
    defer { try? FileManager.default.removeItem(atPath: noteRoot) }
    let workflowRoot = URL(fileURLWithPath: noteRoot, isDirectory: true).appendingPathComponent("workflows")

    let result = try await runWorkflow(
      "note-config-agent",
      variables: [
        "noteRoot": .string(noteRoot),
        "workflowInput": .object([
          "request": .string("Create a business idea ingestion setup"),
          "workflowRoot": .string(workflowRoot.path)
        ])
      ]
    )

    XCTAssertEqual(result.status, .completed)
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot))
    XCTAssertTrue(try service.listTagClasses().contains { $0.classId == "business-idea" })
    XCTAssertTrue(try service.listTags().contains { $0.name == "business-idea" && $0.classId == "business-idea" })
    let autoAction = try XCTUnwrap(try service.listAutoActions().first {
      $0.actionId == "config-agent-auto-tagging-business-idea"
    })
    XCTAssertEqual(autoAction.workflowId, "note-auto-tagging")
    let scaffold = try object(result.rootOutput?["workflowScaffold"], field: "workflowScaffold")
    XCTAssertEqual(scaffold["workflowId"], .string("note-ingest-business-idea"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: workflowRoot.appendingPathComponent("note-ingest-business-idea/workflow.json").path))
  }

  private func makeNoteAgentScenario(noteId: String, function: String = #function) throws -> URL {
    let root = URL(fileURLWithPath: repositoryRoot(), isDirectory: true)
      .appendingPathComponent("tmp/RielaCLITests", isDirectory: true)
      .appendingPathComponent("NoteWorkflowExampleTests", isDirectory: true)
      .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let scenario: JSONObject = [
      "answer-with-citations": .object([
        "provider": .string("scenario-mock"),
        "model": .string("gpt-5.5"),
        "payload": .object([
          "status": .string("answered"),
          "answerMarkdown": .string("Architecture answer"),
          "citations": .array([
            .object([
              "noteId": .string(noteId),
              "title": .string("Architecture Note"),
              "snippet": .string("Source-backed notebooks")
            ])
          ]),
          "sourceNoteIds": .array([.string(noteId)])
        ])
      ])
    ]
    let path = root.appendingPathComponent("mock-scenario.json")
    try JSONEncoder().encode(JSONValue.object(scenario)).write(to: path)
    return path
  }

  private func runWorkflow(
    _ workflowName: String,
    variables: JSONObject,
    mockScenarioPath: String? = nil,
    function: String = #function
  ) async throws -> WorkflowRunResult {
    let root = repositoryRoot()
    let sessionStore = URL(fileURLWithPath: root, isDirectory: true)
      .appendingPathComponent("tmp/RielaCLITests", isDirectory: true)
      .appendingPathComponent("NoteWorkflowExampleTests", isDirectory: true)
      .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
      .appendingPathComponent("\(workflowName)-sessions-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: sessionStore) }
    let result = await RielaCLIApplication().run([
      "workflow", "run", workflowName,
      "--workflow-definition-dir", "\(root)/examples",
      "--mock-scenario", mockScenarioPath ?? "\(root)/examples/\(workflowName)/mock-scenario.json",
      "--session-store", sessionStore.path,
      "--variables", try jsonObjectString(variables),
      "--output", "json"
    ])
    XCTAssertEqual(result.exitCode, .success, "\(workflowName): \(result.stderr)\n\(result.stdout)")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(WorkflowRunResult.self, from: Data(result.stdout.utf8))
  }

  private func makeNoteWorkflowRoot(function: String = #function) throws -> String {
    let root = URL(fileURLWithPath: repositoryRoot(), isDirectory: true)
      .appendingPathComponent("tmp/RielaCLITests", isDirectory: true)
      .appendingPathComponent("NoteWorkflowExampleTests", isDirectory: true)
      .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.path
  }

  private func repositoryRoot() -> String {
    var url = URL(fileURLWithPath: #filePath)
    while url.pathComponents.count > 1 {
      if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
        return url.path
      }
      url.deleteLastPathComponent()
    }
    return FileManager.default.currentDirectoryPath
  }

  private func jsonObjectString(_ object: JSONObject) throws -> String {
    let data = try JSONEncoder().encode(JSONValue.object(object))
    guard let string = String(data: data, encoding: .utf8) else {
      throw CLIUsageError("failed to encode test JSON")
    }
    return string
  }

  private func string(_ value: JSONValue?, field: String) throws -> String {
    guard case let .string(string)? = value else {
      XCTFail("expected \(field) string")
      return ""
    }
    return string
  }

  private func array(_ value: JSONValue?, field: String) throws -> [JSONValue] {
    guard case let .array(array)? = value else {
      XCTFail("expected \(field) array")
      return []
    }
    return array
  }

  private func object(_ value: JSONValue?, field: String) throws -> JSONObject {
    guard case let .object(object)? = value else {
      XCTFail("expected \(field) object")
      return [:]
    }
    return object
  }
}
