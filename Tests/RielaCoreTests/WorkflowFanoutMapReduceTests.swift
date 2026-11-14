import Foundation
import XCTest
@testable import RielaCore

final class WorkflowFanoutMapReduceTests: XCTestCase {
  func testDependencyWavesPreserveInputIndicesAndRequireAcceptedDependencies() throws {
    let items: [JSONValue] = [item("c", ["a", "b"]), item("a"), item("b")]
    let policy = WorkflowFanoutDependencies(branchIdFrom: "/id", dependsOnFrom: "/dependsOn", completedBranchIdsFrom: "/accepted")
    let first = try WorkflowFanoutWave.select(items: items, policy: policy, source: ["accepted": .array([])])
    XCTAssertEqual(first.selectedIndices, [1, 2])
    let next = try WorkflowFanoutWave.select(items: items, policy: policy, source: ["accepted": .array([.string("a"), .string("b")])])
    XCTAssertEqual(next.selectedIndices, [0])
    XCTAssertEqual(next.pendingBranchIds, ["c"])
    XCTAssertThrowsError(try WorkflowFanoutWave.select(items: items, policy: policy, source: ["accepted": .array([.string("c")])]))
    XCTAssertThrowsError(try WorkflowFanoutWave.select(items: [item("a", ["b"]), item("b", ["a"])], policy: policy, source: ["accepted": .array([])]))
    XCTAssertThrowsError(try WorkflowFanoutWave.select(items: [item("a"), item("a")], policy: policy, source: ["accepted": .array([])]))
    XCTAssertThrowsError(try WorkflowFanoutWave.select(items: [item("a", ["missing"])], policy: policy, source: ["accepted": .array([])]))
  }

  func testChangeEvidencePreservesOverwrittenBytesAndReportsDrift() async throws {
    let root = try scratch()
    let path = root.appendingPathComponent("shared.txt")
    try Data("feature A".utf8).write(to: path)
    let evidence = try WorkflowFanoutChangeEvidence(root: root)
    let saved = try await evidence.capture(branchId: "a", paths: ["shared.txt", "new.txt"], stepId: "after:implement")
    try Data("feature B".utf8).write(to: path)
    try Data("new file".utf8).write(to: root.appendingPathComponent("new.txt"))
    let reduced = try await evidence.reduce()
    XCTAssertEqual(reduced["hasDrift"], .bool(true))
    XCTAssertEqual(reduced["requiresSemanticReview"], .bool(true))
    let stored = try JSONDecoder().decode(JSONObject.self, from: Data(contentsOf: URL(fileURLWithPath: saved)))
    XCTAssertEqual(fanoutJSONPointer(.object(stored), "/files/shared.txt/contentBase64"), .string(Data("feature A".utf8).base64EncodedString()))
    let another = try await evidence.capture(branchId: "a", paths: ["shared.txt"], stepId: "after:repair")
    XCTAssertNotEqual(saved, another)
    XCTAssertEqual(try Data(contentsOf: path), Data("feature B".utf8))
  }

  func testTrackingRejectsTraversalAndSymlinksWithoutWritingSource() async throws {
    let root = try scratch()
    let evidence = try WorkflowFanoutChangeEvidence(root: root)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: root.deletingLastPathComponent())
    for path in ["../outside", ".git/config", "escape/file"] {
      do {
        _ = try await evidence.capture(branchId: "a", paths: [path], stepId: "before")
        XCTFail("accepted unsafe path: \(path)")
      } catch { XCTAssertTrue(error is AdapterExecutionError) }
    }
  }

  func testDirectoryCaptureRetainsRootsHiddenEntriesAndOverlappingBytes() async throws {
    let root = try scratch()
    try FileManager.default.createDirectory(at: root.appendingPathComponent("tree/empty"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("tree/nested"), withIntermediateDirectories: true)
    try Data("visible".utf8).write(to: root.appendingPathComponent("tree/file"))
    try Data("hidden".utf8).write(to: root.appendingPathComponent("tree/.hidden"))
    try Data("deep".utf8).write(to: root.appendingPathComponent("tree/nested/deep"))
    let evidence = try WorkflowFanoutChangeEvidence(root: root)
    let saved = try await evidence.capture(branchId: "a", paths: ["tree/file", "tree", "tree"], stepId: "before")
    let stored = try readRecord(saved)
    XCTAssertEqual(stored["roots"], .array([.string("tree"), .string("tree/file")]))
    guard case let .object(files)? = stored["files"] else { return XCTFail("missing entries") }
    XCTAssertEqual(Set(files.keys), ["tree", "tree/file", "tree/.hidden", "tree/empty", "tree/nested", "tree/nested/deep"])
    XCTAssertEqual(fanoutJSONPointer(.object(stored), "/files/tree/children"),
                   .array([.string(".hidden"), .string("empty"), .string("file"), .string("nested")]))
    XCTAssertEqual(entryField(files["tree/empty"], "children"), .array([]))
    XCTAssertEqual(entryField(files["tree/nested"], "children"), .array([.string("deep")]))
    XCTAssertEqual(entryField(files["tree/file"], "contentBase64"), .string(Data("visible".utf8).base64EncodedString()))
    XCTAssertEqual(entryField(files["tree/nested/deep"], "contentBase64"), .string(Data("deep".utf8).base64EncodedString()))
    let reduced = try await evidence.reduce()
    XCTAssertEqual(reduced["hasDrift"], .bool(false))
    try Data("changed".utf8).write(to: root.appendingPathComponent("tree/nested/deep"))
    assertObservation(try await evidence.reduce(), branch: "a", path: "tree/nested/deep", reason: "content-or-mode-drift")
  }

  func testDirectoryMembershipAddRemoveAndImmutableEvidence() async throws {
    let root = try scratch()
    let folder = root.appendingPathComponent("tree")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: folder.appendingPathComponent("removed"))
    let evidence = try WorkflowFanoutChangeEvidence(root: root)
    let saved = try await evidence.capture(branchId: "a", paths: ["tree"], stepId: "before")
    try FileManager.default.removeItem(at: folder.appendingPathComponent("removed"))
    try Data("new".utf8).write(to: folder.appendingPathComponent("added"))
    let reduced = try await evidence.reduce()
    assertObservation(reduced, branch: "a", path: "tree", reason: "directory-membership-drift")
    assertObservation(reduced, branch: "a", path: "tree/added", reason: "entry-added")
    assertObservation(reduced, branch: "a", path: "tree/removed", reason: "entry-removed")
    XCTAssertFalse(String(data: try JSONEncoder().encode(reduced), encoding: .utf8)?.contains("contentBase64") ?? true)
    guard case let .object(savedFiles)? = try readRecord(saved)["files"] else { return XCTFail("missing saved files") }
    XCTAssertEqual(entryField(savedFiles["tree/removed"], "contentBase64"), .string(Data("old".utf8).base64EncodedString()))
    try FileManager.default.removeItem(at: folder)
    let removed = try await evidence.reduce()
    assertObservation(removed, branch: "a", path: "tree", reason: "entry-removed")
    assertObservation(removed, branch: "a", path: "tree/removed", reason: "entry-removed")
  }

  func testEmptyDirectoryMembershipBecomesVisible() async throws {
    let root = try scratch()
    try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
    let evidence = try WorkflowFanoutChangeEvidence(root: root)
    _ = try await evidence.capture(branchId: "empty", paths: ["empty"], stepId: "before")
    try Data().write(to: root.appendingPathComponent("empty/new"))
    let reduced = try await evidence.reduce()
    assertObservation(reduced, branch: "empty", path: "empty", reason: "directory-membership-drift")
    assertObservation(reduced, branch: "empty", path: "empty/new", reason: "entry-added")
  }

  func testMissingRootsAndEntryKindReplacement() async throws {
    let root = try scratch()
    let evidence = try WorkflowFanoutChangeEvidence(root: root)
    _ = try await evidence.capture(branchId: "missing", paths: ["newFile", "newDir"], stepId: "before")
    try Data("file".utf8).write(to: root.appendingPathComponent("newFile"))
    try FileManager.default.createDirectory(at: root.appendingPathComponent("newDir"), withIntermediateDirectories: true)
    try Data("child".utf8).write(to: root.appendingPathComponent("newDir/child"))
    let added = try await evidence.reduce()
    assertObservation(added, branch: "missing", path: "newFile", reason: "entry-added")
    assertObservation(added, branch: "missing", path: "newDir", reason: "entry-added")
    assertObservation(added, branch: "missing", path: "newDir/child", reason: "entry-added")
    _ = try await evidence.capture(branchId: "replacement", paths: ["newFile", "newDir"], stepId: "before")
    try FileManager.default.removeItem(at: root.appendingPathComponent("newFile"))
    try FileManager.default.createDirectory(at: root.appendingPathComponent("newFile"), withIntermediateDirectories: true)
    try FileManager.default.removeItem(at: root.appendingPathComponent("newDir"))
    try Data("replacement".utf8).write(to: root.appendingPathComponent("newDir"))
    let replaced = try await evidence.reduce()
    assertObservation(replaced, branch: "replacement", path: "newFile", reason: "entry-kind-drift")
    assertObservation(replaced, branch: "replacement", path: "newDir", reason: "entry-kind-drift")
    assertObservation(replaced, branch: "replacement", path: "newDir/child", reason: "entry-removed")
  }

  func testTwoWavesCaptureFreshDirectoryAndAttributeDrift() async throws {
    let root = try scratch()
    let items: [JSONValue] = [item("a"), item("b", ["a"])]
    let policy = WorkflowFanoutDependencies(branchIdFrom: "/id", dependsOnFrom: "/dependsOn", completedBranchIdsFrom: "/accepted")
    let first = try WorkflowFanoutWave.select(items: items, policy: policy, source: ["accepted": .array([])])
    XCTAssertEqual(first.selectedIndices, [0])
    let waveOne = try WorkflowFanoutChangeEvidence(root: root)
    _ = try await waveOne.capture(branchId: "a", paths: ["output"], stepId: "before")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("output"), withIntermediateDirectories: true)
    try Data("first".utf8).write(to: root.appendingPathComponent("output/file"))
    assertObservation(try await waveOne.reduce(), branch: "a", path: "output/file", reason: "entry-added")
    let second = try WorkflowFanoutWave.select(items: items, policy: policy, source: ["accepted": .array([.string("a")])])
    XCTAssertEqual(second.selectedIndices, [1])
    let waveTwo = try WorkflowFanoutChangeEvidence(root: root)
    _ = try await waveTwo.capture(branchId: "b", paths: ["output"], stepId: "before")
    try Data("second".utf8).write(to: root.appendingPathComponent("output/file"))
    let reduced = try await waveTwo.reduce()
    assertObservation(reduced, branch: "b", path: "output/file", reason: "content-or-mode-drift")
  }

  func testUnsafeDiscoveredEntriesAndEvidenceRecursion() async throws {
    let root = try scratch()
    let evidence = try WorkflowFanoutChangeEvidence(root: root)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("tree"), withIntermediateDirectories: true)
    let tree = root.appendingPathComponent("tree")
    for path in ["", "/absolute", "a/../b", "a//b", "a/./b", "a/.git/b", "tree", "tmp"] {
      if path == "tree" {
        try FileManager.default.createSymbolicLink(at: tree.appendingPathComponent("dangling"), withDestinationURL: root.appendingPathComponent("absent"))
      }
      await assertCaptureRejected(evidence, paths: [path])
    }
    try FileManager.default.removeItem(at: tree.appendingPathComponent("dangling"))
    try FileManager.default.createDirectory(at: tree.appendingPathComponent(".git"), withIntermediateDirectories: true)
    await assertCaptureRejected(evidence, paths: ["tree"])
    try FileManager.default.removeItem(at: tree.appendingPathComponent(".git"))
    XCTAssertEqual(mkfifo(tree.appendingPathComponent("pipe").path, 0o600), 0)
    await assertCaptureRejected(evidence, paths: ["tree"])
    try FileManager.default.removeItem(at: tree.appendingPathComponent("pipe"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("direct"), withDestinationURL: tree)
    await assertCaptureRejected(evidence, paths: ["direct"])
  }

  func testDeterministicMutationAndEnumerationFailureDoNotPublish() async throws {
    let root = try scratch()
    try FileManager.default.createDirectory(at: root.appendingPathComponent("tree"), withIntermediateDirectories: true)
    try Data("one".utf8).write(to: root.appendingPathComponent("tree/file"))
    let evidence = try WorkflowFanoutChangeEvidence(root: root)
    await evidence.setObservationHook { marker in
      if marker == "file:tree/file" { try Data("two".utf8).write(to: root.appendingPathComponent("tree/file")) }
    }
    await assertCaptureRejected(evidence, paths: ["tree"], expectedCode: .providerError, retryable: true)
    await evidence.setObservationHook { marker in
      if marker == "directory:tree" { try Data("new".utf8).write(to: root.appendingPathComponent("tree/added")) }
    }
    await assertCaptureRejected(evidence, paths: ["tree"], expectedCode: .providerError, retryable: true)
    await evidence.setObservationHook { marker in
      if marker == "directory:tree" { throw NSError(domain: "InjectedEnumerationFailure", code: 1) }
    }
    await assertCaptureRejected(evidence, paths: ["tree"])
    let evidenceDirectory = await evidence.directory
    let artifacts = try FileManager.default.contentsOfDirectory(atPath: evidenceDirectory.path)
    XCTAssertTrue(artifacts.isEmpty)
  }

  func testAncestorSymlinkReplacementAfterObservationDoesNotPublish() async throws {
    for (path, marker) in [("tree/file", "file:tree/file"), ("tree", "directory:tree")] {
      let root = try scratch()
      let tree = root.appendingPathComponent("tree")
      try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
      if path == "tree/file" { try Data("same".utf8).write(to: tree.appendingPathComponent("file")) }
      let evidence = try WorkflowFanoutChangeEvidence(root: root)
      await evidence.setObservationHook { observed in
        guard observed == marker else { return }
        try FileManager.default.moveItem(at: tree, to: root.appendingPathComponent("moved"))
        try FileManager.default.createSymbolicLink(at: tree, withDestinationURL: root.appendingPathComponent("moved"))
      }
      await assertCaptureRejected(evidence, paths: [path], expectedCode: .policyBlocked)
      let evidenceDirectory = await evidence.directory
      XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: evidenceDirectory.path).isEmpty)
    }
  }

  func testModeDriftAndUnsafeReduceGrowth() async throws {
    let root = try scratch()
    let folder = root.appendingPathComponent("tree")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("file")
    try Data("same".utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let evidence = try WorkflowFanoutChangeEvidence(root: root)
    _ = try await evidence.capture(branchId: "mode", paths: ["tree"], stepId: "before")
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    assertObservation(try await evidence.reduce(), branch: "mode", path: "tree/file", reason: "content-or-mode-drift")
    try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("unsafe"),
                                               withDestinationURL: root.appendingPathComponent("absent"))
    do {
      _ = try await evidence.reduce()
      XCTFail("accepted unsafe reduce growth")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
    }
  }

  func testUnreadableFileAndDirectoryAreRejected() async throws {
    let root = try scratch()
    let folder = root.appendingPathComponent("unreadable")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("file")
    try Data("bytes".utf8).write(to: file)
    let evidence = try WorkflowFanoutChangeEvidence(root: root)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
    await assertCaptureRejected(evidence, paths: ["unreadable"], expectedCode: .policyBlocked)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
    await assertCaptureRejected(evidence, paths: ["unreadable"], expectedCode: .policyBlocked)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
  }

  func testAggregateByteLimitInclusiveAndExceeded() async throws {
    let root = try scratch()
    let folder = root.appendingPathComponent("bytes")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let block = Data(count: 8_000_000)
    for index in 0..<8 { try block.write(to: folder.appendingPathComponent("file\(index)")) }
    let evidence = try WorkflowFanoutChangeEvidence(root: root)
    _ = try await evidence.capture(branchId: "bytes", paths: ["bytes"], stepId: "before")
    try Data([1]).write(to: folder.appendingPathComponent("overflow"))
    await assertCaptureRejected(evidence, paths: ["bytes"], expectedCode: .policyBlocked)
    do {
      _ = try await evidence.reduce()
      XCTFail("accepted 64,000,001 bytes at reduce")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
    }
  }

  func testDeclaredExpandedAndByteLimitsAtCaptureAndReduce() async throws {
    let root = try scratch()
    let evidence = try WorkflowFanoutChangeEvidence(root: root)
    let declared = (0..<512).map { "missing\($0)" }
    _ = try await evidence.capture(branchId: "limits", paths: declared, stepId: "before")
    await assertCaptureRejected(evidence, paths: declared + ["extra"])
    let folder = root.appendingPathComponent("many")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for index in 0..<511 { try Data().write(to: folder.appendingPathComponent("f\(index)")) }
    _ = try await evidence.capture(branchId: "limits", paths: ["many"], stepId: "before")
    try Data().write(to: folder.appendingPathComponent("overflow"))
    do {
      _ = try await evidence.reduce()
      XCTFail("accepted over-limit reduce growth")
    } catch { }
    await assertCaptureRejected(evidence, paths: ["many"])
    try FileManager.default.removeItem(at: folder.appendingPathComponent("overflow"))
    let large = root.appendingPathComponent("large")
    try Data(count: 8_000_000).write(to: large)
    _ = try await evidence.capture(branchId: "limits", paths: ["large"], stepId: "before")
    try Data(count: 8_000_001).write(to: large)
    await assertCaptureRejected(evidence, paths: ["large"])
    do {
      _ = try await evidence.reduce()
      XCTFail("accepted per-file limit growth at reduce")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
    }
  }

  func testSixtyPathFourHundredSevenFileScaleFixture() async throws {
    let root = try scratch()
    let paths = (0..<60).map { "package/dir\($0)" }
    for (index, path) in paths.enumerated() {
      let folder = root.appendingPathComponent(path)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      for file in 0..<(index < 47 ? 7 : 6) { try Data("x".utf8).write(to: folder.appendingPathComponent("file\(file)")) }
    }
    let waveOne = try WorkflowFanoutChangeEvidence(root: root)
    let saved = try await waveOne.capture(branchId: "a", paths: paths, stepId: "wave-one")
    guard case let .object(files)? = try readRecord(saved)["files"] else { return XCTFail("missing fixture") }
    XCTAssertEqual(paths.count, 60)
    XCTAssertEqual(files.count, 467)
    XCTAssertEqual(files.values.filter { entryKindForTest($0) == "file" }.count, 407)
    let waveTwo = try WorkflowFanoutChangeEvidence(root: root)
    _ = try await waveTwo.capture(branchId: "b", paths: paths, stepId: "wave-two")
    try FileManager.default.removeItem(at: root.appendingPathComponent("package/dir0/file0"))
    try Data("new".utf8).write(to: root.appendingPathComponent("package/dir0/new"))
    let reduced = try await waveTwo.reduce()
    assertObservation(reduced, branch: "b", path: "package/dir0", reason: "directory-membership-drift")
    assertObservation(reduced, branch: "b", path: "package/dir0/file0", reason: "entry-removed")
    assertObservation(reduced, branch: "b", path: "package/dir0/new", reason: "entry-added")
  }

  private func readRecord(_ path: String) throws -> JSONObject {
    try JSONDecoder().decode(JSONObject.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
  }

  private func assertObservation(_ reduced: JSONObject, branch: String, path: String, reason: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
    guard case let .array(observations)? = reduced["observations"] else { return XCTFail("missing observations", file: file, line: line) }
    XCTAssertTrue(observations.contains { value in
      guard case let .object(item) = value else { return false }
      return item["branchId"] == .string(branch) && item["path"] == .string(path) && item["reason"] == .string(reason)
    }, "missing \(branch):\(path):\(reason)", file: file, line: line)
  }

  private func assertCaptureRejected(_ evidence: WorkflowFanoutChangeEvidence, paths: [String],
                                     expectedCode: AdapterExecutionErrorCode? = nil, retryable: Bool? = nil,
                                     file: StaticString = #filePath, line: UInt = #line) async {
    do {
      _ = try await evidence.capture(branchId: "rejected", paths: paths, stepId: "before")
      XCTFail("accepted \(paths)", file: file, line: line)
    } catch {
      if let expectedCode {
        XCTAssertEqual((error as? AdapterExecutionError)?.code, expectedCode, file: file, line: line)
      }
      if let retryable {
        XCTAssertEqual((error as? AdapterExecutionError)?.isRetryable, retryable, file: file, line: line)
      }
    }
  }

  private func entryKindForTest(_ value: JSONValue) -> String? {
    guard case let .object(entry) = value, case let .string(kind)? = entry["kind"] else { return nil }
    return kind
  }

  private func entryField(_ value: JSONValue?, _ field: String) -> JSONValue? {
    guard case let .object(entry)? = value else { return nil }
    return entry[field]
  }

  private func item(_ id: String, _ dependencies: [String] = []) -> JSONValue {
    .object(["id": .string(id), "dependsOn": .array(dependencies.map(JSONValue.string))])
  }

  private func scratch() throws -> URL {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/fanout-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    return root
  }
}
