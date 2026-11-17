import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Writes diagnostics to the process standard streams without ever raising.
///
/// `FileHandle.write(_:)` raises an Objective-C exception when the underlying
/// `write(2)` fails (for example `ENOSPC` on a full volume that backs a
/// redirected log, or `EPIPE`). An uncaught exception terminates the process
/// through `libc++abi`, so a long-lived host such as RielaApp could crash just
/// because its log volume filled up. Diagnostics are best effort: failures are
/// dropped and counted instead.
public enum RielaStandardStreams {
  private static let droppedLock = NSLock()
  nonisolated(unsafe) private static var droppedWrites = 0

  /// Number of writes that could not be completed since process start.
  public static var droppedWriteCount: Int {
    droppedLock.lock()
    defer { droppedLock.unlock() }
    return droppedWrites
  }

  public static func writeError(_ text: String) { write(Data(text.utf8), to: STDERR_FILENO) }
  public static func writeError(_ data: Data) { write(data, to: STDERR_FILENO) }
  public static func writeOutput(_ text: String) { write(Data(text.utf8), to: STDOUT_FILENO) }
  public static func writeOutput(_ data: Data) { write(data, to: STDOUT_FILENO) }

  @discardableResult
  public static func write(_ data: Data, to descriptor: Int32) -> Bool {
    guard !data.isEmpty else { return true }
    let completed = data.withUnsafeBytes { buffer -> Bool in
      guard var pointer = buffer.baseAddress else { return true }
      var remaining = buffer.count
      while remaining > 0 {
        #if os(Linux)
        let written = Glibc.write(descriptor, pointer, remaining)
        #else
        let written = Darwin.write(descriptor, pointer, remaining)
        #endif
        if written > 0 {
          pointer = pointer.advanced(by: written)
          remaining -= written
        } else if written < 0 && errno == EINTR {
          continue
        } else {
          return false
        }
      }
      return true
    }
    if !completed {
      droppedLock.lock()
      droppedWrites += 1
      droppedLock.unlock()
    }
    return completed
  }
}
