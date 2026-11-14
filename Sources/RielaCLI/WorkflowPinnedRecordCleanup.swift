import Darwin
import Foundation
import RielaCore

/// Pins a record's parent once, validates the record/sidecar pair through that
/// descriptor, and unlinks both names without reopening an absolute path.
final class WorkflowPinnedRecordCleanup {
  private let parentDescriptor: Int32
  private let recordName: String
  private let sidecarName: String
  private let exists: Bool

  init(record: URL, historyRoot: URL) throws {
    let pinned = try WorkflowHistoryPinnedRoot(historyRoot, create: false)
    let relative = try pinned.relativePath(for: record)
    let parts = relative.split(separator: "/").map(String.init)
    guard let recordName = parts.last else {
      throw CLIUsageError("workflow history cleanup record name is required")
    }
    parentDescriptor = try pinned.openDirectory(parts.dropLast().joined(separator: "/"))
    self.recordName = recordName
    sidecarName = WorkflowHistorySecurePersistence.digestSidecar(for: record).lastPathComponent
    let recordExists = try Self.validateRegularIfPresent(recordName, parent: parentDescriptor)
    let sidecarExists = try Self.validateRegularIfPresent(sidecarName, parent: parentDescriptor)
    guard recordExists == sidecarExists else {
      _ = close(parentDescriptor)
      throw CLIUsageError("workflow history marker record and sidecar are incomplete")
    }
    exists = recordExists
  }

  deinit { _ = close(parentDescriptor) }

  func remove(
    beforeRecord: () throws -> Void,
    beforeSidecar: () throws -> Void
  ) throws {
    guard exists else { return }
    try beforeRecord()
    guard unlinkat(parentDescriptor, recordName, 0) == 0 else {
      throw CLIUsageError("unable to remove completed workflow history marker record")
    }
    try beforeSidecar()
    guard unlinkat(parentDescriptor, sidecarName, 0) == 0 else {
      throw CLIUsageError("unable to remove completed workflow history marker sidecar")
    }
    guard fsync(parentDescriptor) == 0 else {
      throw CLIUsageError("unable to fsync completed workflow history marker cleanup")
    }
  }

  private static func validateRegularIfPresent(_ name: String, parent: Int32) throws -> Bool {
    var status = stat()
    if fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW) != 0 {
      if errno == ENOENT { return false }
      throw CLIUsageError("unable to inspect workflow history marker")
    }
    guard status.st_mode & S_IFMT == S_IFREG else {
      throw CLIUsageError("workflow history marker is linked or has unexpected type")
    }
    return true
  }
}
