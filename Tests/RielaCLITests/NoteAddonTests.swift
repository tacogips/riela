import Foundation
import RielaCore
import RielaNote
import XCTest
@testable import RielaCLI

// swiftlint:disable:next type_body_length
final class NoteAddonTests: XCTestCase {
  func testGraphNeighborsAndSearchGraphInputsUseSharedNoteService() async throws {
    let noteRoot = try makeNoteAddonRoot()
    defer {
      try? FileManager.default.removeItem(atPath: noteRoot)
    }
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot))
    let seed = try service.createNote(bodyMarkdown: "# Seed\nprojectalpha")
    let neighbor = try service.createNote(bodyMarkdown: "# Neighbor\nx")
    _ = try service.linkNotes(from: seed.noteId, to: neighbor.noteId)
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": noteRoot])

    let graph = try await resolver.execute(
      noteInput(
        name: "riela/note-graph-neighbors",
        config: [
          "noteIds": .array([.string(seed.noteId)]),
          "depth": .number(1),
          "limit": .number(10)
        ]
      ),
      context: AdapterExecutionContext()
    )
    XCTAssertEqual(try arrayValue(graph.payload["noteIds"], field: "noteIds"), [.string(neighbor.noteId)])
    let graphResult = try objectValue(
      try XCTUnwrap(try arrayValue(graph.payload["results"], field: "results").first)
    )
    XCTAssertEqual(graphResult["edgeKind"], .string("explicit-link"))
    XCTAssertEqual(graphResult["hopCount"], .number(1))
    XCTAssertEqual(graphResult["pathNoteIds"], .array([.string(seed.noteId), .string(neighbor.noteId)]))

    let search = try await resolver.execute(
      noteInput(
        name: "riela/note-search",
        config: [
          "query": .string("projectalpha"),
          "includeLinked": .bool(true),
          "depth": .number(1),
          "limit": .number(10)
        ]
      ),
      context: AdapterExecutionContext()
    )
    XCTAssertEqual(
      try arrayValue(search.payload["noteIds"], field: "noteIds"),
      [.string(seed.noteId), .string(neighbor.noteId)]
    )
  }

  func testGraphNeighborsRejectsMalformedNoteIdsAndNegativeBounds() async throws {
    let noteRoot = try makeNoteAddonRoot()
    defer {
      try? FileManager.default.removeItem(atPath: noteRoot)
    }
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": noteRoot])

    do {
      _ = try await resolver.execute(
        noteInput(name: "riela/note-graph-neighbors", config: ["noteIds": .number(1)]),
        context: AdapterExecutionContext()
      )
      XCTFail("expected malformed noteIds to fail")
    } catch {
      XCTAssertTrue(String(describing: error).contains("noteIds"))
    }

    do {
      _ = try await resolver.execute(
        noteInput(
          name: "riela/note-graph-neighbors",
          config: ["noteIds": .array([]), "depth": .number(-1)]
        ),
        context: AdapterExecutionContext()
      )
      XCTFail("expected negative depth to fail")
    } catch {
      XCTAssertTrue(String(describing: error).contains("depth"))
    }
  }

  func testGraphNeighborSeedClampNoteIdPrecedenceAndBatchGetCap() async throws {
    let noteRoot = try makeNoteAddonRoot()
    defer {
      try? FileManager.default.removeItem(atPath: noteRoot)
    }
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot))
    var noteIds: [JSONValue] = []
    for index in 0..<(NoteGraphPolicy.maximumSeedCount + 5) {
      let note = try service.createNote(bodyMarkdown: "# Note \(index)\nbody")
      noteIds.append(.string(note.noteId))
    }
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": noteRoot])

    // More seeds than the service's 20-seed cap must clamp, not throw.
    let graph = try await resolver.execute(
      noteInput(name: "riela/note-graph-neighbors", config: ["noteIds": .array(noteIds)]),
      context: AdapterExecutionContext()
    )
    XCTAssertEqual(
      try arrayValue(graph.payload["seedNoteIds"], field: "seedNoteIds").count,
      NoteGraphPolicy.maximumSeedCount
    )

    // An explicit noteId keeps the single-note shape even when a forwarded
    // payload also carries a noteIds array.
    let single = try await resolver.execute(
      noteInput(
        name: "riela/note-get",
        config: ["noteId": noteIds[0], "noteIds": .array(Array(noteIds.prefix(3)))]
      ),
      context: AdapterExecutionContext()
    )
    XCTAssertEqual(single.payload["noteId"], noteIds[0])
    XCTAssertNotNil(single.payload["note"])
    XCTAssertNil(single.payload["notes"])

    // Batch fetch dedupes and caps caller-supplied ids.
    let duplicated = noteIds + noteIds
    let batch = try await resolver.execute(
      noteInput(name: "riela/note-get", config: ["noteIds": .array(duplicated)]),
      context: AdapterExecutionContext()
    )
    XCTAssertEqual(
      try arrayValue(batch.payload["notes"], field: "notes").count,
      NoteGraphPolicy.maximumSeedCount
    )
  }

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
    let firstTasks = try arrayValue(first.payload["tasks"], field: "tasks").map(objectValue)
    XCTAssertEqual(firstTasks.count, 2)
    XCTAssertEqual(firstTasks.map { $0["taskKey"] }, [.string("first-card"), .string("second-card")])
    XCTAssertEqual(firstTasks.map { $0["progress"] }, [.string("pending"), .string("pending")])
    XCTAssertEqual(firstTasks.map { $0["reused"] }, [.bool(false), .bool(false)])
    let firstNotebookIds = try firstTasks.map { try stringValue($0["notebookId"], field: "notebookId") }

    let second = try await resolver.execute(
      noteInput(name: "riela/note-kanban-task-create", config: config),
      context: AdapterExecutionContext()
    )
    let secondTasks = try arrayValue(second.payload["tasks"], field: "tasks").map(objectValue)
    XCTAssertEqual(secondTasks.map { $0["reused"] }, [.bool(true), .bool(true)])
    XCTAssertEqual(
      try secondTasks.map { try stringValue($0["notebookId"], field: "notebookId") },
      firstNotebookIds
    )

    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot))
    let folderTag = try service.listTags().first { $0.name == "demo-run" }
    XCTAssertEqual(try XCTUnwrap(folderTag).classId, "folder")
    let parentTag = try service.listTags().first { $0.name == "orchestrations" }
    XCTAssertEqual(try XCTUnwrap(folderTag).parentTagId, try XCTUnwrap(parentTag).tagId)
    XCTAssertEqual(try service.listNotebooks(tagFilter: ["demo-run"]).count, 2)
  }

  func testKanbanMoveReportsConflictAsBranchLocalOutcome() async throws {
    let noteRoot = try makeNoteAddonRoot()
    defer {
      try? FileManager.default.removeItem(atPath: noteRoot)
    }
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot))
    let notebook = try service.createNotebook(title: "Card")
    _ = try service.setNotebookProgress(notebookId: notebook.notebookId, progress: "pending")
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": noteRoot])

    let claimed = try await resolver.execute(
      noteInput(name: "riela/note-kanban-move", config: [
        "notebookId": .string(notebook.notebookId),
        "to": .string("progress"),
        "expectedFrom": .string("pending")
      ]),
      context: AdapterExecutionContext()
    )
    XCTAssertEqual(claimed.payload["conflict"], .bool(false))
    XCTAssertEqual(claimed.payload["progress"], .string("progress"))
    XCTAssertEqual(claimed.payload["previousProgress"], .string("pending"))

    let conflicted = try await resolver.execute(
      noteInput(name: "riela/note-kanban-move", config: [
        "notebookId": .string(notebook.notebookId),
        "to": .string("progress"),
        "expectedFrom": .string("pending")
      ]),
      context: AdapterExecutionContext()
    )
    XCTAssertEqual(conflicted.payload["conflict"], .bool(true))
    XCTAssertEqual(conflicted.payload["progress"], .string("progress"))
    XCTAssertEqual(conflicted.payload["expectedProgress"], .string("pending"))
    XCTAssertEqual(try service.getNotebook(notebook.notebookId).progress, "progress")

    do {
      _ = try await resolver.execute(
        noteInput(name: "riela/note-kanban-move", config: [
          "notebookId": .string(notebook.notebookId),
          "to": .string("not-a-status")
        ]),
        context: AdapterExecutionContext()
      )
      XCTFail("expected an invalid status name to fail")
    } catch {
      XCTAssertTrue(String(describing: error).contains("unsupported notebook progress"))
    }
  }

  func testKanbanBoardGroupsNotebooksIntoEffectiveColumns() async throws {
    let noteRoot = try makeNoteAddonRoot()
    defer {
      try? FileManager.default.removeItem(atPath: noteRoot)
    }
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot))
    _ = try service.defineTag(name: "board-folder", classId: "folder")
    let reviewing = try service.createNotebook(title: "Reviewing")
    _ = try service.applyNotebookTags(notebookId: reviewing.notebookId, tags: ["board-folder"], provenance: .ai)
    _ = try service.setNotebookProgress(notebookId: reviewing.notebookId, progress: "review")
    let idle = try service.createNotebook(title: "Idle")
    _ = try service.applyNotebookTags(notebookId: idle.notebookId, tags: ["board-folder"], provenance: .ai)
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": noteRoot])

    let board = try await resolver.execute(
      noteInput(name: "riela/note-kanban-board", config: ["tagName": .string("board-folder")]),
      context: AdapterExecutionContext()
    )
    XCTAssertEqual(board.payload["tagName"], .string("board-folder"))
    let columns = try arrayValue(board.payload["columns"], field: "columns").map(objectValue)
    XCTAssertEqual(columns.count, 5)
    let statusNames = try columns.map { column -> String in
      let status = try objectValue(column["status"])
      return try stringValue(status["name"], field: "status.name")
    }
    XCTAssertEqual(statusNames, ["none", "pending", "progress", "review", "done"])
    let notebooksByColumn = try columns.map { column in
      try arrayValue(column["notebooks"], field: "notebooks").map(objectValue)
    }
    XCTAssertEqual(notebooksByColumn[0].first?["notebookId"], .string(idle.notebookId))
    XCTAssertEqual(notebooksByColumn[3].first?["notebookId"], .string(reviewing.notebookId))
  }

  func testNoteMemorySuccessorsSaveUpdateLoadAndSearchLockedSystemNotebook() async throws {
    let noteRoot = try makeNoteAddonRoot()
    defer { try? FileManager.default.removeItem(atPath: noteRoot) }
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": noteRoot])
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot))
    let related = try service.createNote(bodyMarkdown: "# Related\ncontext")

    let saved = try await resolver.execute(
      noteInput(
        name: "riela/note-memory-save",
        config: [
          "bodyMarkdown": .string("# Durable fact\nalpha memory"),
          "memoryNamespace": .string("chat"),
          "tags": .array([.string("topic:alpha")]),
          "relatedNoteIds": .array([.string(related.noteId)]),
          "attachments": .array([.string("source")])
        ],
        attachments: [
          "source": WorkflowAddonAttachmentValue(
            id: "source",
            mediaType: "text/plain",
            filename: "source.txt",
            sizeBytes: 11,
            sha256: "sha256:unused-by-resolver",
            contentText: "hello memory"
          )
        ]
      ),
      context: AdapterExecutionContext()
    )
    let noteId = try stringValue(saved.payload["noteId"], field: "noteId")
    XCTAssertTrue(try service.systemMemoryNotebook().readOnly)
    XCTAssertEqual(try service.listLinks(noteId: noteId).map(\.toNoteId), [related.noteId])
    XCTAssertEqual(try service.listFiles(noteId: noteId).map(\.file.originalFilename), ["source.txt"])

    let updated = try await resolver.execute(
      noteInput(
        name: "riela/note-memory-update",
        config: ["noteId": .string(noteId), "bodyMarkdown": .string("# Durable fact\nbeta memory")]
      ),
      context: AdapterExecutionContext()
    )
    XCTAssertEqual(updated.payload["operation"], .string("update"))

    let loaded = try await resolver.execute(
      noteInput(name: "riela/note-memory-load", config: ["noteId": .string(noteId)]),
      context: AdapterExecutionContext()
    )
    let loadedNote = try objectValue(loaded.payload["note"])
    XCTAssertEqual(loadedNote["bodyMarkdown"], .string("# Durable fact\nbeta memory"))

    let searched = try await resolver.execute(
      noteInput(name: "riela/note-memory-search", config: ["query": .string("beta memory")]),
      context: AdapterExecutionContext()
    )
    XCTAssertEqual(searched.payload["noteIds"], .array([.string(noteId)]))
  }

  func testPersonaMemorySuccessorsPreserveReplyAndHandoffFlags() async throws {
    let noteRoot = try makeNoteAddonRoot()
    defer { try? FileManager.default.removeItem(atPath: noteRoot) }
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": noteRoot])
    let payload: JSONObject = [
      "replyText": .string("I will remember."),
      "handoff_mika": .bool(true),
      "memoryEntries": .array([.object([
        "kind": .string("user-instruction"),
        "importance": .string("high"),
        "content": .string("Prefer concise replies")
      ]), .object([
        "kind": .string("observation"),
        "importance": .string("normal"),
        "content": .string("Uses image references")
      ])])
    ]

    let written = try await resolver.execute(
      noteInput(
        name: "riela/note-persona-memory-write",
        config: ["personaId": .string("yui")],
        variables: payload,
        attachments: [
          "chat-image": WorkflowAddonAttachmentValue(
            id: "chat-image",
            mediaType: "image/png",
            filename: "chat-image.png",
            sizeBytes: 7,
            sha256: "sha256:unused-by-resolver",
            contentText: "pngdata"
          )
        ]
      ),
      context: AdapterExecutionContext()
    )
    XCTAssertEqual(written.payload["replyText"], .string("I will remember."))
    XCTAssertEqual(written.when["handoff_mika"], true)
    let writtenMemory = try objectValue(written.payload["memory"])
    XCTAssertEqual(try arrayValue(writtenMemory["fileIds"], field: "memory.fileIds").count, 2)
    let noteIds = try arrayValue(writtenMemory["noteIds"], field: "memory.noteIds")
      .compactMap { value -> String? in
        guard case let .string(noteId) = value else { return nil }
        return noteId
      }
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot))
    XCTAssertEqual(try noteIds.map { try service.listFiles(noteId: $0).count }, [1, 1])

    let read = try await resolver.execute(
      noteInput(
        name: "riela/note-persona-memory-read",
        config: ["personaId": .string("yui"), "fileLimit": .integer(1)]
      ),
      context: AdapterExecutionContext()
    )
    XCTAssertEqual(read.payload["memoryRecordCount"], .number(2))
    XCTAssertTrue(try stringValue(read.payload["memoryMarkdown"], field: "memoryMarkdown").contains("concise replies"))
    let files = try arrayValue(read.payload["files"], field: "files").map(objectValue)
    XCTAssertEqual(files.count, 1)
    let file = try objectValue(files[0]["file"])
    XCTAssertEqual(file["originalFilename"], .string("chat-image.png"))
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
