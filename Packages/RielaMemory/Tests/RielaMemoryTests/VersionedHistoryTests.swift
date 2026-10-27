import Foundation
import SQLite3
import XCTest
@testable import RielaMemory

final class VersionedHistoryTests: XCTestCase {
  func testCodecRoundTripsBinaryAndSplices() throws {
    let randomBinary = Data((0..<4096).map { _ in UInt8.random(in: .min ... .max) })
    let values = [Data(), Data([0, 1, 2, 255]), randomBinary, Data("こんにちは 🌏".utf8), Data(repeating: 65, count: 8192)]
    for value in values {
      let (blob, codec) = try VersionedHistoryCodec.compressed(value)
      XCTAssertEqual(try VersionedHistoryCodec.decompressed(blob, codec: codec, byteCount: Int64(value.count)), value)
      let splice = VersionedHistoryCodec.splice(Data("prefix-old-suffix".utf8), Data("prefix-new-suffix".utf8))
      XCTAssertEqual(try VersionedHistoryCodec.apply(splice, to: Data("prefix-old-suffix".utf8)), Data("prefix-new-suffix".utf8))
    }
  }

  func testRetentionMonotonicVersionsDedupAndUndoRedo() throws {
    let fixture = try Fixture(storage: .stored)
    defer { fixture.close() }
    var last: Data?
    for index in 0..<5 {
      let value = Data("value-\(index)".utf8)
      _ = try fixture.store.write(key: "k", value: value, currentHeadValue: nil, expectedRevision: index == 0 ? 0 : Int64(index), force: false,
                                  retainedGenerations: 5, defaultRetainedGenerations: 5, pins: [])
      last = value
    }
    XCTAssertEqual(try fixture.store.head(key: "k")?.revision, 5)
    let duplicate = try fixture.store.write(key: "k", value: last!, currentHeadValue: nil, expectedRevision: 5, force: false,
                                           retainedGenerations: 5, defaultRetainedGenerations: 5, pins: [])
    XCTAssertEqual(duplicate.outcome, .unchanged)
    let firstUndo = try fixture.store.undo(key: "k", currentHeadValue: nil, expectedRevision: 5)
    XCTAssertEqual(firstUndo.value, Data("value-3".utf8))
    XCTAssertEqual(try fixture.store.versions(key: "k", limit: 10, beforeVersion: nil).count, 5)
    let secondUndo = try fixture.store.undo(key: "k", currentHeadValue: nil, expectedRevision: 6)
    XCTAssertEqual(secondUndo.value, Data("value-2".utf8))
    let redo = try fixture.store.redo(key: "k", currentHeadValue: nil, expectedRevision: 7)
    XCTAssertEqual(redo.value, Data("value-3".utf8))
    XCTAssertEqual(redo.revision, 8)
    XCTAssertEqual(try fixture.store.versions(key: "k", limit: 10, beforeVersion: nil).map(\.version), [5, 4, 3, 2, 1])
    let finalRedo = try fixture.store.redo(key: "k", currentHeadValue: nil, expectedRevision: 8)
    XCTAssertEqual(finalRedo.value, Data("value-4".utf8))
    XCTAssertThrowsError(try fixture.store.redo(key: "k", currentHeadValue: nil, expectedRevision: 9)) { error in
      XCTAssertEqual(error as? VersionedHistoryError, .nothingToRedo)
    }
    let forced = try fixture.store.write(key: "k", value: finalRedo.value, currentHeadValue: nil, expectedRevision: 9, force: true,
      retainedGenerations: 5, defaultRetainedGenerations: 5, pins: [])
    XCTAssertEqual(forced.outcome, .written)
    XCTAssertEqual(forced.version, 10)
  }

  func testExternalHeadRetentionPinsAndGuardedDelete() throws {
    let fixture = try Fixture(storage: .external)
    defer { fixture.close() }
    var value = Data("v0".utf8)
    for index in 0..<25 {
      value = Data("v\(index)".utf8)
      _ = try fixture.store.write(key: "k", value: value, currentHeadValue: index == 0 ? nil : Data("v\(index - 1)".utf8),
        expectedRevision: Int64(index), force: false, retainedGenerations: 10, defaultRetainedGenerations: 10, pins: [3])
    }
    XCTAssertEqual(try fixture.store.head(key: "k")?.headVersion, 25)
    XCTAssertEqual(try fixture.store.value(key: "k", version: 3, currentHeadValue: value), Data("v2".utf8))
    let retained = try fixture.store.versions(key: "k", limit: 100, beforeVersion: nil).map(\.version)
    XCTAssertEqual(Set(retained), Set([3] + (16...25)))
    XCTAssertEqual(fixture.deleteGuards, 25 - retained.count)
  }

  func testRetentionOneAndStaleRevisionErrors() throws {
    let fixture = try Fixture(storage: .stored)
    defer { fixture.close() }
    _ = try fixture.store.write(key: "x", value: Data("a".utf8), currentHeadValue: nil, expectedRevision: 0, force: false,
                                retainedGenerations: 1, defaultRetainedGenerations: 1, pins: [])
    _ = try fixture.store.write(key: "x", value: Data("b".utf8), currentHeadValue: nil, expectedRevision: 1, force: false,
                                retainedGenerations: 1, defaultRetainedGenerations: 1, pins: [])
    XCTAssertEqual(try fixture.store.versions(key: "x", limit: 10, beforeVersion: nil).map(\.version), [2])
    XCTAssertThrowsError(try fixture.store.value(key: "x", version: 1, currentHeadValue: nil)) { error in
      XCTAssertEqual(error as? VersionedHistoryError, .versionNotRetained(version: 1, retained: [2], retainedGenerations: 1))
    }
    XCTAssertThrowsError(try fixture.store.write(key: "x", value: Data("c".utf8), currentHeadValue: nil, expectedRevision: 1, force: false,
      retainedGenerations: 1, defaultRetainedGenerations: 1, pins: [])) { error in
      XCTAssertEqual(error as? VersionedHistoryError, .staleRevision(expected: 1, actual: 2))
    }
  }

  func testApplyRetentionAfterUndoKeepsHeadAndRedoBranch() throws {
    let values = ["a", "b", "c", "d"].map { Data($0.utf8) }
    for storage in [VersionedHistoryHeadStorage.stored, .external] {
      let fixture = try Fixture(storage: storage)
      defer { fixture.close() }
      let headValueForCall: (Data) -> Data? = { value in
        switch storage {
        case .stored: return nil
        case .external: return value
        }
      }

      for (index, value) in values.enumerated() {
        _ = try fixture.store.write(key: "retention-r1", value: value,
          currentHeadValue: index == 0 ? nil : headValueForCall(values[index - 1]), expectedRevision: Int64(index),
          force: false, retainedGenerations: 0, defaultRetainedGenerations: 0, pins: [])
      }
      _ = try fixture.store.undo(key: "retention-r1", currentHeadValue: headValueForCall(values[3]), expectedRevision: 4)
      _ = try fixture.store.undo(key: "retention-r1", currentHeadValue: headValueForCall(values[2]), expectedRevision: 5)

      let oneGeneration = try fixture.store.applyRetention(key: "retention-r1", currentHeadValue: headValueForCall(values[1]),
        retainedGenerations: 1, pins: [])
      XCTAssertEqual(oneGeneration.dropped, [1])
      XCTAssertGreaterThan(oneGeneration.freedBytes, 0)
      XCTAssertEqual(try fixture.store.head(key: "retention-r1")?.headVersion, 2)
      XCTAssertEqual(try fixture.store.value(key: "retention-r1", version: 2, currentHeadValue: headValueForCall(values[1])), values[1])
      XCTAssertEqual(try fixture.store.versions(key: "retention-r1", limit: 10, beforeVersion: nil).map(\.version), [4, 3, 2])

      let redo = try fixture.store.redo(key: "retention-r1", currentHeadValue: headValueForCall(values[1]), expectedRevision: 6)
      XCTAssertEqual(redo.value, values[2])
      let nextWrite = try fixture.store.write(key: "retention-r1", value: Data("e".utf8), currentHeadValue: headValueForCall(values[2]),
        expectedRevision: redo.revision, force: false, retainedGenerations: 1, defaultRetainedGenerations: 1, pins: [])
      XCTAssertEqual(nextWrite.outcome, .written)

      for (index, value) in values.enumerated() {
        _ = try fixture.store.write(key: "retention-r2", value: value,
          currentHeadValue: index == 0 ? nil : headValueForCall(values[index - 1]), expectedRevision: Int64(index),
          force: false, retainedGenerations: 0, defaultRetainedGenerations: 0, pins: [])
      }
      _ = try fixture.store.undo(key: "retention-r2", currentHeadValue: headValueForCall(values[3]), expectedRevision: 4)
      _ = try fixture.store.undo(key: "retention-r2", currentHeadValue: headValueForCall(values[2]), expectedRevision: 5)
      let twoGenerations = try fixture.store.applyRetention(key: "retention-r2", currentHeadValue: headValueForCall(values[1]),
        retainedGenerations: 2, pins: [])
      XCTAssertEqual(twoGenerations.dropped, [])
      XCTAssertEqual(try fixture.store.value(key: "retention-r2", version: 1, currentHeadValue: headValueForCall(values[1])), values[0])
    }
  }

  func testRedoBranchPinnedRowDetachesAndStaysFull() throws {
    let fixture = try Fixture(storage: .external)
    defer { fixture.close() }
    _ = try fixture.store.write(key: "branch", value: Data("a".utf8), currentHeadValue: nil, expectedRevision: 0, force: false,
      retainedGenerations: 0, defaultRetainedGenerations: 0, pins: [])
    _ = try fixture.store.write(key: "branch", value: Data("b".utf8), currentHeadValue: Data("a".utf8), expectedRevision: 1, force: false,
      retainedGenerations: 0, defaultRetainedGenerations: 0, pins: [])
    _ = try fixture.store.write(key: "branch", value: Data("c".utf8), currentHeadValue: Data("b".utf8), expectedRevision: 2, force: false,
      retainedGenerations: 0, defaultRetainedGenerations: 0, pins: [])
    let undo = try fixture.store.undo(key: "branch", currentHeadValue: Data("c".utf8), expectedRevision: 3)
    let write = try fixture.store.write(key: "branch", value: Data("d".utf8), currentHeadValue: undo.value, expectedRevision: 4, force: false,
      retainedGenerations: 0, defaultRetainedGenerations: 0, pins: [3])
    XCTAssertEqual(write.droppedVersions, [])
    let detached = try XCTUnwrap(fixture.store.versions(key: "branch", limit: 10, beforeVersion: nil).first { $0.version == 3 })
    XCTAssertTrue(detached.detached)
    XCTAssertEqual(detached.encoding, "full")
    XCTAssertEqual(try fixture.store.value(key: "branch", version: 3, currentHeadValue: Data("d".utf8)), Data("c".utf8))
    XCTAssertThrowsError(try fixture.store.redo(key: "branch", currentHeadValue: Data("d".utf8), expectedRevision: 5)) { error in
      XCTAssertEqual(error as? VersionedHistoryError, .nothingToRedo)
    }

    _ = try fixture.store.write(key: "drop-branch", value: Data("a".utf8), currentHeadValue: nil, expectedRevision: 0, force: false,
      retainedGenerations: 0, defaultRetainedGenerations: 0, pins: [])
    _ = try fixture.store.write(key: "drop-branch", value: Data("b".utf8), currentHeadValue: Data("a".utf8), expectedRevision: 1, force: false,
      retainedGenerations: 0, defaultRetainedGenerations: 0, pins: [])
    _ = try fixture.store.write(key: "drop-branch", value: Data("c".utf8), currentHeadValue: Data("b".utf8), expectedRevision: 2, force: false,
      retainedGenerations: 0, defaultRetainedGenerations: 0, pins: [])
    let unpinnedUndo = try fixture.store.undo(key: "drop-branch", currentHeadValue: Data("c".utf8), expectedRevision: 3)
    let detachedBranch = try fixture.store.write(key: "drop-branch", value: Data("d".utf8), currentHeadValue: unpinnedUndo.value, expectedRevision: 4,
      force: false, retainedGenerations: 0, defaultRetainedGenerations: 0, pins: [])
    XCTAssertEqual(detachedBranch.droppedVersions, [3])
    XCTAssertEqual(try fixture.store.versions(key: "drop-branch", limit: 10, beforeVersion: nil).map(\.version), [5, 2, 1])
    XCTAssertEqual(unpinnedUndo.value, Data("b".utf8))
  }

  func testImportedChainReconstructsAndCorruptRowsFailClosed() throws {
    let fixture = try Fixture(storage: .stored)
    defer { fixture.close() }
    try fixture.store.importChain(key: "imported", revision: 3, headVersion: 3, headValue: Data("head".utf8), previous: [
      (version: 1, createdAt: "one", value: Data("old".utf8)),
      (version: 2, createdAt: "two", value: Data("mid".utf8))
    ])
    XCTAssertEqual(try fixture.store.value(key: "imported", version: 1, currentHeadValue: nil), Data("old".utf8))
    try RawSQLiteHistoryExecutor(db: fixture.db).execute("UPDATE test_history_versions SET blob = x'00' WHERE key = ? AND version = ?", [.text("imported"), .int(2)])
    XCTAssertThrowsError(try fixture.store.value(key: "imported", version: 2, currentHeadValue: nil)) { error in
      guard let historyError = error as? VersionedHistoryError, case .historyCorrupt = historyError else {
        return XCTFail("expected historyCorrupt, got \(error)")
      }
    }
  }

  func testFiveGenerationWindowKeepsFourPreviousValues() throws {
    let fixture = try Fixture(storage: .stored)
    defer { fixture.close() }
    for index in 1...8 {
      _ = try fixture.store.write(key: "five", value: Data("v\(index)".utf8), currentHeadValue: nil, expectedRevision: Int64(index - 1), force: false,
        retainedGenerations: 5, defaultRetainedGenerations: 5, pins: [])
    }
    let versions = try fixture.store.versions(key: "five", limit: 10, beforeVersion: nil).map(\.version)
    XCTAssertEqual(versions, [8, 7, 6, 5, 4])
  }

  func testUndoStopsAtOldestRetainedVersion() throws {
    let fixture = try Fixture(storage: .stored)
    defer { fixture.close() }
    for index in 1...3 {
      _ = try fixture.store.write(key: "undo", value: Data("v\(index)".utf8), currentHeadValue: nil, expectedRevision: Int64(index - 1), force: false,
        retainedGenerations: 0, defaultRetainedGenerations: 0, pins: [])
    }
    let first = try fixture.store.undo(key: "undo", currentHeadValue: nil, expectedRevision: 3)
    let second = try fixture.store.undo(key: "undo", currentHeadValue: nil, expectedRevision: 4)
    XCTAssertEqual(first.value, Data("v2".utf8))
    XCTAssertEqual(second.value, Data("v1".utf8))
    XCTAssertThrowsError(try fixture.store.undo(key: "undo", currentHeadValue: nil, expectedRevision: 5)) { error in
      XCTAssertEqual(error as? VersionedHistoryError, .nothingToUndo(oldestRetained: 1))
    }
  }

  func testDiffEscapingArraysNumberLiteralsAndBytesFallback() {
    let entries = VersionedHistoryDiff.diff(before: Data(#"{"a/b":{"~key":1},"items":["x","y"]}"#.utf8),
      after: Data(#"{"a/b":{"~key":1.0},"items":["x","z","tail"]}"#.utf8))
    XCTAssertEqual(entries.map(\.path), ["/a~1b/~0key", "/items/1", "/items/2"])
    XCTAssertEqual(entries.map(\.op), ["replace", "replace", "add"])
    XCTAssertEqual(entries[0].beforeJSON, Data("1".utf8))
    XCTAssertEqual(entries[0].afterJSON, Data("1.0".utf8))
    XCTAssertTrue(VersionedHistoryDiff.diff(before: Data("{\"same\":true}".utf8), after: Data("{\"same\":true}".utf8)).isEmpty)
    let fallback = VersionedHistoryDiff.diff(before: Data([0, 1]), after: Data([0, 2]))
    XCTAssertEqual(fallback.count, 1)
    XCTAssertEqual(fallback[0].encoding, "bytes")
  }

  func testLargeDocumentRetentionRemainsBounded() throws {
    let fixture = try Fixture(storage: .stored)
    defer { fixture.close() }
    for index in 1...1000 {
      let json = "{\"header\":\"\(String(format: "%08d", index))\",\"items\":[" +
        Array(repeating: "\"stable payload\"", count: 38_800).joined(separator: ",") + ",\"item-\(index)\"]}"
      let value = Data(json.utf8)
      if index == 1 { XCTAssertEqual(value.count, 660_000, accuracy: 10_000) }
      _ = try fixture.store.write(key: "large", value: value, currentHeadValue: nil, expectedRevision: Int64(index - 1), force: false,
                                 retainedGenerations: 2, defaultRetainedGenerations: 2, pins: [])
    }
    let head = try XCTUnwrap(fixture.store.head(key: "large"))
    XCTAssertEqual(head.revision, 1000)
    let versions = try fixture.store.versions(key: "large", limit: 10, beforeVersion: nil)
    XCTAssertEqual(versions.count, 2)
    XCTAssertLessThanOrEqual(versions.first(where: { !$0.isHead })!.storedBytes,
      Int64(try VersionedHistoryCodec.compressed(fixture.store.value(key: "large", version: 999, currentHeadValue: nil)).0.count))
  }

  private final class Fixture {
    let db: OpaquePointer
    let store: VersionedHistoryStore
    let spy: DeleteSpy
    var deleteGuards: Int { spy.count }
    init(storage: VersionedHistoryHeadStorage) throws {
      var opened: OpaquePointer?
      guard sqlite3_open(":memory:", &opened) == SQLITE_OK, let opened else { throw NSError(domain: "sqlite", code: 1) }
      db = opened
      let spy = DeleteSpy()
      self.spy = spy
      store = VersionedHistoryStore(tablePrefix: "test", headStorage: storage, sql: RawSQLiteHistoryExecutor(db: opened),
        withGuardedDelete: { action in spy.count += 1; try action() })
      try store.ensureSchema()
    }
    func close() { sqlite3_close(db) }
  }

  private final class DeleteSpy { var count = 0 }
}
