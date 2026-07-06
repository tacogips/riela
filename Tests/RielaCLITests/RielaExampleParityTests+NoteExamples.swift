import Foundation
import RielaCore
import RielaNote
import XCTest
@testable import RielaCLI

extension RielaExampleParityTests {
  func noteExampleVariables(workflowName: String, root: URL) throws -> String? {
    let noteRoot = root.appendingPathComponent("tmp/test-note-example-\(workflowName)-\(UUID().uuidString)", isDirectory: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: noteRoot)
    }
    switch workflowName {
    case "note-agent":
      let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot.path))
      _ = try service.createNote(
        bodyMarkdown: "# Architecture Note\n\nSource-backed notebooks stay searchable for the note agent."
      )
      return try noteExampleJSON([
        "noteRoot": .string(noteRoot.path),
        "workflowInput": .object([
          "query": .string("source-backed notebooks"),
          "limit": .number(5)
        ])
      ])
    case "note-auto-tagging":
      let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot.path))
      let body = "# Auto Tag Target\n\nResearch note body."
      let note = try service.createNote(bodyMarkdown: body)
      return try noteExampleJSON([
        "noteRoot": .string(noteRoot.path),
        "noteId": .string(note.noteId),
        "noteBodyMarkdown": .string(body),
        "trigger": .string("note-created")
      ])
    case "note-pdf-ingest":
      try FileManager.default.createDirectory(at: noteRoot, withIntermediateDirectories: true)
      let sourcePDF = noteRoot.appendingPathComponent("source.pdf")
      try Data("mock source pdf bytes".utf8).write(to: sourcePDF)
      return try noteExampleJSON([
        "noteRoot": .string(noteRoot.path),
        "workflowInput": .object([
          "title": .string("Imported PDF"),
          "sourceDocumentRef": .string(sourcePDF.absoluteString)
        ])
      ])
    case "note-quick-memo":
      return try noteExampleJSON([
        "noteRoot": .string(noteRoot.path),
        "workflowInput": .object([
          "text": .string("# Quick memo\n\nRemember the design."),
          "notebookTitle": .string("Quick Memos")
        ])
      ])
    case "note-youtube-transcript":
      try FileManager.default.createDirectory(at: noteRoot, withIntermediateDirectories: true)
      let videoFile = noteRoot.appendingPathComponent("youtube-video.mp4")
      try Data("mock video bytes".utf8).write(to: videoFile)
      return try noteExampleJSON([
        "noteRoot": .string(noteRoot.path),
        "workflowInput": .object([
          "title": .string("Video Notes"),
          "videoUrl": .string("https://youtu.be/example"),
          "videoFilePath": .string(videoFile.path)
        ])
      ])
    case "note-config-agent":
      return try noteExampleJSON([
        "noteRoot": .string(noteRoot.path),
        "workflowInput": .object([
          "request": .string("Create a business idea ingestion setup"),
          "workflowRoot": .string(noteRoot.appendingPathComponent("workflows", isDirectory: true).path)
        ])
      ])
    case "note-link-extract":
      let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot.path))
      let subject = try service.createNote(
        bodyMarkdown: "# Project planning\n\nCoordinate launch milestones and planning risks."
      )
      _ = try service.createNote(
        bodyMarkdown: "# Launch milestones\n\nRelated project planning notes for the launch checklist."
      )
      return try noteExampleJSON([
        "noteRoot": .string(noteRoot.path),
        "workflowInput": .object([
          "noteId": .string(subject.noteId),
          "subjectBodyMarkdown": .string(subject.bodyMarkdown),
          "query": .string("project planning launch"),
          "limit": .number(10)
        ])
      ])
    default:
      return nil
    }
  }

  private func noteExampleJSON(_ object: JSONObject) throws -> String {
    let data = try JSONEncoder().encode(JSONValue.object(object))
    guard let string = String(data: data, encoding: .utf8) else {
      throw CLIUsageError("failed to encode test JSON")
    }
    return string
  }
}
