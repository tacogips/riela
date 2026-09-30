import ArgumentParser
import Foundation
import RielaCore
import RielaWork

struct TaskHandoverCommandRunner: Sendable {
  func run(_ command: TaskCommand, signalState: TaskRunSignalState?) async -> CLICommandResult {
    do {
      switch command.kind {
      case .handover: return try requestHandover(command)
      case .takeover: return await takeover(command, signalState: signalState)
      case .answer: return try answer(command)
      case .handovers: return try handovers(command)
      case .reconcile: return await reconcile(command)
      case .show, .list, .run, .decide: throw CLIUsageError("unsupported task handover command")
      }
    } catch let error as CLIUsageError {
      return CLICommandResult(exitCode: .usage, stderr: error.message)
    } catch {
      if command.options.output.isStructured {
        return CLICommandResult(
          exitCode: .failure,
          stdout: (try? jsonString(TaskCommandFailureResult(
            taskId: command.options.target ?? "", command: command.kind.rawValue,
            error: "\(error)", exitCode: CLIExitCode.failure.rawValue
          ))) ?? ""
        )
      }
      return CLICommandResult(exitCode: .failure, stderr: "\(error)")
    }
  }

  private func requestHandover(_ command: TaskCommand) throws -> CLICommandResult {
    let taskId = try requiredTaskId(command)
    let parsed = try ParsedTaskHandoverOptions.resolve(command.options.arguments)
    let located = try locate(taskId, options: parsed.shared)
    let request = try TaskHandoverRuntime(located: located, options: parsed.shared).requestHandover(
      taskId: TaskID(taskId), reason: parsed.reason, immediate: parsed.immediate,
      target: parsed.target, sinks: parsed.sinks
    )
    let result = TaskHandoverRequestCommandResult(
      taskId: taskId, requestId: request.requestId, attemptId: request.attemptId.rawValue,
      immediate: request.immediate
    )
    return render(result, output: command.options.output, text: [
      "taskId: \(result.taskId)", "requestId: \(result.requestId)",
      "attemptId: \(result.attemptId)", "immediate: \(result.immediate)"
    ])
  }

  private func takeover(_ command: TaskCommand, signalState: TaskRunSignalState?) async -> CLICommandResult {
    do {
      let taskId = try requiredTaskId(command)
      let parsed = try ParsedTaskTakeoverOptions.resolve(command.options.arguments)
      var shared = parsed.shared
      let located = try locate(taskId, options: shared)
      let runtime = TaskHandoverRuntime(located: located, options: shared)
      var packet: HandoverPacket?
      if let override = parsed.packet {
        packet = try await loadPacket(override, taskId: TaskID(taskId), located: located, options: shared)
      } else {
        packet = try located.store.latestHandover(taskId: TaskID(taskId))
      }
      if parsed.forceOrphan {
        packet = try await runtime.forceOrphan(
          taskId: TaskID(taskId), producer: .human(principal: parsed.principal), cliSinks: parsed.sinks
        )
      } else if try TaskDispatcher(store: located.store).pendingReservation(taskId: TaskID(taskId)) == nil {
        _ = try runtime.requestTakeover(
          taskId: TaskID(taskId), traits: parsed.traits, producer: .human(principal: parsed.principal)
        )
      }
      if let cloneDirectory = parsed.cloneInto {
        guard let packet, let remote = packet.deliverables.compactMap({ deliverable -> String? in
          guard case let .repository(repository) = deliverable, !repository.remote.isEmpty else { return nil }
          return repository.remote
        }).first else {
          throw WorkStoreError("--clone-into requires a repository handover deliverable with a remote URL")
        }
        try cloneRepository(remote: remote, into: cloneDirectory)
        shared.workingDirectory = cloneDirectory
      }
      return await TaskDispatch(signalState: signalState).run(
        taskId: taskId, options: shared, dryRun: false, output: command.options.output,
        localTraits: parsed.traits, packetOverride: packet
      )
    } catch let error as CLIUsageError {
      return CLICommandResult(exitCode: .usage, stderr: error.message)
    } catch {
      return CLICommandResult(exitCode: .failure, stderr: "\(error)")
    }
  }

  private func answer(_ command: TaskCommand) throws -> CLICommandResult {
    let taskId = try requiredTaskId(command)
    let parsed = try ParsedTaskAnswerOptions.resolve(command.options.arguments)
    let located = try locate(taskId, options: parsed.shared)
    guard let packet = try located.store.latestHandover(taskId: TaskID(taskId)),
          case let .userInputRequired(question) = packet.reason,
          question.id == parsed.questionId else {
      throw WorkStoreError("latest handover does not contain question '\(parsed.questionId)'")
    }
    let payload: JSONObject
    switch parsed.payload {
    case let .json(value):
      guard case let .object(object) = value else { throw CLIUsageError("--answer-json must be a JSON object") }
      payload = object
    case let .file(path):
      let data = try Data(contentsOf: URL(fileURLWithPath: path))
      guard case let .object(object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
        throw CLIUsageError("--answer-file must contain a JSON object")
      }
      payload = object
    case let .text(value): payload = ["text": .string(value)]
    case let .option(optionId):
      guard question.options.contains(where: { $0.id == optionId }) else {
        throw WorkStoreError("option '\(optionId)' is not among the question's options")
      }
      payload = ["option": .string(optionId)]
    case .useDefault:
      guard let defaultAnswer = question.defaultAnswer else {
        throw WorkStoreError("question '\(question.id)' has no default answer")
      }
      payload = defaultAnswer
    }
    let task = try TaskHandoverRuntime(located: located, options: parsed.shared).answer(
      taskId: TaskID(taskId), questionId: parsed.questionId, payload: payload,
      producer: .human(principal: parsed.principal)
    )
    let result = TaskAnswerCommandResult(taskId: taskId, questionId: parsed.questionId, taskState: task.state)
    return render(result, output: command.options.output, text: [
      "taskId: \(result.taskId)", "questionId: \(result.questionId)", "taskState: \(result.taskState.rawValue)"
    ])
  }

  private func handovers(_ command: TaskCommand) throws -> CLICommandResult {
    let taskId = try requiredTaskId(command)
    let options = try ParsedTaskSharedOptions.resolve(command.options.arguments)
    let located = try locate(taskId, options: options)
    let packets = try located.store.listHandovers(taskId: TaskID(taskId))
    let attempts = try located.store.listAttempts(taskId: TaskID(taskId))
    let successors = attempts.compactMap { attempt in attempt.takeoverLineage.map { ($0.handoverId, attempt.id.rawValue) } }
    let rows = packets.map { packet in
      TaskHandoverCommandRow(packet: packet, successorAttemptId: successors.first(where: { $0.0 == packet.id })?.1)
    }
    let result = TaskHandoversCommandResult(taskId: taskId, handovers: rows)
    return render(result, output: command.options.output, text: rows.map {
      "handoverId: \($0.handoverId) createdAt: \($0.createdAt) reasonKind: \($0.reasonKind) digest: \($0.digest)"
    })
  }

  private func reconcile(_ command: TaskCommand) async -> CLICommandResult {
    do {
      let parsed = try ParsedTaskReconcileOptions.resolve(command.options.arguments)
      let options = parsed.shared
      let roots = TaskCommandRunner().storeRoots(options)
      let resolvedRoots = roots.isEmpty ? [canonicalRuntimeStoreRoot(
        sessionStoreRoot: CLIWorkflowSessionStore.resolveRootDirectory(
          sessionStore: options.sessionStore, scope: options.scope,
          workingDirectory: options.workingDirectory, environment: CLIRuntimeEnvironment.mergedProcessEnvironment()
        )
      )] : roots
      var entries: [TaskReconcileEntry] = []
      for root in resolvedRoots {
        let runtime = TaskHandoverRuntime(
          located: TaskCommandRunner.LocatedTask(
            task: Self.placeholderTask(), store: WorkStore(rootDirectory: root), root: root
          ), options: options
        )
        entries += try await runtime.reconcileExpired(dryRun: parsed.dryRun, cliSinks: parsed.sinks)
      }
      let result = TaskReconcileCommandResult(entries: entries)
      return render(result, output: command.options.output, text: entries.map {
        "taskId: \($0.taskId.rawValue) attemptId: \($0.attemptId.rawValue) action: \($0.action)"
      })
    } catch let error as CLIUsageError {
      return CLICommandResult(exitCode: .usage, stderr: error.message)
    } catch {
      return CLICommandResult(exitCode: .failure, stderr: "\(error)")
    }
  }

  func runSessionHandover(_ options: CLICommandOptions) async -> CLICommandResult {
    do {
      guard let sessionId = options.target, !sessionId.isEmpty else {
        throw CLIUsageError("session handover requires a session id")
      }
      let parsed = try ParsedSessionHandoverOptions.resolve(options.arguments)
      let root = TaskCommandRunner().storeRoots(parsed.shared).first ?? canonicalRuntimeStoreRoot(
        sessionStoreRoot: CLIWorkflowSessionStore.resolveRootDirectory(
          sessionStore: parsed.shared.sessionStore, scope: parsed.shared.scope,
          workingDirectory: parsed.shared.workingDirectory, environment: CLIRuntimeEnvironment.mergedProcessEnvironment()
        )
      )
      let store = WorkStore(rootDirectory: root)
      let placeholder = Self.placeholderTask()
      let runtime = TaskHandoverRuntime(
        located: TaskCommandRunner.LocatedTask(task: placeholder, store: store, root: root), options: parsed.shared
      )
      let (task, packet) = try await runtime.adoptAndSeal(
        sessionId: sessionId, workingDirectory: parsed.shared.workingDirectory,
        reason: parsed.reason, principal: parsed.principal,
        existingTaskId: parsed.taskId.map(TaskID.init), cliSinks: parsed.sinks
      )
      let result = SessionHandoverCommandResult(sessionId: sessionId, taskId: task.id.rawValue, handoverId: packet.id.rawValue)
      return CLICommandResult(exitCode: .suspended, stdout: try jsonString(result))
    } catch let error as CLIUsageError {
      return CLICommandResult(exitCode: .usage, stderr: error.message)
    } catch {
      return CLICommandResult(exitCode: .failure, stderr: "\(error)")
    }
  }

  private func loadPacket(
    _ value: String, taskId: TaskID, located: TaskCommandRunner.LocatedTask, options: TaskStoreOptions
  ) async throws -> HandoverPacket {
    let latest = try located.store.latestHandover(taskId: taskId)
    guard let latest else { throw WorkStoreError("task has no sealed handover packet") }
    let packet: HandoverPacket
    if value.contains(":") && value.contains("#sha256:") {
      let parsed: ParsedHandoverSinkRef
      do { parsed = try HandoverSinkRef.parse(value) } catch { throw CLIUsageError("invalid --packet locator") }
      let ref = HandoverSinkRef(kind: parsed.kind, locator: parsed.locator, digest: parsed.digest, writtenAt: latest.createdAt)
      let context = HandoverSinkContext(
        hostId: "local", storeRoot: located.root, repositoryRoot: options.workingDirectory,
        store: located.store, environment: CLIRuntimeEnvironment.mergedProcessEnvironment()
      )
      let sink = try HandoverSinkFactory.reader(for: ref, context: context)
      packet = try HandoverSinkVerification.verify(bytes: await sink.read(ref), ref: ref)
    } else {
      let bytes = try Data(contentsOf: URL(fileURLWithPath: value))
      packet = try JSONCanonical.decoder().decode(HandoverPacket.self, from: bytes)
      guard packet.digest == (try packet.canonicalDigest()) else {
        throw HandoverSinkError.digestMismatch(expected: packet.digest, actual: try packet.canonicalDigest())
      }
    }
    guard packet.taskId == taskId, packet.digest == latest.digest else {
      throw WorkStoreError("--packet does not match the latest handover stored for task '\(taskId.rawValue)'")
    }
    return packet
  }

  private func cloneRepository(remote: String, into path: String) throws {
    let destination = URL(fileURLWithPath: path, isDirectory: true)
    if FileManager.default.fileExists(atPath: path) {
      let contents = try FileManager.default.contentsOfDirectory(atPath: path)
      if !contents.isEmpty {
        let result = try runGit(["remote", "get-url", "origin"], at: destination)
        guard result.exitCode == 0, result.output.trimmingCharacters(in: .whitespacesAndNewlines) == remote else {
          throw WorkStoreError("--clone-into destination is non-empty and is not the requested repository")
        }
        return
      }
    }
    let result = try runGit(["clone", remote, path], at: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    guard result.exitCode == 0 else { throw WorkStoreError("git clone failed: \(result.output)") }
  }

  private func runGit(_ arguments: [String], at directory: URL) throws -> GitCommandResult {
    try FoundationGitCommandRunner().run(GitCommandInvocation(
      executableURL: URL(fileURLWithPath: "/usr/bin/git"), arguments: arguments,
      workingDirectory: directory, environment: ProcessInfo.processInfo.environment, standardInput: nil
    ))
  }

  private func requiredTaskId(_ command: TaskCommand) throws -> String {
    guard let taskId = command.options.target, !taskId.isEmpty else {
      throw CLIUsageError("task \(command.kind.rawValue) requires a task id")
    }
    return taskId
  }

  private func locate(_ taskId: String, options: TaskStoreOptions) throws -> TaskCommandRunner.LocatedTask {
    guard let task = try TaskCommandRunner().locateTask(TaskID(taskId), in: options) else {
      throw WorkStoreError("task '\(taskId)' was not found")
    }
    return task
  }

  private static func placeholderTask() -> WorkTask {
    WorkTask(id: TaskID("cli-placeholder"), intentId: IntentID("cli-placeholder"), title: "CLI", instruction: "CLI")
  }

  private func render<T: Encodable>(_ value: T, output: WorkflowOutputFormat, text: [String]) -> CLICommandResult {
    switch output {
    case .json, .jsonl: return CLICommandResult(exitCode: .success, stdout: (try? jsonString(value)) ?? "")
    case .text, .table: return CLICommandResult(exitCode: .success, stdout: text.joined(separator: "\n") + (text.isEmpty ? "" : "\n"))
    }
  }
}

struct TaskHandoverRequestCommandResult: Codable, Equatable, Sendable {
  var taskId: String; var requestId: String; var attemptId: String; var immediate: Bool
}
struct TaskAnswerCommandResult: Codable, Equatable, Sendable {
  var taskId: String; var questionId: String; var taskState: TaskState
}
struct TaskHandoversCommandResult: Codable, Equatable, Sendable {
  var taskId: String; var handovers: [TaskHandoverCommandRow]
}
struct TaskReconcileCommandResult: Codable, Equatable, Sendable { var entries: [TaskReconcileEntry] }
struct SessionHandoverCommandResult: Codable, Equatable, Sendable {
  var sessionId: String; var taskId: String; var handoverId: String
}

private struct TaskHandoverOptions {
  var shared: TaskStoreOptions; var reason: String; var immediate: Bool; var target: String?; var sinks: [HandoverSinkKind]
}
private struct ParsedTaskHandoverOptions: RielaClientFamilyArguments {
  @Option var scope = "auto"
  @Option(name: [.customLong("working-dir"), .customLong("working-directory")]) var workingDirectory = FileManager.default.currentDirectoryPath
  @Option var sessionStore: String?
  @Option var reason: String?
  @Flag(name: .long) var now = false
  @Option var to: String?
  @Option var sink: String?
  @Option var principal: String?
  @Option var output: String?
  static func resolve(_ args: [String]) throws -> TaskHandoverOptions {
    let value = try parseCLI(args)
    guard let reason = value.reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else { throw CLIUsageError("task handover requires --reason") }
    return TaskHandoverOptions(
      shared: try shared(value.scope, value.workingDirectory, value.sessionStore), reason: reason,
      immediate: value.now, target: value.to, sinks: try sinks(value.sink)
    )
  }
}

private struct TaskTakeoverOptions {
  var shared: TaskStoreOptions; var packet: String?; var forceOrphan: Bool; var cloneInto: String?
  var traits: [HostTrait]; var sinks: [HandoverSinkKind]; var principal: String
}
private struct ParsedTaskTakeoverOptions: RielaClientFamilyArguments {
  @Option var scope = "auto"
  @Option(name: [.customLong("working-dir"), .customLong("working-directory")]) var workingDirectory = FileManager.default.currentDirectoryPath
  @Option var sessionStore: String?
  @Option var packet: String?
  @Flag var forceOrphan = false
  @Option var cloneInto: String?
  @Option var traits: String?
  @Option var sink: String?
  @Option var principal: String?
  @Option var output: String?
  static func resolve(_ args: [String]) throws -> TaskTakeoverOptions {
    let value = try parseCLI(args)
    return TaskTakeoverOptions(
      shared: try shared(value.scope, value.workingDirectory, value.sessionStore), packet: value.packet,
      forceOrphan: value.forceOrphan, cloneInto: value.cloneInto, traits: try parsedTraits(value.traits),
      sinks: try sinks(value.sink), principal: resolvedPrincipal(value.principal)
    )
  }
}

private enum TaskAnswerPayload { case json(JSONValue), file(String), text(String), option(String), useDefault }
private struct TaskAnswerOptions {
  var shared: TaskStoreOptions; var questionId: String; var payload: TaskAnswerPayload; var principal: String
}
private struct ParsedTaskAnswerOptions: RielaClientFamilyArguments {
  @Option var scope = "auto"
  @Option(name: [.customLong("working-dir"), .customLong("working-directory")]) var workingDirectory = FileManager.default.currentDirectoryPath
  @Option var sessionStore: String?
  @Option var question: String?
  @Option var answerJson: String?
  @Option var answerFile: String?
  @Option var text: String?
  @Option var option: String?
  @Flag var useDefault = false
  @Option var principal: String?
  @Option var output: String?
  static func resolve(_ args: [String]) throws -> TaskAnswerOptions {
    let value = try parseCLI(args)
    guard let question = value.question, !question.isEmpty else { throw CLIUsageError("task answer requires --question") }
    let payloadCount = [value.answerJson != nil, value.answerFile != nil, value.text != nil, value.option != nil, value.useDefault].filter { $0 }.count
    guard payloadCount == 1 else { throw CLIUsageError("task answer requires exactly one payload flag") }
    let payload: TaskAnswerPayload
    if let raw = value.answerJson { payload = .json(try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))) } else if let path = value.answerFile {
      payload = .file(path)
    } else if let text = value.text {
      payload = .text(text)
    } else if let option = value.option {
      payload = .option(option)
    } else {
      payload = .useDefault
    }
    return TaskAnswerOptions(
      shared: try shared(value.scope, value.workingDirectory, value.sessionStore), questionId: question,
      payload: payload, principal: resolvedPrincipal(value.principal)
    )
  }
}

private struct ParsedTaskSharedOptions: RielaClientFamilyArguments {
  @Option var scope = "auto"
  @Option(name: [.customLong("working-dir"), .customLong("working-directory")]) var workingDirectory = FileManager.default.currentDirectoryPath
  @Option var sessionStore: String?
  @Option var output: String?
  static func resolve(_ args: [String]) throws -> TaskStoreOptions { let value = try parseCLI(args); return try shared(value.scope, value.workingDirectory, value.sessionStore) }
}

private struct TaskReconcileOptions { var shared: TaskStoreOptions; var dryRun: Bool; var sinks: [HandoverSinkKind] }
private struct ParsedTaskReconcileOptions: RielaClientFamilyArguments {
  @Option var scope = "auto"
  @Option(name: [.customLong("working-dir"), .customLong("working-directory")]) var workingDirectory = FileManager.default.currentDirectoryPath
  @Option var sessionStore: String?
  @Flag var expiredLeases = false
  @Flag var dryRun = false
  @Option var sink: String?
  @Option var output: String?
  static func resolve(_ args: [String]) throws -> TaskReconcileOptions {
    let value = try parseCLI(args)
    guard value.expiredLeases else { throw CLIUsageError("task reconcile supports --expired-leases") }
    return TaskReconcileOptions(
      shared: try shared(value.scope, value.workingDirectory, value.sessionStore),
      dryRun: value.dryRun, sinks: try sinks(value.sink)
    )
  }
}

private struct SessionHandoverOptions {
  var shared: TaskStoreOptions; var reason: String; var taskId: String?; var principal: String; var sinks: [HandoverSinkKind]
}
private struct ParsedSessionHandoverOptions: RielaClientFamilyArguments {
  @Option var scope = "auto"
  @Option(name: [.customLong("working-dir"), .customLong("working-directory")]) var workingDirectory = FileManager.default.currentDirectoryPath
  @Option var sessionStore: String?
  @Option var reason: String?
  @Option var task: String?
  @Option var sink: String?
  @Option var principal: String?
  @Option var output: String?
  static func resolve(_ args: [String]) throws -> SessionHandoverOptions {
    let value = try parseCLI(args)
    let reason = value.reason?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "operator handover"
    return SessionHandoverOptions(
      shared: try shared(value.scope, value.workingDirectory, value.sessionStore), reason: reason,
      taskId: value.task, principal: resolvedPrincipal(value.principal), sinks: try sinks(value.sink)
    )
  }
}

private func shared(_ scope: String, _ workingDirectory: String, _ sessionStore: String?) throws -> TaskStoreOptions {
  guard let value = WorkflowScope(rawValue: scope), value != .direct else { throw CLIUsageError("invalid --scope value '\(scope)'; expected auto, project, or user") }
  return TaskStoreOptions(scope: value, workingDirectory: workingDirectory, sessionStore: sessionStore)
}
private func resolvedPrincipal(_ value: String?) -> String { value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "local-user" }
private func parsedTraits(_ value: String?) throws -> [HostTrait] {
  try parseCSV(value, label: "host trait").map { raw in
    guard let trait = HostTrait(rawValue: String(raw)) else { throw CLIUsageError("unknown host trait '\(raw)'") }
    return trait
  }.reduce(into: []) { result, trait in if !result.contains(trait) { result.append(trait) } }.sorted()
}
private func sinks(_ value: String?) throws -> [HandoverSinkKind] {
  try parseCSV(value, label: "handover sink").map { raw in
    guard let kind = HandoverSinkKind(rawValue: String(raw)) else { throw CLIUsageError("unknown handover sink '\(raw)'") }
    return kind
  }.reduce(into: []) { result, kind in if !result.contains(kind) { result.append(kind) } }
}
private func parseCSV(_ value: String?, label: String) throws -> [String] {
  guard let value else { return [] }
  let values = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
  guard values.allSatisfy({ !$0.isEmpty }) else { throw CLIUsageError("empty \(label) in comma-separated list") }
  return values
}
private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
