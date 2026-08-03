import Foundation
import RielaCore
import RielaNote
import XCTest
@testable import RielaCLI

final class NotePersonaAddonTests: XCTestCase {
  func testSuccessorAddonsWriteAndReadSystemMemoryNotebook() async throws {
    let noteRoot = try makeNotePersonaAddonRoot()
    defer { try? FileManager.default.removeItem(atPath: noteRoot) }
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": noteRoot])
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot))
    let relatedNotebook = try service.createNotebook(title: "Related")
    let relatedNote = try service.createNote(
      notebookId: relatedNotebook.notebookId,
      bodyMarkdown: "Release source"
    )
    let payload: JSONObject = [
      "replyText": .string("Yui reply"),
      "handoff_mika": .bool(true),
      "noteEntries": .array([
        .object([
          "kind": .string("user-instruction"),
          "importance": .string("medium"),
          "source": .string("chat"),
          "content": .string("Prefer concise release notes"),
          "relatedNoteIds": .array([.string(relatedNote.noteId), .string("external-ticket-42")]),
          "attachments": .array([.string("avatar")])
        ])
      ])
    ]

    let write = try await resolver.execute(
      notePersonaInput(
        name: "riela/note-persona-context-write",
        config: ["personaId": .string("yui"), "personaName": .string("Yui Codex")],
        variables: ["payload": .object(payload)],
        attachments: [
          "avatar": WorkflowAddonAttachmentValue(
            id: "avatar",
            mediaType: "image/png",
            filename: "avatar.png",
            sizeBytes: 3,
            sha256: "fixture",
            contentBase64: Data([1, 2, 3]).base64EncodedString()
          )
        ]
      ),
      context: AdapterExecutionContext()
    )
    XCTAssertEqual(write.payload["entriesWritten"], .number(1))
    XCTAssertEqual(write.payload["attachmentsWritten"], .number(1))
    XCTAssertEqual(write.payload["replyText"], .string("Yui reply"))
    XCTAssertEqual(write.when["handoff_mika"], true)

    let read = try await resolver.execute(
      notePersonaInput(
        name: "riela/note-persona-context-read",
        config: ["personaId": .string("yui"), "personaName": .string("Yui Codex"), "limit": .number(3)]
      ),
      context: AdapterExecutionContext()
    )
    XCTAssertEqual(read.payload["noteCount"], .number(1))
    guard case let .array(imagePaths)? = read.payload["imagePaths"] else {
      return XCTFail("imagePaths is missing")
    }
    XCTAssertEqual(imagePaths.count, 1)
    guard case let .string(storedImagePath)? = imagePaths.first else {
      return XCTFail("imagePaths does not contain a materialized path")
    }
    let storedImageURL = URL(fileURLWithPath: storedImagePath)
    let expectedFilesRoot = URL(fileURLWithPath: noteRoot, isDirectory: true)
      .appendingPathComponent("files", isDirectory: true)
      .standardizedFileURL
    XCTAssertTrue(storedImageURL.isFileURL)
    XCTAssertTrue(storedImageURL.path.hasPrefix(expectedFilesRoot.path + "/"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: storedImageURL.path))
    XCTAssertEqual(try Data(contentsOf: storedImageURL), Data([1, 2, 3]))
    guard case let .array(filePaths)? = read.payload["filePaths"],
          case let .string(storedFilePath)? = filePaths.first else {
      return XCTFail("filePaths does not contain a materialized path")
    }
    XCTAssertEqual(storedFilePath, storedImagePath)
    guard case let .string(contextMarkdown)? = read.payload["contextMarkdown"] else {
      return XCTFail("contextMarkdown is missing")
    }
    XCTAssertTrue(contextMarkdown.contains("Prefer concise release notes"))

    XCTAssertTrue(try service.systemMemoryNotebook().readOnly)
    let stored = try XCTUnwrap(service.listSystemMemoryNotes(personaId: "yui", limit: 10).first)
    XCTAssertEqual(try service.listLinks(noteId: stored.noteId).first?.toNoteId, relatedNote.noteId)
    XCTAssertTrue(stored.metaJSON?.contains("external-ticket-42") == true)
  }

  func testPersonaReadsAreIsolatedAndBoundedInServiceOrder() async throws {
    let noteRoot = try makeNotePersonaAddonRoot()
    defer { try? FileManager.default.removeItem(atPath: noteRoot) }
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": noteRoot])
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot))

    for (personaId, contents) in [("yui", ["Yui older", "Yui newer"]), ("mika", ["Mika only"])] {
      _ = try await resolver.execute(
        notePersonaInput(
          name: "riela/note-persona-context-write",
          config: ["personaId": .string(personaId)],
          variables: ["payload": .object([
            "noteEntries": .array(contents.map { .object(["content": .string($0)]) })
          ])]
        ),
        context: AdapterExecutionContext()
      )
    }

    let serviceOrder = try service.listSystemMemoryNotes(personaId: "yui", limit: 10)
    XCTAssertEqual(serviceOrder.count, 2)
    let read = try await resolver.execute(
      notePersonaInput(
        name: "riela/note-persona-context-read",
        config: ["personaId": .string("yui"), "limit": .number(1)]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(read.payload["noteCount"], .number(1))
    guard case let .string(contextMarkdown)? = read.payload["contextMarkdown"] else {
      return XCTFail("contextMarkdown is missing")
    }
    XCTAssertTrue(contextMarkdown.contains(serviceOrder[0].bodyMarkdown))
    XCTAssertFalse(contextMarkdown.contains(serviceOrder[1].bodyMarkdown))
    XCTAssertFalse(contextMarkdown.contains("Mika only"))
  }

  func testPersonaReadRejectsTagOnlyWorkflowMemorySpoof() async throws {
    let noteRoot = try makeNotePersonaAddonRoot()
    defer { try? FileManager.default.removeItem(atPath: noteRoot) }
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": noteRoot])

    do {
      _ = try await resolver.execute(
        notePersonaInput(
          name: "riela/note-memory-save",
          config: [
            "streamId": .string("generic-stream"),
            "payload": .string("must not become persona context"),
            "tags": .array([.string("persona:yui")])
          ]
        ),
        context: AdapterExecutionContext()
      )
      XCTFail("Expected generic Note memory to reject reserved persona tags")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .invalidInput)
      XCTAssertTrue(error.message.contains("reserved prefix 'persona:'"), error.message)
    }

    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot))
    let notebook = try service.systemMemoryNotebook()
    _ = try service.setNotebookReadOnly(notebookId: notebook.notebookId, readOnly: false)
    _ = try service.createNote(
      notebookId: notebook.notebookId,
      bodyMarkdown: "must not become persona context",
      tags: [NoteTagInput(name: "persona:yui")],
      metaJSON: #"{"systemMemoryVersion":1,"entryKind":"workflow-memory","personaId":"mika"}"#
    )
    _ = try service.setNotebookReadOnly(notebookId: notebook.notebookId, readOnly: true)

    let read = try await resolver.execute(
      notePersonaInput(
        name: "riela/note-persona-context-read",
        config: ["personaId": .string("yui"), "limit": .number(10)]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(read.payload["noteCount"], .number(0))
    XCTAssertEqual(read.payload["contextMarkdown"], .string(""))
  }

  func testEmptyWriteAndLaterInvalidAttachmentLeaveNoPartialNotesOrFiles() async throws {
    let noteRoot = try makeNotePersonaAddonRoot()
    defer { try? FileManager.default.removeItem(atPath: noteRoot) }
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": noteRoot])
    let driver = SQLiteNoteDatabaseDriver(noteRoot: noteRoot)
    let service = try NoteService(driver: driver)
    let config: JSONObject = ["personaId": .string("yui")]

    let empty = try await resolver.execute(
      notePersonaInput(
        name: "riela/note-persona-context-write",
        config: config,
        variables: ["payload": .object(["noteEntries": .array([])])]
      ),
      context: AdapterExecutionContext()
    )
    XCTAssertEqual(empty.payload["entriesWritten"], .number(0))

    do {
      _ = try await resolver.execute(
        notePersonaInput(
          name: "riela/note-persona-context-write",
          config: config,
          variables: ["payload": .object([
            "noteEntries": .array([
              .object([
                "content": .string("valid entry must not be persisted"),
                "attachments": .array([.string("valid")])
              ]),
              .object([
                "content": .string("later invalid entry"),
                "attachments": .array([.string("missing")])
              ])
            ])
          ])],
          attachments: [
            "valid": WorkflowAddonAttachmentValue(
              id: "valid",
              mediaType: "image/png",
              filename: "valid.png",
              sizeBytes: 3,
              sha256: "fixture",
              contentBase64: Data([1, 2, 3]).base64EncodedString()
            )
          ]
        ),
        context: AdapterExecutionContext()
      )
      XCTFail("Expected unresolved attachment rejection")
    } catch {
      XCTAssertTrue(String(describing: error).contains("attachment cannot be resolved"))
    }
    XCTAssertTrue(try service.listSystemMemoryNotes(personaId: "yui", limit: 10).isEmpty)
    let fileRecordCount = try driver.withDatabase { database in
      try database.query("SELECT COUNT(*) AS count FROM files").first?["count"]
    }
    XCTAssertEqual(fileRecordCount, "0")
    let filesRoot = URL(fileURLWithPath: noteRoot, isDirectory: true)
      .appendingPathComponent("files", isDirectory: true)
    let storedFiles = FileManager.default.enumerator(
      at: filesRoot,
      includingPropertiesForKeys: [.isRegularFileKey]
    )?.compactMap { $0 as? URL }.filter { url in
      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    } ?? []
    XCTAssertTrue(storedFiles.isEmpty)
  }

  func testWriteRetryUsesWorkflowExecutionIdentityWithoutDuplicatingNotes() async throws {
    let noteRoot = try makeNotePersonaAddonRoot()
    defer { try? FileManager.default.removeItem(atPath: noteRoot) }
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": noteRoot])
    let variables: JSONObject = [
      "payload": .object([
        "noteEntries": .array([.object(["content": .string("Retry-safe context")])])
      ]),
      "_rielaInput": .object([
        "workflowExecutionId": .string("persona-session-1"),
        "sourceStepExecutionId": .string("generate-yui-context-exec-1")
      ])
    ]
    let input = notePersonaInput(
      name: "riela/note-persona-context-write",
      config: ["personaId": .string("yui")],
      variables: variables
    )

    let first = try await resolver.execute(input, context: AdapterExecutionContext())
    let retry = try await resolver.execute(input, context: AdapterExecutionContext())

    XCTAssertEqual(retry.payload["noteIds"], first.payload["noteIds"])
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot))
    XCTAssertEqual(try service.listSystemMemoryNotes(personaId: "yui", limit: 10).count, 1)
  }

  func testRelationPreflightPropagatesInvalidStoredNoteRows() async throws {
    let noteRoot = try makeNotePersonaAddonRoot()
    defer { try? FileManager.default.removeItem(atPath: noteRoot) }
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": noteRoot])
    let driver = SQLiteNoteDatabaseDriver(noteRoot: noteRoot)
    let service = try NoteService(driver: driver)
    let notebook = try service.createNotebook(title: "Corrupt relation fixture")
    let related = try service.createNote(
      notebookId: notebook.notebookId,
      bodyMarkdown: "Invalid row target"
    )
    try driver.withDatabase { database in
      try database.execute(
        "UPDATE notes SET note_number = 'not-an-integer' WHERE note_id = ?",
        bindings: [.text(related.noteId)]
      )
    }

    do {
      _ = try await resolver.execute(
        notePersonaInput(
          name: "riela/note-persona-context-write",
          config: ["personaId": .string("yui")],
          variables: ["payload": .object([
            "noteEntries": .array([
              .object([
                "content": .string("Must not be written"),
                "relatedNoteIds": .array([.string(related.noteId)])
              ])
            ])
          ])]
        ),
        context: AdapterExecutionContext()
      )
      XCTFail("Expected invalid stored relation row to propagate")
    } catch {
      XCTAssertTrue(String(describing: error).contains("invalidRow"))
    }
    XCTAssertTrue(try service.listSystemMemoryNotes(personaId: "yui", limit: 10).isEmpty)
  }

  func testRuntimeTrailBlocksVisitedHandoffAndRemovesContinuationSentence() async throws {
    let noteRoot = try makeNotePersonaAddonRoot()
    defer { try? FileManager.default.removeItem(atPath: noteRoot) }
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": noteRoot])

    let output = try await resolver.execute(
      notePersonaInput(
        name: "riela/note-persona-context-write",
        config: [
          "personaId": .string("rina"),
          "personaName": .string("Rina Cursor"),
          "teamPersonaIds": .array([.string("yui"), .string("mika"), .string("rina")])
        ],
        variables: [
          "payload": .object([
            "replyText": .string("結論。@Yui はどう見る？"),
            "handoff_yui": .bool(true),
            "noteEntries": .array([])
          ]),
          "runtime": .object([
            "executedStepIds": .array([
              .string("route-message"),
              .string("send-yui-reply"),
              .string("send-mika-reply")
            ])
          ])
        ]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.when["handoff_yui"], false)
    XCTAssertEqual(output.payload["replyText"], .string("結論。"))
    XCTAssertEqual(
      output.payload["handoffTrail"],
      .array([.string("yui"), .string("mika"), .string("rina")])
    )
    let guardPayload = try XCTUnwrap(jsonObject(output.payload["handoffGuard"]))
    XCTAssertEqual(guardPayload["blocked"], .bool(true))
    XCTAssertEqual(guardPayload["reason"], .string("target-persona-already-replied"))
    XCTAssertEqual(guardPayload["selectedTarget"], .string("yui"))
    XCTAssertEqual(
      guardPayload["visitedPersonas"],
      .array([.string("yui"), .string("mika")])
    )
  }

  func testUnvisitedHandoffRemainsEnabled() async throws {
    let noteRoot = try makeNotePersonaAddonRoot()
    defer { try? FileManager.default.removeItem(atPath: noteRoot) }
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": noteRoot])

    let output = try await resolver.execute(
      notePersonaInput(
        name: "riela/note-persona-context-write",
        config: [
          "personaId": .string("mika"),
          "personaName": .string("Mika Trend"),
          "teamPersonaIds": .array([.string("yui"), .string("mika"), .string("rina")])
        ],
        variables: [
          "payload": .object([
            "replyText": .string("いいじゃん。@Rina はどう？"),
            "handoff_rina": .bool(true),
            "noteEntries": .array([])
          ]),
          "upstream": .array([
            .object(["output": .object(["payload": .object([
              "replyAs": .string("yui"),
              "replyText": .string("Yui reply")
            ])])])
          ])
        ]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.when["handoff_rina"], true)
    XCTAssertEqual(output.payload["handoff_rina"], .bool(true))
    let guardPayload = try XCTUnwrap(jsonObject(output.payload["handoffGuard"]))
    XCTAssertEqual(guardPayload["blocked"], .bool(false))
    XCTAssertEqual(guardPayload["selectedTarget"], .string("rina"))
  }

  func testFinalTurnRemovesContinuationToVisitedPersonaWithoutRequestedHandoff() async throws {
    let noteRoot = try makeNotePersonaAddonRoot()
    defer { try? FileManager.default.removeItem(atPath: noteRoot) }
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": noteRoot])

    let output = try await resolver.execute(
      notePersonaInput(
        name: "riela/note-persona-context-write",
        config: [
          "personaId": .string("rina"),
          "personaName": .string("Rina Cursor"),
          "teamPersonaIds": .array([.string("yui"), .string("mika"), .string("rina")])
        ],
        variables: [
          "payload": .object([
            "replyText": .string("結論: 妥当。要点は3点。次はmikaの要点を受け取り、私の短評を返す。"),
            "handoff_mika": .bool(false),
            "handoff_yui": .bool(false),
            "noteEntries": .array([])
          ]),
          "runtime": .object([
            "executedStepIds": .array([
              .string("send-yui-reply"),
              .string("send-mika-reply")
            ])
          ])
        ]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.when["handoff_mika"], false)
    XCTAssertEqual(output.when["handoff_yui"], false)
    XCTAssertEqual(output.payload["replyText"], .string("結論: 妥当。要点は3点。"))
    let guardPayload = try XCTUnwrap(jsonObject(output.payload["handoffGuard"]))
    XCTAssertEqual(guardPayload["blocked"], .bool(false))
    XCTAssertEqual(guardPayload["selectedTarget"], .null)
  }

  func testBlockedTargetMentionIsPreservedWhenItIsNotAContinuation() async throws {
    let noteRoot = try makeNotePersonaAddonRoot()
    defer { try? FileManager.default.removeItem(atPath: noteRoot) }
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": noteRoot])

    let output = try await resolver.execute(
      notePersonaInput(
        name: "riela/note-persona-context-write",
        config: [
          "personaId": .string("rina"),
          "personaName": .string("Rina Cursor"),
          "teamPersonaIds": .array([.string("yui"), .string("mika"), .string("rina")])
        ],
        variables: [
          "payload": .object([
            "replyText": .string("Yuiの前提は正しい。ここで止める。"),
            "handoff_yui": .bool(true),
            "noteEntries": .array([])
          ]),
          "upstream": .array([
            .object(["output": .object(["payload": .object([
              "replyAs": .string("yui"),
              "replyText": .string("Yui reply")
            ])])])
          ])
        ]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.when["handoff_yui"], false)
    XCTAssertEqual(output.payload["replyText"], .string("Yuiの前提は正しい。ここで止める。"))
    let guardPayload = try XCTUnwrap(jsonObject(output.payload["handoffGuard"]))
    XCTAssertEqual(guardPayload["blocked"], .bool(true))
    XCTAssertEqual(guardPayload["reason"], .string("target-persona-already-replied"))
  }

  func testSelfHandoffIsBlockedAndDanglingReplyFallsBack() async throws {
    let noteRoot = try makeNotePersonaAddonRoot()
    defer { try? FileManager.default.removeItem(atPath: noteRoot) }
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": noteRoot])

    let output = try await resolver.execute(
      notePersonaInput(
        name: "riela/note-persona-context-write",
        config: [
          "personaId": .string("yui"),
          "personaName": .string("Yui Codex"),
          "teamPersonaIds": .array([.string("yui"), .string("mika"), .string("rina")])
        ],
        variables: ["payload": .object([
          "replyText": .string("続きは@Yuiが見るね。"),
          "handoff_yui": .bool(true),
          "noteEntries": .array([])
        ])]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.when["handoff_yui"], false)
    XCTAssertEqual(output.payload["replyText"], .string("Yui Codexです。今の話題を受けて、自然に続けます。"))
    let guardPayload = try XCTUnwrap(jsonObject(output.payload["handoffGuard"]))
    XCTAssertEqual(guardPayload["blocked"], .bool(true))
    XCTAssertEqual(guardPayload["reason"], .string("current-persona-already-replied"))
    XCTAssertEqual(guardPayload["selectedTarget"], .string("yui"))
  }

  func testMaximumTurnGuardBlocksOtherwiseUnvisitedHandoff() async throws {
    let noteRoot = try makeNotePersonaAddonRoot()
    defer { try? FileManager.default.removeItem(atPath: noteRoot) }
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": noteRoot])

    let output = try await resolver.execute(
      notePersonaInput(
        name: "riela/note-persona-context-write",
        config: [
          "personaId": .string("rina"),
          "personaName": .string("Rina Cursor"),
          "teamPersonaIds": .array([.string("yui"), .string("mika"), .string("rina")]),
          "maxHandoffTurns": .number(2)
        ],
        variables: [
          "handoffTrail": .array([.string("yui")]),
          "payload": .object([
            "replyText": .string("結論。@Mika はどう見る？"),
            "handoff_mika": .bool(true),
            "noteEntries": .array([])
          ])
        ]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.when["handoff_mika"], false)
    XCTAssertEqual(output.payload["replyText"], .string("結論。"))
    let guardPayload = try XCTUnwrap(jsonObject(output.payload["handoffGuard"]))
    XCTAssertEqual(guardPayload["blocked"], .bool(true))
    XCTAssertEqual(guardPayload["reason"], .string("max-handoff-turns-reached"))
    XCTAssertEqual(guardPayload["selectedTarget"], .string("mika"))
  }

  func testPersonaAddonsRejectUnsupportedVersionsAndLegacyMemoryConfiguration() async throws {
    let noteRoot = try makeNotePersonaAddonRoot()
    defer { try? FileManager.default.removeItem(atPath: noteRoot) }
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": noteRoot])

    for input in [
      notePersonaInput(
        name: "riela/note-persona-context-read",
        version: "2",
        config: ["personaId": .string("yui")]
      ),
      notePersonaInput(
        name: "riela/note-persona-context-write",
        config: ["personaId": .string("yui"), "memoryId": .string("legacy")]
      )
    ] {
      do {
        _ = try await resolver.execute(input, context: AdapterExecutionContext())
        XCTFail("Expected unsupported persona add-on input rejection")
      } catch {
        XCTAssertFalse(String(describing: error).isEmpty)
      }
    }
  }

  func testEnterpriseManagerCanReadAllTeamMemoryButWriteOnlyOwn() async throws {
    let noteRoot = try makeNotePersonaAddonRoot()
    defer { try? FileManager.default.removeItem(atPath: noteRoot) }
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": noteRoot])
    let team = ["incident-lead", "security-analyst", "compliance-counsel"]

    for personaId in team {
      _ = try await resolver.execute(
        notePersonaInput(
          name: "riela/note-persona-context-write",
          config: [
            "personaId": .string(personaId),
            "actorPersonaId": .string(personaId),
            "teamPersonaIds": .array(team.map(JSONValue.string))
          ],
          variables: ["payload": .object([
            "noteEntries": .array([.object(["content": .string("\(personaId) private context")])])
          ])]
        ),
        context: AdapterExecutionContext()
      )
    }

    for target in team {
      let read = try await resolver.execute(
        notePersonaInput(
          name: "riela/note-persona-context-read",
          config: [
            "personaId": .string(target),
            "actorPersonaId": .string("incident-lead"),
            "allowedReadPersonaIds": .array(team.map(JSONValue.string)),
            "teamPersonaIds": .array(team.map(JSONValue.string))
          ]
        ),
        context: AdapterExecutionContext()
      )
      XCTAssertEqual(read.payload["noteCount"], .number(1))
      let access = try XCTUnwrap(jsonObject(read.payload["access"]))
      XCTAssertEqual(access["actorPersonaId"], .string("incident-lead"))
      XCTAssertEqual(access["targetPersonaId"], .string(target))
      XCTAssertEqual(access["allowed"], .bool(true))
    }

    do {
      _ = try await resolver.execute(
        notePersonaInput(
          name: "riela/note-persona-context-write",
          config: [
            "personaId": .string("security-analyst"),
            "actorPersonaId": .string("incident-lead"),
            "allowedReadPersonaIds": .array(team.map(JSONValue.string))
          ],
          variables: ["payload": .object([
            "noteEntries": .array([.object(["content": .string("forbidden manager write")])])
          ])]
        ),
        context: AdapterExecutionContext()
      )
      XCTFail("Expected cross-persona manager write to be blocked")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertTrue(error.message.contains("incident-lead"))
      XCTAssertTrue(error.message.contains("security-analyst"))
    }
  }

  func testEnterpriseSpecialistCanOnlyReadAndWriteOwnMemory() async throws {
    let noteRoot = try makeNotePersonaAddonRoot()
    defer { try? FileManager.default.removeItem(atPath: noteRoot) }
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": noteRoot])

    for operation in ["read", "write"] {
      do {
        _ = try await resolver.execute(
          notePersonaInput(
            name: "riela/note-persona-context-\(operation)",
            config: [
              "personaId": .string("incident-lead"),
              "actorPersonaId": .string("security-analyst")
            ],
            variables: ["payload": .object(["noteEntries": .array([])])]
          ),
          context: AdapterExecutionContext()
        )
        XCTFail("Expected specialist cross-persona \(operation) to be blocked")
      } catch let error as AdapterExecutionError {
        XCTAssertEqual(error.code, .policyBlocked)
      }
    }

    let ownWrite = try await resolver.execute(
      notePersonaInput(
        name: "riela/note-persona-context-write",
        config: [
          "personaId": .string("security-analyst"),
          "actorPersonaId": .string("security-analyst")
        ],
        variables: ["payload": .object([
          "noteEntries": .array([.object(["content": .string("own finding")])])
        ])]
      ),
      context: AdapterExecutionContext()
    )
    XCTAssertEqual(ownWrite.payload["entriesWritten"], .number(1))
  }

  func testConfiguredEnterpriseTeamUsesBoundedDynamicHandoffKeys() async throws {
    let noteRoot = try makeNotePersonaAddonRoot()
    defer { try? FileManager.default.removeItem(atPath: noteRoot) }
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": noteRoot])
    let team = ["incident-lead", "security-analyst", "compliance-counsel"]

    let output = try await resolver.execute(
      notePersonaInput(
        name: "riela/note-persona-context-write",
        config: [
          "personaId": .string("security-analyst"),
          "actorPersonaId": .string("security-analyst"),
          "teamPersonaIds": .array(team.map(JSONValue.string)),
          "maxHandoffTurns": .number(2)
        ],
        variables: [
          "handoffTrail": .array([.string("incident-lead")]),
          "payload": .object([
            "replyText": .string("Analysis complete. @compliance-counsel please review."),
            "handoff_compliance-counsel": .bool(true),
            "noteEntries": .array([])
          ])
        ]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.when["handoff_compliance-counsel"], false)
    XCTAssertEqual(output.payload["handoff_compliance-counsel"], .bool(false))
    let guardPayload = try XCTUnwrap(jsonObject(output.payload["handoffGuard"]))
    XCTAssertEqual(guardPayload["reason"], .string("max-handoff-turns-reached"))
  }

  private func notePersonaInput(
    name: String,
    version: String = "1",
    config: JSONObject,
    variables: JSONObject = [:],
    attachments: [String: WorkflowAddonAttachmentValue] = [:]
  ) -> WorkflowAddonExecutionInput {
    WorkflowAddonExecutionInput(
      workflowId: "note-persona-addon-tests",
      stepId: name.replacingOccurrences(of: "riela/", with: "").replacingOccurrences(of: "/", with: "-"),
      nodeId: name.replacingOccurrences(of: "riela/", with: "").replacingOccurrences(of: "/", with: "-"),
      addon: WorkflowNodeAddonRef(name: name, version: version, config: config),
      variables: variables,
      attachments: attachments
    )
  }

  private func makeNotePersonaAddonRoot() throws -> String {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/RielaCLITests/NotePersonaAddonTests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.path
  }

  private func jsonObject(_ value: JSONValue?) -> JSONObject? {
    guard case let .object(object)? = value else { return nil }
    return object
  }
}
