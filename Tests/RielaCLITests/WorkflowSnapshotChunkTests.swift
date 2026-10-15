import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class WorkflowSnapshotChunkTests: XCTestCase {
  func testPagingDoesNotReconstructBodiesOutsideRequestedPage() throws {
    let root = try scratchRoot()
    defer { removeWorkflowVersioningTestDirectory(root) }
    let store = WorkflowHistoryStore(root: root.appendingPathComponent("history"))
    let old = try store.createSnapshot(inventory: inventory(root: root, bytes: Data("old".utf8)),
      snapshotId: "old", now: Date(timeIntervalSince1970: 1))
    let new = try store.createSnapshot(inventory: inventory(root: root, bytes: Data("new".utf8)),
      snapshotId: "new", now: Date(timeIntervalSince1970: 2))
    XCTAssertEqual(try store.list(expectedIdentity: old.target, limit: 1).map(\.snapshotId), ["new"])
    XCTAssertEqual(try store.list(expectedIdentity: old.target, limit: 1, beforeSnapshotId: "new").map(\.snapshotId), ["old"])
    XCTAssertThrowsError(try store.list(expectedIdentity: old.target, limit: 0))
    XCTAssertThrowsError(try store.list(expectedIdentity: old.target, beforeSnapshotId: "unknown"))
    let digest = old.files[0].contentDigest
    let chunk = store.root.appendingPathComponent("chunks/sha256/\(digest.prefix(2))/\(digest)/data")
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: chunk.path)
    try Data("corrupt".utf8).write(to: chunk)
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: chunk.path)
    let page = try store.list(expectedIdentity: new.target, limit: 1)
    XCTAssertTrue(try XCTUnwrap(page.first).integrityVerified)
    XCTAssertThrowsError(try store.list(expectedIdentity: old.target, limit: 1, beforeSnapshotId: "new"))
  }

  func testSharedChunksReconstructEditedPromptWithoutFullCopies() throws {
    let root = try scratchRoot()
    defer { removeWorkflowVersioningTestDirectory(root) }
    let store = WorkflowHistoryStore(root: root.appendingPathComponent("history"))
    var bytes = Data((0..<60_000).flatMap { Array("prompt line \($0) 記憶\n".utf8) })
    let original = bytes
    let first = try store.createSnapshot(inventory: inventory(root: root, bytes: bytes), snapshotId: "first")
    let initialSize = try storedSize(store.root)
    bytes.insert(contentsOf: Data("a new instruction\n".utf8), at: 80_000)
    let second = try store.createSnapshot(inventory: inventory(root: root, bytes: bytes), snapshotId: "second")
    XCTAssertEqual(second.schemaVersion, 2)
    XCTAssertEqual(second.storageFormat, .sharedChunks)
    XCTAssertLessThan(try storedSize(store.root) - initialSize, original.count / 4)
    let oldDigest = try XCTUnwrap(first.files.first?.contentDigest)
    let newDigest = try XCTUnwrap(second.files.first?.contentDigest)
    XCTAssertEqual(try store.objectBytes(digest: oldDigest, snapshotId: "first"), original)
    XCTAssertEqual(try store.objectBytes(digest: newDigest, snapshotId: "second"), bytes)
    let staging = root.appendingPathComponent("restored")
    try store.restoreSnapshot(first, to: staging)
    XCTAssertEqual(try Data(contentsOf: staging.appendingPathComponent("prompt.txt")), original)
    XCTAssertEqual(try store.list(expectedIdentity: first.target).count, 2)
  }

  func testEmptyBinaryAndCorruptOrMissingChunk() throws {
    let root = try scratchRoot()
    defer { removeWorkflowVersioningTestDirectory(root) }
    let store = WorkflowHistoryStore(root: root.appendingPathComponent("history"))
    let empty = try store.createSnapshot(inventory: inventory(root: root, bytes: Data()), snapshotId: "empty")
    XCTAssertEqual(try store.objectBytes(digest: empty.files[0].contentDigest, snapshotId: "empty"), Data())
    let bytes = Data([0, 255, 128, 0, 10])
    let binary = try store.createSnapshot(inventory: inventory(root: root, bytes: bytes), snapshotId: "binary")
    XCTAssertEqual(try store.objectBytes(digest: binary.files[0].contentDigest, snapshotId: "binary"), bytes)
    let digest = WorkflowHistoryCanonicalCoding.sha256(bytes)
    let chunk = store.root.appendingPathComponent("chunks/sha256/\(digest.prefix(2))/\(digest)/data")
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: chunk.path)
    try Data([1, 2, 3]).write(to: chunk)
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: chunk.path)
    XCTAssertThrowsError(try store.loadSnapshot("binary", expectedIdentity: binary.target))
    XCTAssertThrowsError(try store.createSnapshot(inventory: inventory(root: root, bytes: bytes), snapshotId: "corrupt-reuse"))
  }

  func testLegacyRawSnapshotRemainsReadable() throws {
    let root = try scratchRoot()
    defer { removeWorkflowVersioningTestDirectory(root) }
    let history = root.appendingPathComponent("history")
    let pinned = try WorkflowHistoryPinnedRoot(history)
    let bytes = Data("legacy prompt".utf8)
    let inventory = try inventory(root: root, bytes: bytes)
    let digest = inventory.files[0].metadata.contentDigest
    let manifest = WorkflowBundleSnapshotManifest(snapshotId: "legacy", target: inventory.target,
      createdAt: Date(timeIntervalSince1970: 1), bundleDigest: inventory.bundleDigest, files: inventory.files.map(\.metadata))
    let artifact = try WorkflowHistoryPrivateDirectory(parent: history.appendingPathComponent("snapshots"), pinnedRoot: pinned)
    try artifact.write(bytes, to: "objects/sha256/\(digest.prefix(2))/\(digest)")
    let encoded = try WorkflowHistoryCanonicalCoding.encode(manifest)
    try artifact.write(encoded, to: "manifest.json")
    try artifact.write(Data("\(WorkflowHistoryCanonicalCoding.sha256(encoded))\n".utf8), to: "manifest.sha256")
    try artifact.syncAndMakeImmutable()
    try artifact.publish(to: history.appendingPathComponent("snapshots/legacy"), pinnedRoot: pinned)
    let store = WorkflowHistoryStore(root: history)
    XCTAssertEqual(try store.loadSnapshot("legacy", expectedIdentity: inventory.target), manifest)
    XCTAssertEqual(try store.objectBytes(digest: digest, snapshotId: "legacy"), bytes)
  }

  private func scratchRoot() throws -> URL {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("tmp/evolution-history/chunks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func inventory(root: URL, bytes: Data) throws -> WorkflowBundleInventory {
    let source = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let url = source.appendingPathComponent("prompt.txt")
    try bytes.write(to: url)
    let target = WorkflowBundleIdentity(workflowId: "evolving", sourceScope: .project, sourceKind: .authoredWorkflow,
      workflowDirectory: source.path, ownershipRoot: source.path, sourceMutable: true)
    let file = WorkflowBundleSnapshotFile(relativePath: "prompt.txt", contentDigest: WorkflowHistoryCanonicalCoding.sha256(bytes),
      byteCount: bytes.count, artifactKind: .prompt, executable: false)
    return WorkflowBundleInventory(target: target, files: [WorkflowOwnedFile(metadata: file, url: url, bytes: bytes)],
      bundleDigest: try WorkflowHistoryCanonicalCoding.bundleDigest(target: target, files: [file]))
  }

  private func storedSize(_ root: URL) throws -> Int {
    let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]))
    return try enumerator.compactMap { $0 as? URL }.reduce(0) { total, url in
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      return total + (values.isRegularFile == true ? values.fileSize ?? 0 : 0)
    }
  }
}
