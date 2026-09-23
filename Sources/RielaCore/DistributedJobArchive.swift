import Foundation

public struct DistributedStoreLimits: Sendable {
  var maximumJobs = 10_000
  var maximumActiveJobs = 32
  var retainedTerminalJobs = 16
  var maximumSnapshotBytes = 512 * 1024 * 1024
  var maximumArchiveBytes = 1024 * 1024 * 1024
  var maximumJobBytes = 5 * 1024 * 1024

  public init() {}
}

/// Immutable terminal records are loaded individually, never on every heartbeat.
struct DistributedJobArchive {
  struct Reference: Codable, Equatable {
    let digest: String
    let size: Int
  }

  let directory: URL
  let maximumJobBytes: Int

  func store(_ job: DistributedJob) throws -> Reference {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let bytes = try encoder.encode(job)
    guard bytes.count <= maximumJobBytes else { throw DistributedWorkerError.storeCapacityExceeded }
    let reference = Reference(digest: DistributedArtifact.digest(bytes), size: bytes.count)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try DistributedSnapshotWriter.write(bytes, to: directory.appendingPathComponent(reference.digest))
    return reference
  }

  func load(_ reference: Reference, jobId: String) throws -> DistributedJob {
    guard reference.digest.count == 64, reference.digest.allSatisfy({ $0.isHexDigit }),
      reference.size <= maximumJobBytes else { throw DistributedWorkerError.storeUnavailable }
    let bytes = try Self.read(directory.appendingPathComponent(reference.digest), maximumBytes: maximumJobBytes)
    guard bytes.count == reference.size, DistributedArtifact.digest(bytes) == reference.digest else {
      throw DistributedWorkerError.storeUnavailable
    }
    let job = try JSONDecoder().decode(DistributedJob.self, from: bytes)
    guard job.id == jobId else { throw DistributedWorkerError.storeUnavailable }
    return job
  }

  static func read(_ url: URL, maximumBytes: Int) throws -> Data {
    let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard attributes.isRegularFile == true else { throw DistributedWorkerError.storeUnavailable }
    let size = attributes.fileSize ?? 0
    guard size <= maximumBytes else { throw DistributedWorkerError.storeCapacityExceeded }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let bytes = try handle.read(upToCount: maximumBytes + 1) ?? Data()
    guard bytes.count <= maximumBytes else { throw DistributedWorkerError.storeCapacityExceeded }
    return bytes
  }
}
