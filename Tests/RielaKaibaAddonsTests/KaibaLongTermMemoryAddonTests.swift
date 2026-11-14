import AppCore
import Foundation
import RielaAddonSupport
import RielaCore
import XCTest
@testable import RielaKaibaAddons

final class KaibaLongTermMemoryAddonTests: XCTestCase {
  private func scratchNoteRoot() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-long-term-memory-addon-\(UUID().uuidString)", isDirectory: true)
  }

  private func consolidate(
    noteRoot: String,
    config extraConfig: JSONObject = [:],
    resolvedInputPayload: JSONObject
  ) async throws -> AdapterExecutionOutput {
    var config: JSONObject = ["noteRoot": .string(noteRoot)]
    for (key, value) in extraConfig {
      config[key] = value
    }
    return try await KaibaAddonCatalog.execute(
      WorkflowAddonExecutionInput(
        workflowId: "memory-consolidation",
        stepId: "consolidate-long-term",
        nodeId: "consolidate-long-term",
        addon: WorkflowNodeAddonRef(name: "kaiba/memory-consolidate", version: "1", config: config),
        resolvedInputPayload: resolvedInputPayload
      ),
      environment: [:]
    )
  }

  func testConsolidateStoresShortTermRecordIdsAsMetadataNotNoteLinks() async throws {
    let noteRoot = scratchNoteRoot()
    defer {
      try? FileManager.default.removeItem(at: noteRoot)
    }

    let output = try await consolidate(
      noteRoot: noteRoot.path,
      config: ["idempotencyKey": .string("period-2026-08-01")],
      resolvedInputPayload: [
        "memoryEntries": .array([
          .object([
            "content": .string("# project-atlas kickoff\n\nScope was settled in the design review."),
            "topicTags": .array([.string("project-atlas")]),
            "sourceMemoryRecordIds": .array([.integer(1), .integer(2)]),
            "periodStart": .string("2026-08-01T00:00:00Z"),
            "periodEnd": .string("2026-08-08T00:00:00Z")
          ])
        ])
      ]
    )

    XCTAssertEqual(output.payload["entriesWritten"], .number(1))
    XCTAssertEqual(output.payload["idempotentReplay"], .bool(false))
    guard case let .array(noteIds)? = output.payload["noteIds"], noteIds.count == 1 else {
      return XCTFail("consolidation did not return exactly one note id")
    }

    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot.path))
    let noteId = NoteID(try XCTUnwrap(nonEmptyString(noteIds[0])))
    let note = try service.getNote(noteId)
    let metaJSON = try XCTUnwrap(note.metaJSON)
    XCTAssertTrue(metaJSON.contains("\"sourceMemoryRecordIds\":[1,2]"), metaJSON)
    XCTAssertTrue(metaJSON.contains("\"sourceNoteIds\":[]"), metaJSON)
    XCTAssertEqual(note.tags.map(\.tag.name), ["project-atlas"])
    XCTAssertEqual(try service.listLinks(noteId: noteId), [])
  }

  func testConsolidateReplaysUnderTheSameIdempotencyKey() async throws {
    let noteRoot = scratchNoteRoot()
    defer {
      try? FileManager.default.removeItem(at: noteRoot)
    }
    let payload: JSONObject = [
      "memoryEntries": .array([
        .object(["content": .string("# nightly window\n\nOne durable fact.")])
      ])
    ]

    let first = try await consolidate(
      noteRoot: noteRoot.path,
      config: ["idempotencyKey": .string("period-2026-08-01")],
      resolvedInputPayload: payload
    )
    let second = try await consolidate(
      noteRoot: noteRoot.path,
      config: ["idempotencyKey": .string("period-2026-08-01")],
      resolvedInputPayload: payload
    )

    XCTAssertEqual(first.payload["idempotentReplay"], .bool(false))
    XCTAssertEqual(second.payload["idempotentReplay"], .bool(true))
    XCTAssertEqual(first.payload["noteIds"], second.payload["noteIds"])
    // A replay must not re-run association linking against the same note.
    XCTAssertEqual(second.payload["associations"], .array([]))

    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot.path))
    XCTAssertEqual(try service.listLongTermMemoryNotes(limit: 20).count, 1)
  }

  func testRecallReturnsPromptReadyTextForConsolidatedMemories() async throws {
    let noteRoot = scratchNoteRoot()
    defer {
      try? FileManager.default.removeItem(at: noteRoot)
    }
    _ = try await consolidate(
      noteRoot: noteRoot.path,
      config: ["idempotencyKey": .string("period-2026-08-01")],
      resolvedInputPayload: [
        "memoryEntries": .array([
          .object([
            "content": .string("# project-atlas kickoff\n\nScope was settled in the design review."),
            "topicTags": .array([.string("project-atlas")])
          ])
        ])
      ]
    )

    let output = try await KaibaAddonCatalog.execute(
      WorkflowAddonExecutionInput(
        workflowId: "memory-consolidation",
        stepId: "recall-long-term",
        nodeId: "recall-long-term",
        addon: WorkflowNodeAddonRef(
          name: "kaiba/memory-recall",
          version: "1",
          config: [
            "noteRoot": .string(noteRoot.path),
            "query": .string("project-atlas"),
            "passthrough": .object(["entriesWritten": .string("{{entriesWritten}}")])
          ]
        ),
        resolvedInputPayload: ["entriesWritten": .number(1)]
      ),
      environment: [:]
    )

    XCTAssertEqual(output.payload["resultCount"], .number(1))
    // The passthrough keeps the upstream value's JSON type instead of stringifying it.
    XCTAssertEqual(output.payload["entriesWritten"], .number(1))
    let recallText = try XCTUnwrap(nonEmptyString(output.payload["recallText"]))
    XCTAssertTrue(recallText.contains("[direct]"), recallText)
    XCTAssertTrue(recallText.contains("project-atlas kickoff"), recallText)
  }

  func testUnsupportedVersionIsRejected() async {
    let noteRoot = scratchNoteRoot()
    defer {
      try? FileManager.default.removeItem(at: noteRoot)
    }
    do {
      _ = try await KaibaAddonCatalog.execute(
        WorkflowAddonExecutionInput(
          workflowId: "memory-consolidation",
          stepId: "recall-long-term",
          nodeId: "recall-long-term",
          addon: WorkflowNodeAddonRef(
            name: "kaiba/memory-recall",
            version: "2",
            config: ["noteRoot": .string(noteRoot.path), "query": .string("anything")]
          ),
          resolvedInputPayload: [:]
        ),
        environment: [:]
      )
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      return
    } catch {
      return XCTFail("expected a policy-blocked version rejection, got \(error)")
    }
    XCTFail("expected version '2' to be rejected")
  }

  func testConsolidateRequiresAtLeastOneEntry() async {
    let noteRoot = scratchNoteRoot()
    defer {
      try? FileManager.default.removeItem(at: noteRoot)
    }
    do {
      _ = try await consolidate(noteRoot: noteRoot.path, resolvedInputPayload: [:])
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .invalidInput)
      return
    } catch {
      return XCTFail("expected an invalid-input rejection, got \(error)")
    }
    XCTFail("expected an empty entry list to be rejected")
  }

  func testConsolidateAllowsEmptyEntriesAsNoOpWhenOptedIn() async throws {
    let noteRoot = scratchNoteRoot()
    defer {
      try? FileManager.default.removeItem(at: noteRoot)
    }

    let output = try await consolidate(
      noteRoot: noteRoot.path,
      config: [
        "entries": .array([]),
        "allowEmptyEntries": .bool(true),
        "idempotencyKey": .string("seed-2026-08-21")
      ],
      resolvedInputPayload: [:]
    )

    XCTAssertEqual(output.payload["entriesWritten"], .number(0))
    XCTAssertEqual(output.payload["idempotentReplay"], .bool(false))
    XCTAssertEqual(output.payload["noteIds"], .array([]))
    XCTAssertEqual(output.payload["notes"], .array([]))
    XCTAssertEqual(output.payload["associations"], .array([]))
    XCTAssertEqual(output.payload["idempotencyKey"], .string("seed-2026-08-21"))
    XCTAssertNotNil(nonEmptyString(output.payload["notebookId"] ?? .null))
  }
}
