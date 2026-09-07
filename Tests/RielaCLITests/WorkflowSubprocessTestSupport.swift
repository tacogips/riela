import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct CapturedWorkflowTestProcess {
  let status: Int32
  let terminationReason: Process.TerminationReason
  let stdout: String
  let stderr: String
}

/// Process-boundary tests must bound failures as well as successful fixtures.
/// File-backed output avoids deadlocking on full, undrained stdout/stderr pipes.
enum WorkflowSubprocessTestSupport {
  static func capture(
    executable: URL, arguments: [String], logRoot: URL, workingDirectory: URL? = nil,
    environment: [String: String]? = nil, timeout: TimeInterval = 30
  ) throws -> CapturedWorkflowTestProcess {
    try FileManager.default.createDirectory(at: logRoot, withIntermediateDirectories: true)
    let prefix = logRoot.appendingPathComponent("process-\(UUID().uuidString)")
    let outputURL = prefix.appendingPathExtension("stdout")
    let errorURL = prefix.appendingPathExtension("stderr")
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    FileManager.default.createFile(atPath: errorURL.path, contents: nil)
    let output = try FileHandle(forWritingTo: outputURL)
    let errors = try FileHandle(forWritingTo: errorURL)
    defer { try? output.close(); try? errors.close() }
    let process = Process()
    process.executableURL = executable
    process.currentDirectoryURL = workingDirectory
    process.arguments = arguments
    process.environment = environment ?? ProcessInfo.processInfo.environment
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    try waitForExit(process, timeout: timeout)
    return CapturedWorkflowTestProcess(
      status: process.terminationStatus, terminationReason: process.terminationReason,
      stdout: try String(contentsOf: outputURL, encoding: .utf8), stderr: try String(contentsOf: errorURL, encoding: .utf8)
    )
  }

  static func waitForExit(_ process: Process, timeout: TimeInterval = 30) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    guard !process.isRunning else {
      _ = kill(process.processIdentifier, SIGKILL)
      let reapDeadline = Date().addingTimeInterval(3)
      while process.isRunning, Date() < reapDeadline { Thread.sleep(forTimeInterval: 0.01) }
      if !process.isRunning { process.waitUntilExit() }
      throw NSError(domain: "WorkflowSubprocessTestSupport", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "owned subprocess \(process.processIdentifier) exceeded \(timeout) seconds"
      ])
    }
    process.waitUntilExit()
  }
}
