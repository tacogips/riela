import Darwin
import Foundation

enum WorkflowHistoryExclusivePublication {
  static func publishDirectory(
    _ temporary: URL,
    to destination: URL,
    pinnedRoot: WorkflowHistoryPinnedRoot
  ) throws {
    try pinnedRoot.publishDirectory(temporary, to: destination)
  }
}
