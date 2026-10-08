import Foundation

/// Synchronous package tools must drain both pipes while the child is running.
/// Waiting for exit or draining the pipes serially can deadlock on a full pipe.
package struct PackageToolOutput: Sendable {
  package var stdout: Data
  package var stderr: Data

  package static func collect(from process: Process) throws -> PackageToolOutput {
    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error
    defer {
      try? output.fileHandleForReading.close()
      try? output.fileHandleForWriting.close()
      try? error.fileHandleForReading.close()
      try? error.fileHandleForWriting.close()
    }
    try process.run()
    // Only the child owns the remaining writers; its exit must produce EOF.
    try? output.fileHandleForWriting.close()
    try? error.fileHandleForWriting.close()
    let readers = DispatchGroup()
    let stdout = PackageToolPipeResult()
    let stderr = PackageToolPipeResult()
    stdout.drain(output.fileHandleForReading, group: readers)
    stderr.drain(error.fileHandleForReading, group: readers)
    process.waitUntilExit()
    readers.wait()
    return try PackageToolOutput(stdout: stdout.get(), stderr: stderr.get())
  }
}

private final class PackageToolPipeResult: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<Data, Error> = .success(Data())

  func drain(_ handle: FileHandle, group: DispatchGroup) {
    group.enter()
    DispatchQueue.global(qos: .utility).async {
      defer { group.leave() }
      let result = Result { try handle.readToEnd() ?? Data() }
      try? handle.close()
      self.lock.withLock { self.result = result }
    }
  }

  func get() throws -> Data {
    try lock.withLock { try result.get() }
  }
}
