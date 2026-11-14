#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

#if canImport(Glibc)
@_silgen_name("renameat2")
private func linuxRenameAt2(
  _ oldDirectory: Int32,
  _ oldName: UnsafePointer<CChar>,
  _ newDirectory: Int32,
  _ newName: UnsafePointer<CChar>,
  _ flags: UInt32
) -> Int32
#endif

func workflowHistoryExclusiveRename(
  oldDirectory: Int32,
  oldName: UnsafePointer<CChar>,
  newDirectory: Int32,
  newName: UnsafePointer<CChar>
) -> Int32 {
  #if canImport(Darwin)
  renameatx_np(oldDirectory, oldName, newDirectory, newName, UInt32(RENAME_EXCL))
  #else
  linuxRenameAt2(oldDirectory, oldName, newDirectory, newName, 1)
  #endif
}

enum WorkflowHistoryExclusivePublication {
  static func publishDirectory(
    _ temporary: URL,
    to destination: URL,
    pinnedRoot: WorkflowHistoryPinnedRoot
  ) throws {
    try pinnedRoot.publishDirectory(temporary, to: destination)
  }
}
