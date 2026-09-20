import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Called under the store lock. The temporary inode is private from creation,
/// and data reaches the filesystem before atomic publication of the snapshot.
enum DistributedSnapshotWriter {
  static func write(_ data: Data, to destination: URL) throws {
    let directory = destination.deletingLastPathComponent()
    var template = Array(directory.appendingPathComponent(".distributed-snapshot-XXXXXX").path.utf8CString)
    let descriptor = mkstemp(&template)
    guard descriptor >= 0 else { throw DistributedWorkerError.storeUnavailable }
    guard let temporary = String(bytes: template.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, encoding: .utf8) else {
      close(descriptor)
      template.withUnsafeBufferPointer { buffer in
        if let path = buffer.baseAddress { _ = unlink(path) }
      }
      throw DistributedWorkerError.storeUnavailable
    }
    defer {
      close(descriptor)
      unlink(temporary)
    }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        guard let baseAddress = bytes.baseAddress else { throw DistributedWorkerError.storeUnavailable }
        #if os(Linux)
        let count = Glibc.write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
        #else
        let count = Darwin.write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
        #endif
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw DistributedWorkerError.storeUnavailable }
        offset += count
      }
    }
    guard fsync(descriptor) == 0, rename(temporary, destination.path) == 0 else {
      throw DistributedWorkerError.storeUnavailable
    }
    let directoryDescriptor = open(directory.path, O_RDONLY | O_CLOEXEC)
    guard directoryDescriptor >= 0 else { throw DistributedWorkerError.storeUnavailable }
    defer { close(directoryDescriptor) }
    guard fsync(directoryDescriptor) == 0 else { throw DistributedWorkerError.storeUnavailable }
  }
}
