import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// `readdir` returns variable-length records. Taking a Swift value of
/// `d_name` copies its full imported tuple (1024 bytes on Darwin), which can
/// read beyond the record and even beyond the directory buffer's allocation.
/// Read only the bytes inside this record, without materializing that tuple.
package func posixDirectoryEntryName(_ entry: UnsafePointer<dirent>) throws -> String {
  guard let offset = MemoryLayout<dirent>.offset(of: \.d_name) else { throw POSIXError(.EIO) }
  let capacity = Int(entry.pointee.d_reclen) - offset
  guard capacity > 0 else { throw POSIXError(.EIO) }
  let start = UnsafeRawPointer(entry).advanced(by: offset)
  guard let end = memchr(start, 0, capacity) else { throw POSIXError(.EIO) }
  let bytes = UnsafeRawBufferPointer(start: start, count: start.distance(to: UnsafeRawPointer(end)))
  guard let name = String(bytes: bytes, encoding: .utf8) else { throw POSIXError(.EILSEQ) }
  return name
}
