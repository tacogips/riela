import Foundation
import RielaCore
import RielaNote
import XCTest
@testable import RielaCLI

final class NoteAddonTests: XCTestCase {
  func testNoteCreateTagCommentGetAndSearchReturnFlattenedPayload() async throws {
    let noteRoot = try makeNoteAddonRoot()
    defer {
      try? FileManager.default.removeItem(atPath: noteRoot)
    }
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": noteRoot])

    let create = try await resolver.execute(
      noteInput(
        name: "riela/note-create",
        config: [
          "bodyMarkdown": .string("# Alpha Brief\n\nSearchable note content."),
          "tags": .array([.object(["name": .string("research"), "classId": .string("topic")])]),
          "assignedBy": .string("note-addon-test")
        ]
      ),
      context: AdapterExecutionContext()
    )
    let noteId = try stringValue(create.payload["noteId"], field: "noteId")
    XCTAssertEqual(create.payload["noteRoot"], .string(noteRoot))
    XCTAssertNil(create.payload["candidatePayload"])
    XCTAssertEqual(create.payload["noteId"], .string(noteId))

    let tagged = try await resolver.execute(
      noteInput(
        name: "riela/note-tag-apply",
        config: [
          "noteId": .string(noteId),
          "tags": .array([.string("reviewed")]),
          "provenance": .string("ai")
        ]
      ),
      context: AdapterExecutionContext()
    )
    XCTAssertEqual(tagged.payload["noteId"], .string(noteId))

    let comment = try await resolver.execute(
      noteInput(
        name: "riela/note-comment-add",
        config: [
          "noteId": .string(noteId),
          "bodyMarkdown": .string("Looks ready."),
          "author": .string("tester")
        ]
      ),
      context: AdapterExecutionContext()
    )
    XCTAssertNotNil(try? stringValue(comment.payload["commentId"], field: "commentId"))

    let fetched = try await resolver.execute(
      noteInput(name: "riela/note-get", config: ["noteId": .string(noteId)]),
      context: AdapterExecutionContext()
    )
    XCTAssertEqual(try arrayValue(fetched.payload["comments"], field: "comments").count, 1)

    let search = try await resolver.execute(
      noteInput(
        name: "riela/note-search",
        config: [
          "query": .string("Alpha"),
          "tagFilter": .array([.string("research")])
        ]
      ),
      context: AdapterExecutionContext()
    )
    XCTAssertEqual(try arrayValue(search.payload["noteIds"], field: "noteIds"), [.string(noteId)])
  }

  func testNoteCreateFallbackTitleOnlyStripsLeadingMarkdownHeadingMarkers() async throws {
    let noteRoot = try makeNoteAddonRoot()
    defer {
      try? FileManager.default.removeItem(atPath: noteRoot)
    }
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": noteRoot])

    let chapter = try await resolver.execute(
      noteInput(
        name: "riela/note-create",
        config: [
          "bodyMarkdown": .string("Chapter # 1\n\nBody."),
          "notebookKindTag": .string("notebook-kind:addon-title-test")
        ]
      ),
      context: AdapterExecutionContext()
    )
    let heading = try await resolver.execute(
      noteInput(
        name: "riela/note-create",
        config: [
          "bodyMarkdown": .string("## Markdown Heading\n\nBody."),
          "notebookKindTag": .string("notebook-kind:addon-title-test")
        ]
      ),
      context: AdapterExecutionContext()
    )

    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot))
    let chapterNotebook = try service.getNotebook(
      try stringValue(chapter.payload["notebookId"], field: "chapter notebookId")
    )
    let headingNotebook = try service.getNotebook(
      try stringValue(heading.payload["notebookId"], field: "heading notebookId")
    )

    XCTAssertEqual(chapterNotebook.title, "Chapter # 1")
    XCTAssertEqual(headingNotebook.title, "Markdown Heading")
  }

  func testNoteAddonValidationFailureUsesInvalidInputCode() async throws {
    let noteRoot = try makeNoteAddonRoot()
    defer {
      try? FileManager.default.removeItem(atPath: noteRoot)
    }
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": noteRoot])

    do {
      _ = try await resolver.execute(
        noteInput(name: "riela/note-create", config: [:]),
        context: AdapterExecutionContext()
      )
      XCTFail("expected validation failure")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .invalidInput)
      XCTAssertTrue(error.message.contains("bodyMarkdown is required"), error.message)
    }
  }

  func testNoteAddonRejectsOversizedAndOutOfRootFileInputs() async throws {
    let noteRoot = try makeNoteAddonRoot()
    defer {
      try? FileManager.default.removeItem(atPath: noteRoot)
    }
    let outsideDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("RielaNoteAddonOutside", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: outsideDirectory)
    }
    let outsideFile = outsideDirectory.appendingPathComponent("secret.txt")
    try "secret".write(to: outsideFile, atomically: true, encoding: .utf8)

    let resolver = BuiltinWorkflowAddonResolver(environment: [:])
    let create = try await resolver.execute(
      noteInput(
        name: "riela/note-create",
        config: [
          "noteRoot": .string(noteRoot),
          "bodyMarkdown": .string("# Attachment Target\n\nBody")
        ]
      ),
      context: AdapterExecutionContext()
    )
    let noteId = try stringValue(create.payload["noteId"], field: "noteId")

    do {
      _ = try await resolver.execute(
        noteInput(
          name: "riela/note-attach-file",
          config: [
            "noteRoot": .string(noteRoot),
            "noteId": .string(noteId),
            "filePath": .string(outsideFile.path)
          ]
        ),
        context: AdapterExecutionContext()
      )
      XCTFail("expected out-of-root file rejection")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .invalidInput)
      XCTAssertTrue(error.message.contains("outside allowed root"), error.message)
    }

    do {
      _ = try await resolver.execute(
        noteInput(
          name: "riela/note-attach-file",
          config: [
            "noteRoot": .string(noteRoot),
            "noteId": .string(noteId),
            "contentText": .string("12345"),
            "maxAttachmentBytes": .number(4)
          ]
        ),
        context: AdapterExecutionContext()
      )
      XCTFail("expected oversized attachment rejection")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .invalidInput)
      XCTAssertTrue(error.message.contains("max 4"), error.message)
    }
  }

  func testNotebookIngestPagesRejectsPageCountLimit() async throws {
    let noteRoot = try makeNoteAddonRoot()
    defer {
      try? FileManager.default.removeItem(atPath: noteRoot)
    }
    let resolver = BuiltinWorkflowAddonResolver(environment: [:])

    do {
      _ = try await resolver.execute(
        noteInput(
          name: "riela/notebook-ingest-pages",
          config: [
            "noteRoot": .string(noteRoot),
            "maxPageCount": .number(1),
            "pages": .array([
              .object(["bodyMarkdown": .string("Page one")]),
              .object(["bodyMarkdown": .string("Page two")])
            ])
          ]
        ),
        context: AdapterExecutionContext()
      )
      XCTFail("expected page count rejection")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .invalidInput)
      XCTAssertTrue(error.message.contains("max 1"), error.message)
    }
  }

  func testNoteAttachFileAndNotebookIngestPages() async throws {
    let noteRoot = try makeNoteAddonRoot()
    defer {
      try? FileManager.default.removeItem(atPath: noteRoot)
    }
    let resolver = BuiltinWorkflowAddonResolver(environment: [:])
    let create = try await resolver.execute(
      noteInput(
        name: "riela/note-create",
        config: [
          "noteRoot": .string(noteRoot),
          "bodyMarkdown": .string("# Attachment Target\n\nBody")
        ]
      ),
      context: AdapterExecutionContext()
    )
    let noteId = try stringValue(create.payload["noteId"], field: "noteId")

    let attach = try await resolver.execute(
      noteInput(
        name: "riela/note-attach-file",
        config: [
          "noteRoot": .string(noteRoot),
          "noteId": .string(noteId),
          "attachmentField": .string("source"),
          "role": .string("source-page-image")
        ],
        attachments: [
          "source": WorkflowAddonAttachmentValue(
            id: "source",
            mediaType: "text/plain",
            filename: "source.txt",
            sizeBytes: 11,
            sha256: "sha256:unused-by-resolver",
            contentText: "hello notes"
          )
        ]
      ),
      context: AdapterExecutionContext()
    )
    let file = try objectValue(objectValue(attach.payload["file"])["file"])
    XCTAssertEqual(file["mediaType"], .string("text/plain"))
    let storedPath = URL(fileURLWithPath: noteRoot, isDirectory: true)
      .appendingPathComponent("files", isDirectory: true)
      .appendingPathComponent(try stringValue(file["localPath"], field: "localPath"))
      .path
    XCTAssertTrue(FileManager.default.fileExists(atPath: storedPath))

    let sourcePDF = URL(fileURLWithPath: noteRoot, isDirectory: true).appendingPathComponent("source.pdf")
    try Data("%PDF-1.4 test".utf8).write(to: sourcePDF)
    let localPageImage = URL(fileURLWithPath: noteRoot, isDirectory: true).appendingPathComponent("page-local.png")
    try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x01]).write(to: localPageImage)
    let pageImageData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
    let ingest = try await resolver.execute(
      noteInput(
        name: "riela/notebook-ingest-pages",
        config: [
          "noteRoot": .string(noteRoot),
          "title": .string("Imported Packet"),
          "sourceDocumentRef": .string(sourcePDF.path),
          "pages": .array([
            .object([
              "number": .number(10),
              "title": .string("Page One"),
              "bodyMarkdown": .string("First imported page"),
              "pageImageRef": .string(localPageImage.path)
            ]),
            .object([
              "title": .string("Page Two"),
              "bodyMarkdown": .string("Second imported page"),
              "pageImageRef": .string("page-two-image")
            ])
          ])
        ],
        attachments: [
          "page-two-image": WorkflowAddonAttachmentValue(
            id: "page-two-image",
            mediaType: "image/png",
            filename: "page-002.png",
            sizeBytes: pageImageData.count,
            sha256: "sha256:unused-by-resolver",
            contentBase64: pageImageData.base64EncodedString()
          )
        ]
      ),
      context: AdapterExecutionContext()
    )
    XCTAssertEqual(ingest.payload["pageCount"], .number(2))
    XCTAssertEqual(try arrayValue(ingest.payload["noteIds"], field: "noteIds").count, 2)
    let notebook = try objectValue(ingest.payload["notebook"])
    XCTAssertEqual(try stringValue(notebook["metaJSON"], field: "notebook.metaJSON"), "{\"sourceDocumentRef\":\"\(sourcePDF.path)\"}")

    let sourceDocument = try objectValue(ingest.payload["sourceDocument"])
    XCTAssertEqual(sourceDocument["role"], .string("source-document"))
    let sourceFile = try objectValue(sourceDocument["file"])
    XCTAssertEqual(sourceFile["mediaType"], .string("application/pdf"))
    XCTAssertEqual(sourceFile["originalFilename"], .string("source.pdf"))

    let pageImages = try arrayValue(ingest.payload["pageImages"], field: "pageImages")
    XCTAssertEqual(pageImages.count, 2)
    let pageImage = try objectValue(pageImages[0])
    XCTAssertEqual(pageImage["role"], .string("source-page-image"))
    XCTAssertEqual(pageImage["position"], .number(10))
    let pageImageFile = try objectValue(pageImage["file"])
    XCTAssertEqual(pageImageFile["mediaType"], .string("image/png"))
    XCTAssertEqual(pageImageFile["originalFilename"], .string("page-local.png"))
    let inlinePageImage = try objectValue(pageImages[1])
    XCTAssertEqual(inlinePageImage["role"], .string("source-page-image"))
    XCTAssertEqual(inlinePageImage["position"], .number(2))
    let inlinePageImageFile = try objectValue(inlinePageImage["file"])
    XCTAssertEqual(inlinePageImageFile["mediaType"], .string("image/png"))
    XCTAssertEqual(inlinePageImageFile["originalFilename"], .string("page-002.png"))

    let firstNote = try objectValue(try arrayValue(ingest.payload["notes"], field: "notes").first)
    XCTAssertEqual(firstNote["noteNumber"], .number(10))
    let metaJSON = try stringValue(firstNote["metaJSON"], field: "first note metaJSON")
    XCTAssertTrue(metaJSON.contains(#""number":10"#), metaJSON)
    XCTAssertTrue(metaJSON.contains(#""pageImageRef":"\#(localPageImage.path)""#), metaJSON)
  }

  func testNoteSearchCoercesRenderedNumericLimit() async throws {
    let noteRoot = try makeNoteAddonRoot()
    defer {
      try? FileManager.default.removeItem(atPath: noteRoot)
    }
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": noteRoot])
    for index in 1...2 {
      _ = try await resolver.execute(
        noteInput(
          name: "riela/note-create",
          config: [
            "bodyMarkdown": .string("# Alpha \(index)\n\nShared searchable body.")
          ]
        ),
        context: AdapterExecutionContext()
      )
    }

    let search = try await resolver.execute(
      noteInput(
        name: "riela/note-search",
        config: [
          "query": .string("Shared"),
          "limit": .string("{{workflowInput.limit}}")
        ],
        variables: [
          "workflowInput": .object(["limit": .number(1)])
        ]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(search.payload["resultCount"], .number(1))
    XCTAssertEqual(try arrayValue(search.payload["noteIds"], field: "noteIds").count, 1)
  }

  func testNoteGraphQLDocumentAddonExecutesMutationPayload() async throws {
    let noteRoot = try makeNoteAddonRoot()
    defer {
      try? FileManager.default.removeItem(atPath: noteRoot)
    }
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": noteRoot])

    let output = try await resolver.execute(
      noteInput(
        name: "riela/note-graphql-document",
        config: [
          "query": .string("""
          mutation DefineClass($input: DefineNoteTagClassInput!) {
            defineNoteTagClass(input: $input) { result { accepted status } tagClass { classId label } }
          }
          """),
          "variables": .object([
            "input": .object([
              "classId": .string("business-idea"),
              "label": .string("Business Idea"),
              "description": .string("Opportunity notes")
            ])
          ]),
          "operationName": .string("DefineClass")
        ]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.payload["fieldName"], .string("defineNoteTagClass"))
    let result = try objectValue(output.payload["result"])
    XCTAssertEqual(result["accepted"], .bool(true))
    let tagClass = try objectValue(output.payload["tagClass"])
    XCTAssertEqual(tagClass["classId"], .string("business-idea"))
  }

  func testNoteGraphQLDocumentAddonPreservesTemplatedBooleanVariables() async throws {
    let noteRoot = try makeNoteAddonRoot()
    defer {
      try? FileManager.default.removeItem(atPath: noteRoot)
    }
    let workflowRoot = URL(fileURLWithPath: noteRoot, isDirectory: true)
      .appendingPathComponent("workflows", isDirectory: true)
      .path
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": noteRoot])

    let output = try await resolver.execute(
      noteInput(
        name: "riela/note-graphql-document",
        config: [
          "query": .string("""
          mutation Scaffold($input: ScaffoldNoteIngestionWorkflowInput!) {
            scaffoldNoteIngestionWorkflow(input: $input) {
              result { accepted status }
              workflowScaffold { workflowPath }
            }
          }
          """),
          "variables": .object([
            "input": .object([
              "workflowRoot": .string(workflowRoot),
              "workflowId": .string("note-ingest-templated-translation"),
              "translationEnabled": .string("{{workflowInput.translationEnabled}}")
            ])
          ]),
          "operationName": .string("Scaffold")
        ],
        variables: [
          "workflowInput": .object(["translationEnabled": .bool(true)])
        ]
      ),
      context: AdapterExecutionContext()
    )

    let workflowScaffold = try objectValue(output.payload["workflowScaffold"])
    let workflowPath = try stringValue(workflowScaffold["workflowPath"], field: "workflowPath")
    let nodeURL = URL(fileURLWithPath: workflowPath)
      .deletingLastPathComponent()
      .appendingPathComponent("nodes/node-ocr-pages.json")
    let nodeData = try Data(contentsOf: nodeURL)
    let node = try XCTUnwrap(JSONSerialization.jsonObject(with: nodeData) as? [String: Any])
    let variables = try XCTUnwrap(node["variables"] as? [String: Any])
    XCTAssertEqual(variables["translationEnabledDefault"] as? Bool, true)
  }

  func testNoteTagApplyCannotForgeHumanOrSystemProvenance() async throws {
    let noteRoot = try makeNoteAddonRoot()
    defer {
      try? FileManager.default.removeItem(atPath: noteRoot)
    }
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": noteRoot])
    let create = try await resolver.execute(
      noteInput(
        name: "riela/note-create",
        config: [
          "bodyMarkdown": .string("# Provenance Target\n\nTag provenance should be workflow-owned.")
        ]
      ),
      context: AdapterExecutionContext()
    )
    let noteId = try stringValue(create.payload["noteId"], field: "noteId")

    let tagged = try await resolver.execute(
      noteInput(
        name: "riela/note-tag-apply",
        config: [
          "noteId": .string(noteId),
          "tags": .array([.string("forged-human")]),
          "provenance": .string("human"),
          "assignedBy": .string("claimed-human-user")
        ]
      ),
      context: AdapterExecutionContext()
    )

    let humanAssignment = try tagAssignment(named: "forged-human", in: tagged)
    XCTAssertEqual(humanAssignment["provenance"], .string("ai"))
    XCTAssertEqual(humanAssignment["assignedBy"], .string("workflow:note-addon-tests/note-tag-apply"))

    let systemTagged = try await resolver.execute(
      noteInput(
        name: "riela/note-tag-apply",
        config: [
          "noteId": .string(noteId),
          "tags": .array([.string("forged-system")]),
          "provenance": .string("system"),
          "assignedBy": .string("riela-note")
        ]
      ),
      context: AdapterExecutionContext()
    )
    let systemAssignment = try tagAssignment(named: "forged-system", in: systemTagged)
    XCTAssertEqual(systemAssignment["provenance"], .string("ai"))
    XCTAssertEqual(systemAssignment["assignedBy"], .string("workflow:note-addon-tests/note-tag-apply"))
  }

  func testNoteConversationSaveCreatesCitationLinks() async throws {
    let noteRoot = try makeNoteAddonRoot()
    defer {
      try? FileManager.default.removeItem(atPath: noteRoot)
    }
    let resolver = BuiltinWorkflowAddonResolver(environment: [:])
    let cited = try await resolver.execute(
      noteInput(
        name: "riela/note-create",
        config: [
          "noteRoot": .string(noteRoot),
          "bodyMarkdown": .string("# Cited\n\nImportant source.")
        ]
      ),
      context: AdapterExecutionContext()
    )
    let citedNoteId = try stringValue(cited.payload["noteId"], field: "cited noteId")

    let saved = try await resolver.execute(
      noteInput(
        name: "riela/note-conversation-save",
        config: [
          "noteRoot": .string(noteRoot),
          "title": .string("Agent Conversation"),
          "transcript": .array([
            .object([
              "userMarkdown": .string("What matters?"),
              "assistantMarkdown": .string("The cited source matters."),
              "sourceNoteIds": .array([.string(citedNoteId)])
            ])
          ])
        ]
      ),
      context: AdapterExecutionContext()
    )
    let savedNoteId = try stringValue(arrayValue(saved.payload["noteIds"], field: "noteIds").first, field: "saved noteId")
    let fetched = try await resolver.execute(
      noteInput(
        name: "riela/note-get",
        config: [
          "noteRoot": .string(noteRoot),
          "noteId": .string(savedNoteId)
        ]
      ),
      context: AdapterExecutionContext()
    )
    let links = try arrayValue(fetched.payload["links"], field: "links")
    XCTAssertEqual(links.count, 1)
    XCTAssertEqual(try stringValue(objectValue(links[0])["toNoteId"], field: "toNoteId"), citedNoteId)
    XCTAssertEqual(try stringValue(objectValue(links[0])["linkKind"], field: "linkKind"), "source-citation")
  }

  private func noteInput(
    name: String,
    config: JSONObject,
    variables: JSONObject = [:],
    attachments: [String: WorkflowAddonAttachmentValue] = [:]
  ) -> WorkflowAddonExecutionInput {
    WorkflowAddonExecutionInput(
      workflowId: "note-addon-tests",
      stepId: name.replacingOccurrences(of: "riela/", with: "").replacingOccurrences(of: "/", with: "-"),
      nodeId: name.replacingOccurrences(of: "riela/", with: "").replacingOccurrences(of: "/", with: "-"),
      addon: WorkflowNodeAddonRef(name: name, version: "1", config: config),
      variables: variables,
      attachments: attachments
    )
  }

  private func makeNoteAddonRoot(function: String = #function) throws -> String {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/RielaCLITests", isDirectory: true)
      .appendingPathComponent("NoteAddonTests", isDirectory: true)
      .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.path
  }

  private func objectValue(_ value: JSONValue?) throws -> JSONObject {
    guard case let .object(object)? = value else {
      throw XCTSkip("expected object")
    }
    return object
  }

  private func arrayValue(_ value: JSONValue?, field: String) throws -> [JSONValue] {
    guard case let .array(values)? = value else {
      XCTFail("expected \(field) array")
      return []
    }
    return values
  }

  private func stringValue(_ value: JSONValue?, field: String) throws -> String {
    guard case let .string(string)? = value else {
      XCTFail("expected \(field) string")
      return ""
    }
    return string
  }

  private func tagAssignment(named tagName: String, in output: AdapterExecutionOutput) throws -> JSONObject {
    let tags = try arrayValue(output.payload["tags"], field: "tags")
    return try XCTUnwrap(tags.compactMap { value -> JSONObject? in
      guard let assignment = try? objectValue(value),
            let tag = try? objectValue(assignment["tag"]),
            (try? stringValue(tag["name"], field: "tag.name")) == tagName else {
        return nil
      }
      return assignment
    }.first)
  }
}
