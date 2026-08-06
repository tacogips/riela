import Foundation
import XCTest
@testable import RielaCLI
@testable import RielaCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class GitWorkflowAddonStoreReadTests: XCTestCase {
  func testCreateOnlyRetryAcceptsPostLinkCrashArtifactWithoutDeletion() throws {
    let fixture = try GitFinalizationStoreFixture()
    let key = String(repeating: "e", count: 64)
    let data = Data("prepared".utf8)
    let destination = try fixture.store.writePreparedIndex(data, journalKey: key)
    let orphan = fixture.root.appendingPathComponent("tmp/post-link-crash")
    guard link(destination.path, orphan.path) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    var linkedStatus = stat()
    XCTAssertEqual(lstat(destination.path, &linkedStatus), 0)
    XCTAssertEqual(linkedStatus.st_nlink, 2)

    XCTAssertEqual(try fixture.store.writePreparedIndex(data, journalKey: key), destination)

    XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
    var reconciledStatus = stat()
    XCTAssertEqual(lstat(destination.path, &reconciledStatus), 0)
    XCTAssertEqual(reconciledStatus.st_nlink, 2)
  }

  func testOwnedHardLinkReplacementDuringValidationPreservesReplacementAndFailsClosed() throws {
    let fixture = try GitFinalizationStoreFixture()
    let key = String(repeating: "g", count: 64)
    let destination = try fixture.store.writePreparedIndex(Data("prepared".utf8), journalKey: key)
    let temporaryDirectory = fixture.root.appendingPathComponent("tmp")
    let ownedLink = temporaryDirectory.appendingPathComponent("owned-crash-link")
    let displacedLink = fixture.root.appendingPathComponent("displaced-owned-link")
    let replacement = fixture.root.appendingPathComponent("unrelated-replacement")
    let replacementData = Data("unrelated".utf8)
    guard link(destination.path, ownedLink.path) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    try replacementData.write(to: replacement)

    XCTAssertThrowsError(try boundedGitFinalizationRecordData(
      from: destination,
      maxBytes: 64 * 1024 * 1024,
      ownedHardLinkDirectory: temporaryDirectory,
      afterOwnedHardLinkValidation: {
        try FileManager.default.moveItem(at: ownedLink, to: displacedLink)
        try FileManager.default.moveItem(at: replacement, to: ownedLink)
      }
    )) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("unowned hard link") == true)
    }
    XCTAssertEqual(try Data(contentsOf: ownedLink), replacementData)
    XCTAssertTrue(FileManager.default.fileExists(atPath: displacedLink.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
  }

  func testOwnedHardLinkValidationRejectsEntryLimitExhaustion() throws {
    let fixture = try GitFinalizationStoreFixture()
    let key = String(repeating: "h", count: 64)
    let destination = try fixture.store.writePreparedIndex(Data("prepared".utf8), journalKey: key)
    let temporaryDirectory = fixture.root.appendingPathComponent("tmp")
    let ownedLink = temporaryDirectory.appendingPathComponent("owned-crash-link")
    guard link(destination.path, ownedLink.path) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    XCTAssertThrowsError(try boundedGitFinalizationRecordData(
      from: destination,
      maxBytes: 64 * 1024 * 1024,
      ownedHardLinkDirectory: temporaryDirectory,
      ownedHardLinkEntryLimit: 0
    )) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("entry limit") == true)
    }
  }

  func testOwnedHardLinkValidationHonorsExpiredDeadline() throws {
    let fixture = try GitFinalizationStoreFixture()
    let key = String(repeating: "i", count: 64)
    let destination = try fixture.store.writePreparedIndex(Data("prepared".utf8), journalKey: key)
    let temporaryDirectory = fixture.root.appendingPathComponent("tmp")
    let ownedLink = temporaryDirectory.appendingPathComponent("owned-crash-link")
    guard link(destination.path, ownedLink.path) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    XCTAssertThrowsError(try GitCommandRuntimeContext.$deadline.withValue(.distantPast) {
      try boundedGitFinalizationRecordData(
        from: destination,
        maxBytes: 64 * 1024 * 1024,
        ownedHardLinkDirectory: temporaryDirectory
      )
    }) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .timeout)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("workflow deadline") == true)
    }
  }

  func testCreateOnlyCollisionRejectsFIFOWithoutBlocking() throws {
    let fixture = try GitFinalizationStoreFixture()
    let key = String(repeating: "a", count: 64)
    let destination = fixture.store.preparedURL(for: key)
    guard mkfifo(destination.path, 0o600) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    let startedAt = Date()

    XCTAssertThrowsError(try fixture.store.writePreparedIndex(Data("prepared".utf8), journalKey: key)) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("collision") == true)
    }
    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
  }

  func testJournalRecoveryRejectsSymlinkToMatchingRecord() throws {
    let fixture = try GitFinalizationStoreFixture()
    let journal = try fixture.writeJournal(key: String(repeating: "b", count: 64), executionID: "commit")
    let journalURL = fixture.root.appendingPathComponent("journals/\(journal.journalKey).json")
    let targetURL = fixture.root.appendingPathComponent("matching-journal.json")
    try FileManager.default.copyItem(at: journalURL, to: targetURL)
    try FileManager.default.removeItem(at: journalURL)
    try FileManager.default.createSymbolicLink(at: journalURL, withDestinationURL: targetURL)

    XCTAssertThrowsError(try fixture.store.loadJournal(predecessorStepExecutionId: "commit")) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("regular file") == true)
    }
  }

  func testPreparedIndexRecoveryRejectsOversizedSparseFile() throws {
    let fixture = try GitFinalizationStoreFixture()
    let journal = try fixture.writeJournal(key: String(repeating: "c", count: 64), executionID: "commit")
    let preparedURL = fixture.store.preparedURL(for: journal.journalKey)
    try FileManager.default.removeItem(at: preparedURL)
    XCTAssertTrue(FileManager.default.createFile(atPath: preparedURL.path, contents: Data()))
    guard truncate(preparedURL.path, 64 * 1024 * 1024 + 1) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    XCTAssertThrowsError(try fixture.store.preparedIndexData(for: journal)) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("bounded") == true)
    }
  }

  func testPreparedIndexRecoveryRejectsForeignHardLink() throws {
    let fixture = try GitFinalizationStoreFixture()
    let journal = try fixture.writeJournal(key: String(repeating: "f", count: 64), executionID: "commit")
    let preparedURL = fixture.store.preparedURL(for: journal.journalKey)
    let foreignURL = fixture.root.appendingPathComponent("foreign-hard-link")
    guard link(preparedURL.path, foreignURL.path) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    XCTAssertThrowsError(try fixture.store.preparedIndexData(for: journal)) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("unowned hard link") == true)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: foreignURL.path))
  }

  func testPredecessorLinkReplacementDuringReadFailsClosed() throws {
    let fixture = try GitFinalizationStoreFixture()
    let journal = try fixture.writeJournal(key: String(repeating: "d", count: 64), executionID: "commit")
    let linkName = sha256(Data(journal.stepExecutionId.utf8)) + ".json"
    let linkURL = fixture.root.appendingPathComponent("links/\(linkName)")
    let displacedURL = fixture.root.appendingPathComponent("displaced-link.json")
    let replacementURL = fixture.root.appendingPathComponent("replacement-link.json")
    try Data("replacement".utf8).write(to: replacementURL)

    XCTAssertThrowsError(try boundedGitFinalizationRecordData(
      from: linkURL,
      maxBytes: 8 * 1024,
      afterOpen: {
        try FileManager.default.moveItem(at: linkURL, to: displacedURL)
        try FileManager.default.moveItem(at: replacementURL, to: linkURL)
      }
    )) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("changed") == true)
    }
  }
}
