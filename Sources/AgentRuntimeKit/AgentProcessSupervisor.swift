import Foundation

public final class AgentProcessSupervisor<Managed: AgentManagedProcessRuntime>: @unchecked Sendable {
  public typealias RolloutLine = Managed.RolloutLine
  public typealias Executor = @Sendable ([String], String, [String: String]) -> AgentProcessExecution
  public typealias ManagedFactory = AgentManagedProcessLauncher.ManagedFactory<Managed>

  private let executableName: String
  private let executor: Executor?
  private let registry = AgentProcessRegistry<Managed>()

  public init(executableName: String, executor: Executor? = nil) {
    self.executableName = executableName
    self.executor = executor
  }

  public func list() -> [AgentProcessRecord] {
    registry.list()
  }

  public func get(id: String) -> AgentProcessRecord? {
    registry.get(id: id)
  }

  public func kill(id: String) -> Bool {
    let (marked, managed) = registry.markKilled(id: id)
    managed?.terminate()
    return marked
  }

  public func writeInput(id: String, text: String) -> Bool {
    let (appended, managed) = registry.appendInput(id: id, text: text)
    guard appended else {
      return false
    }
    return managed?.write(text) ?? false
  }

  public func killAll() {
    registry.markAllRunningKilled().forEach { $0.terminate() }
  }

  @discardableResult
  public func prune() -> Int {
    registry.prune()
  }

  public func run(
    prompt: String,
    arguments: [String],
    environment: [String: String],
    cwd: String?,
    initialInput: String? = nil,
    makeManaged: @escaping ManagedFactory,
    makeFailedManaged: @escaping (Error) -> Managed
  ) -> (process: AgentProcessRecord, result: AgentProcessExecution) {
    let allArguments = [executableName] + arguments
    guard let executor else {
      let started = startManagedProcess(
        prompt: prompt,
        commandArguments: allArguments,
        environment: environment,
        cwd: cwd,
        closeInputAfterPrompt: true,
        initialInput: initialInput,
        makeManaged: makeManaged,
        makeFailedManaged: makeFailedManaged
      )
      started.managed.waitUntilExit()
      let result = started.managed.execution()
      let record = registry.finish(id: started.process.id, exitCode: result.exitCode) ?? started.process
      registry.removeManagedProcess(id: record.id)
      return (record, result)
    }
    let record = registry.createVirtualRunningRecord(commandArguments: allArguments, prompt: prompt)
    let result = executor(allArguments, prompt, environment)
    let finished = registry.finish(id: record.id, exitCode: result.exitCode) ?? record
    return (finished, result)
  }

  public func startProcess(
    prompt: String,
    arguments: [String],
    environment: [String: String],
    cwd: String?,
    closeInputAfterPrompt: Bool,
    initialInput: String? = nil,
    makeManaged: @escaping ManagedFactory,
    makeFailedManaged: @escaping (Error) -> Managed
  ) -> AgentProcessRecord {
    let allArguments = [executableName] + arguments
    guard executor == nil else {
      return registry.createVirtualRunningRecord(commandArguments: allArguments, prompt: prompt)
    }
    return startManagedProcess(
      prompt: prompt,
      commandArguments: allArguments,
      environment: environment,
      cwd: cwd,
      closeInputAfterPrompt: closeInputAfterPrompt,
      initialInput: initialInput,
      makeManaged: makeManaged,
      makeFailedManaged: makeFailedManaged
    ).process
  }

  public func stream(
    prompt: String,
    arguments: [String],
    environment: [String: String],
    cwd: String?,
    initialInput: String? = nil,
    makeOutputBuffers: () -> AgentProcessOutputBuffers<RolloutLine>,
    makeManaged: @escaping ManagedFactory,
    makeFailedManaged: @escaping (Error) -> Managed
  ) -> AgentExecStreamResult<RolloutLine> {
    if executor != nil {
      let executed = run(
        prompt: prompt,
        arguments: arguments,
        environment: environment,
        cwd: cwd,
        initialInput: initialInput,
        makeManaged: makeManaged,
        makeFailedManaged: makeFailedManaged
      )
      let buffers = makeOutputBuffers()
      buffers.appendStdout(Data(executed.result.stdout.utf8))
      buffers.appendStderr(Data(executed.result.stderr.utf8))
      buffers.finishStdout()
      return AgentExecStreamResult(
        process: executed.process,
        lines: AgentRolloutLineStream(buffers: buffers),
        completion: AgentProcessCompletion { executed.result.exitCode }
      )
    }

    let started = startManagedProcess(
      prompt: prompt,
      commandArguments: [executableName] + arguments,
      environment: environment,
      cwd: cwd,
      closeInputAfterPrompt: true,
      initialInput: initialInput,
      makeManaged: makeManaged,
      makeFailedManaged: makeFailedManaged
    )
    return AgentExecStreamResult(
      process: started.process,
      lines: AgentRolloutLineStream(buffers: started.managed.agentOutputBuffers),
      completion: AgentProcessCompletion { [weak self, managed = started.managed, processId = started.process.id] in
        managed.waitUntilExit()
        let result = managed.execution()
        self?.registry.finish(id: processId, exitCode: result.exitCode)
        self?.registry.removeManagedProcess(id: processId)
        return result.exitCode
      }
    )
  }

  private func startManagedProcess(
    prompt: String,
    commandArguments: [String],
    environment: [String: String],
    cwd: String?,
    closeInputAfterPrompt: Bool,
    initialInput: String? = nil,
    makeManaged: @escaping ManagedFactory,
    makeFailedManaged: @escaping (Error) -> Managed
  ) -> (process: AgentProcessRecord, managed: Managed) {
    let launched = AgentManagedProcessLauncher.launch(
      commandArguments: commandArguments,
      environment: environment,
      cwd: cwd,
      prompt: prompt,
      closeInputAfterPrompt: closeInputAfterPrompt,
      initialInput: initialInput,
      makeManaged: makeManaged,
      makeFailedManaged: makeFailedManaged
    )
    if let systemProcess = launched.systemProcess {
      registry.store(record: launched.record, managed: launched.managed)
      systemProcess.terminationHandler = { [weak self, id = launched.record.id] (process: Process) in
        self?.registry.finish(id: id, exitCode: process.terminationStatus)
      }
    } else {
      registry.store(record: launched.record)
    }
    return (launched.record, launched.managed)
  }
}
