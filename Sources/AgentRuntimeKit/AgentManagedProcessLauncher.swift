import Foundation

public protocol AgentManagedProcessControl: AnyObject, Sendable {
  func startDraining()
  @discardableResult
  func write(_ text: String) -> Bool
  func closeInput()
  func terminate()
  func waitUntilExit()
}

public extension AgentManagedProcessControl {
  @discardableResult
  func waitUntilExit(timeout: TimeInterval) -> Bool {
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global(qos: .utility).async {
      self.waitUntilExit()
      group.leave()
    }
    return group.wait(timeout: .now() + timeout) == .success
  }
}

extension AgentManagedProcess: AgentManagedProcessControl {}

public protocol AgentManagedProcessRuntime: AgentManagedProcessControl {
  associatedtype RolloutLine

  var agentOutputBuffers: AgentProcessOutputBuffers<RolloutLine> { get }

  func execution() -> AgentProcessExecution
}

public struct AgentManagedProcessLaunchResult<Managed> {
  public var record: AgentProcessRecord
  public var managed: Managed
  public var systemProcess: Process?

  public init(record: AgentProcessRecord, managed: Managed, systemProcess: Process?) {
    self.record = record
    self.managed = managed
    self.systemProcess = systemProcess
  }
}

public enum AgentManagedProcessLauncher {
  public typealias ManagedFactory<Managed> = (
    _ process: Process,
    _ input: FileHandle,
    _ output: FileHandle,
    _ error: FileHandle
  ) -> Managed

  public static func launch<Managed: AgentManagedProcessControl>(
    commandArguments: [String],
    environment: [String: String],
    cwd: String?,
    prompt: String,
    closeInputAfterPrompt: Bool,
    initialInput: String? = nil,
    makeManaged: ManagedFactory<Managed>,
    makeFailedManaged: (Error) -> Managed
  ) -> AgentManagedProcessLaunchResult<Managed> {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = commandArguments
    process.environment = environment
    if let cwd {
      process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
    }

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    let inputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    process.standardInput = inputPipe

    let id = UUID().uuidString
    do {
      try process.run()
      let record = AgentProcessRegistry<Managed>.makeRecord(
        id: id,
        pid: process.processIdentifier,
        commandArguments: commandArguments,
        prompt: prompt,
        status: .running
      )
      let managed = makeManaged(
        process,
        inputPipe.fileHandleForWriting,
        outputPipe.fileHandleForReading,
        errorPipe.fileHandleForReading
      )
      managed.startDraining()
      if closeInputAfterPrompt {
        if let initialInput {
          _ = managed.write(initialInput)
        }
        managed.closeInput()
      }
      return AgentManagedProcessLaunchResult(record: record, managed: managed, systemProcess: process)
    } catch {
      let record = AgentProcessRegistry<Managed>.makeRecord(
        id: id,
        pid: -1,
        commandArguments: commandArguments,
        prompt: prompt,
        status: .exited,
        exitCode: 127
      )
      return AgentManagedProcessLaunchResult(record: record, managed: makeFailedManaged(error), systemProcess: nil)
    }
  }
}
