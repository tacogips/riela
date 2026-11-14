import Foundation
@testable import RielaCLI

final class ActionGitFinalizationFailureInjector: GitFinalizationFailureInjecting, @unchecked Sendable {
  private let lock = NSLock()
  private let phase: GitFinalizationFailurePhase
  private let action: () throws -> Void
  private var didRun = false

  init(phase: GitFinalizationFailurePhase, action: @escaping () throws -> Void) {
    self.phase = phase
    self.action = action
  }

  func check(_ phase: GitFinalizationFailurePhase) throws {
    let shouldRun = lock.withLock { () -> Bool in
      guard phase == self.phase, !didRun else { return false }
      didRun = true
      return true
    }
    if shouldRun {
      try action()
    }
  }
}

final class FailOnceMatchingGitCommandRunner: GitCommandRunning, @unchecked Sendable {
  private let lock = NSLock()
  private let argument: String
  private let underlying = FoundationGitCommandRunner()
  private var didFail = false

  init(argument: String) {
    self.argument = argument
  }

  func run(_ invocation: GitCommandInvocation) throws -> GitCommandResult {
    let shouldFail = lock.withLock { () -> Bool in
      guard invocation.arguments.contains(argument), !didFail else { return false }
      didFail = true
      return true
    }
    if shouldFail {
      return GitCommandResult(exitCode: 128, output: "injected validation failure")
    }
    return try underlying.run(invocation)
  }
}
