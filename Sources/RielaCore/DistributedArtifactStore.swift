import Foundation

/// Content-addressed controller files. Worker paths are manifest labels only;
/// they never choose a destination or overwrite a controller project file.
struct DistributedArtifactStore {
  let directory: URL

  func materialize(_ artifacts: [DistributedArtifact]) throws -> [DistributedArtifactLocation] {
    guard !artifacts.isEmpty else { return [] }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
    )
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw DistributedWorkerError.storeUnavailable }
    return try artifacts.map { artifact in
      guard artifact.sha256 == DistributedArtifact.digest(artifact.data) else {
        throw DistributedWorkerError.invalidJob
      }
      let destination = directory.appendingPathComponent(artifact.sha256)
      // Replace atomically, never follow a pre-existing final symlink. The
      // snapshot also retains the bounded bytes for recovery after file loss.
      try DistributedSnapshotWriter.write(artifact.data, to: destination)
      return DistributedArtifactLocation(path: artifact.path, url: destination, sha256: artifact.sha256, size: artifact.data.count)
    }
  }
}
