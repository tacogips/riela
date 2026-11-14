import Foundation

public enum AgentProcessStatus: String, Equatable, Sendable {
  case running
  case exited
  case killed
}

public struct AgentProcessRecord: Equatable, Sendable {
  public var id: String
  public var pid: Int32
  public var command: String
  public var prompt: String
  public var startedAt: String
  public var status: AgentProcessStatus
  public var exitCode: Int32?
  public var arguments: [String]
  public var input: [String]

  public init(
    id: String,
    pid: Int32,
    command: String,
    prompt: String,
    startedAt: String,
    status: AgentProcessStatus,
    exitCode: Int32? = nil,
    arguments: [String] = [],
    input: [String] = []
  ) {
    self.id = id
    self.pid = pid
    self.command = command
    self.prompt = prompt
    self.startedAt = startedAt
    self.status = status
    self.exitCode = exitCode
    self.arguments = arguments
    self.input = input
  }
}

public struct AgentProcessExecution: Equatable, Sendable {
  public var stdout: String
  public var stderr: String
  public var exitCode: Int32

  public init(stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
    self.stdout = stdout
    self.stderr = stderr
    self.exitCode = exitCode
  }
}
