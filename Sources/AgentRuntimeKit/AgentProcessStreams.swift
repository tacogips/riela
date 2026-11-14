import Foundation

public final class AgentRolloutLineStream<RolloutLine>: @unchecked Sendable {
  private let buffers: AgentProcessOutputBuffers<RolloutLine>
  private var cursor = 0

  public init(buffers: AgentProcessOutputBuffers<RolloutLine>) {
    self.buffers = buffers
  }

  public func next(timeout: TimeInterval? = nil) -> RolloutLine? {
    buffers.nextLine(after: &cursor, timeout: timeout)
  }

  public func snapshot() -> [RolloutLine] {
    buffers.lines()
  }
}

public final class AgentProcessCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private let waitClosure: () -> Int32
  private var cachedExitCode: Int32?

  public init(_ waitClosure: @escaping () -> Int32) {
    self.waitClosure = waitClosure
  }

  @discardableResult
  public func wait() -> Int32 {
    lock.lock()
    if let cachedExitCode {
      lock.unlock()
      return cachedExitCode
    }
    lock.unlock()
    let exitCode = waitClosure()
    lock.lock()
    cachedExitCode = exitCode
    lock.unlock()
    return exitCode
  }
}

public struct AgentExecStreamResult<RolloutLine>: Sendable {
  public var process: AgentProcessRecord
  public var lines: AgentRolloutLineStream<RolloutLine>
  public var completion: AgentProcessCompletion

  public init(
    process: AgentProcessRecord,
    lines: AgentRolloutLineStream<RolloutLine>,
    completion: AgentProcessCompletion
  ) {
    self.process = process
    self.lines = lines
    self.completion = completion
  }

  public func collectLines() -> [RolloutLine] {
    completion.wait()
    return lines.snapshot()
  }

  public func waitForCompletion() -> Int32 {
    completion.wait()
  }
}
