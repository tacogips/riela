import Foundation
@testable import RielaCLI

final class CapturingGitCommandRunner: GitCommandRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var capturedArguments: [String]?

  var arguments: [String]? { lock.withLock { capturedArguments } }

  func run(_ invocation: GitCommandInvocation) throws -> GitCommandResult {
    lock.withLock { capturedArguments = invocation.arguments }
    return GitCommandResult(exitCode: 0, output: "")
  }
}

struct SensitiveFailingGitCommandRunner: GitCommandRunning {
  var output: String
  func run(_: GitCommandInvocation) throws -> GitCommandResult {
    GitCommandResult(exitCode: 128, output: output)
  }
}
