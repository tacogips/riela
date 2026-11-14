import Foundation
import RielaCore

/// A snapshot object is reconstructed by concatenating chunks in listed order.
/// These are content references, not patches in either version direction.
struct WorkflowSnapshotChunkList: Codable {
  enum Format: String, Codable { case sha256Chunks = "sha256-chunks-v1" }
  let format: Format
  let byteCount: Int
  let chunks: [String]
}

struct WorkflowSnapshotChunks {
  let root: URL

  func encode(_ bytes: Data, pinnedRoot: WorkflowHistoryPinnedRoot) throws -> Data {
    var digests: [String] = []
    for chunk in Self.split(bytes) {
      let digest = WorkflowHistoryCanonicalCoding.sha256(chunk)
      try publish(chunk, digest: digest, pinnedRoot: pinnedRoot)
      digests.append(digest)
    }
    return try WorkflowHistoryCanonicalCoding.encode(
      WorkflowSnapshotChunkList(format: .sha256Chunks, byteCount: bytes.count, chunks: digests)
    )
  }

  func decode(_ encoded: Data, expectedDigest: String) throws -> Data {
    let list = try WorkflowHistoryCanonicalCoding.decode(WorkflowSnapshotChunkList.self, from: encoded)
    guard list.byteCount >= 0, list.chunks.count <= list.byteCount / Self.minimumChunkSize + 1 else {
      throw CLIUsageError("snapshot chunk list has invalid lengths")
    }
    let pinned = try WorkflowHistoryPinnedRoot(root, create: false)
    var result = Data()
    for (index, digest) in list.chunks.enumerated() {
      try WorkflowHistoryCanonicalCoding.validateDigest(digest)
      let bytes = try pinned.readRegular(chunkDirectory(digest).appendingPathComponent("data"), requireNonWritable: true)
      guard !bytes.isEmpty, bytes.count <= Self.maximumChunkSize,
        index == list.chunks.count - 1 || bytes.count >= Self.minimumChunkSize,
        bytes.count <= list.byteCount - result.count,
        WorkflowHistoryCanonicalCoding.sha256(bytes) == digest else {
        throw WorkflowHistoryValidationError.integrityMismatch
      }
      result.append(bytes)
    }
    guard result.count == list.byteCount, WorkflowHistoryCanonicalCoding.sha256(result) == expectedDigest else {
      throw WorkflowHistoryValidationError.integrityMismatch
    }
    return result
  }

  private func publish(_ bytes: Data, digest: String, pinnedRoot: WorkflowHistoryPinnedRoot) throws {
    let destination = chunkDirectory(digest)
    // A present chunk must be immutable and byte-identical. Never repair an
    // existing corrupt chunk silently; old versions may depend on that object.
    if FileManager.default.fileExists(atPath: destination.path) {
      guard try pinnedRoot.readRegular(destination.appendingPathComponent("data"), requireNonWritable: true) == bytes else {
        throw WorkflowHistoryValidationError.integrityMismatch
      }
      return
    }
    let artifact = try WorkflowHistoryPrivateDirectory(parent: destination.deletingLastPathComponent(), pinnedRoot: pinnedRoot)
    do {
      try artifact.write(bytes, to: "data")
      try artifact.syncAndMakeImmutable()
      do {
        try artifact.publish(to: destination, pinnedRoot: pinnedRoot)
      } catch {
        // Concurrent creators may publish the same hash. Accept only the exact
        // immutable value, resolving every path component through descriptors.
        guard try pinnedRoot.readRegular(destination.appendingPathComponent("data"), requireNonWritable: true) == bytes else {
          throw error
        }
      }
    } catch {
      try? artifact.remove()
      throw error
    }
  }

  private func chunkDirectory(_ digest: String) -> URL {
    root.appendingPathComponent("chunks/sha256/\(digest.prefix(2))/\(digest)", isDirectory: true)
  }

  static let minimumChunkSize = 2_048
  static let maximumChunkSize = 16_384

  /// Content-defined boundaries resynchronize after insertions. The rolling
  /// value is only a boundary selector; SHA-256 owns all content identity.
  private static func split(_ bytes: Data) -> [Data] {
    var result: [Data] = []
    var chunk = Data()
    var rolling: UInt64 = 0
    for byte in bytes {
      chunk.append(byte)
      rolling = (rolling << 1) &+ gear[Int(byte)]
      if chunk.count >= minimumChunkSize && (rolling & 0x1fff == 0 || chunk.count == maximumChunkSize) {
        result.append(chunk)
        chunk = Data()
        rolling = 0
      }
    }
    if !chunk.isEmpty { result.append(chunk) }
    return result
  }

  private static let gear: [UInt64] = (0..<256).map { value in
    var mixed = UInt64(value) &+ 0x9e3779b97f4a7c15
    mixed = (mixed ^ (mixed >> 30)) &* 0xbf58476d1ce4e5b9
    mixed = (mixed ^ (mixed >> 27)) &* 0x94d049bb133111eb
    return mixed ^ (mixed >> 31)
  }
}
