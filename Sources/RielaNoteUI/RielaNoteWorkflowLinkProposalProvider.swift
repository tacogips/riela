import Foundation
import RielaNote

public struct RielaNoteLinkProposalDraft: Codable, Equatable, Sendable {
  public var targetNoteId: String
  public var linkKind: String
  public var reason: String

  public init(targetNoteId: String, linkKind: String = "related", reason: String) {
    self.targetNoteId = targetNoteId
    self.linkKind = linkKind
    self.reason = reason
  }
}

public protocol RielaNoteLinkProposalProviding: Sendable {
  func proposeLinkDrafts(noteId: String, noteRoot: String, query: String, limit: Int) async throws
    -> [RielaNoteLinkProposalDraft]
}

#if os(macOS)
public struct RielaWorkflowNoteLinkProposalProvider: RielaNoteLinkProposalProviding {
  public static let defaultDeadlineSeconds: TimeInterval = 60
  public var workflowDefinitionDirectory: String
  public var executablePath: String?
  public var environment: [String: String]
  public var deadlineSeconds: TimeInterval

  public init(
    workflowDefinitionDirectory: String,
    executablePath: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    deadlineSeconds: TimeInterval = Self.defaultDeadlineSeconds
  ) {
    self.workflowDefinitionDirectory = workflowDefinitionDirectory
    self.executablePath = executablePath
    self.environment = environment
    self.deadlineSeconds = deadlineSeconds
  }

  public func proposeLinkDrafts(
    noteId: String,
    noteRoot: String,
    query: String,
    limit: Int
  ) async throws -> [RielaNoteLinkProposalDraft] {
    let processBox = RielaWorkflowProcessBox()
    return try await withTaskCancellationHandler {
      try await Task.detached {
        try runNoteLinkExtractWorkflow(
        executablePath: resolvedRielaExecutablePath(executablePath, environment: environment),
        workflowDefinitionDirectory: workflowDefinitionDirectory,
        noteId: noteId,
        noteRoot: noteRoot,
        query: query,
        limit: limit,
        environment: environment,
        deadlineSeconds: deadlineSeconds,
        processBox: processBox
        )
      }.value
    } onCancel: {
      processBox.terminate()
    }
  }

  public static func defaultProvider(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) -> RielaWorkflowNoteLinkProposalProvider? {
    let candidates = defaultWorkflowDirectoryCandidates(environment: environment)
    guard let workflowDirectory = candidates.first(where: { candidate in
      var isDirectory: ObjCBool = false
      let path = URL(fileURLWithPath: candidate, isDirectory: true)
        .appendingPathComponent("note-link-extract", isDirectory: true)
        .appendingPathComponent("workflow.json")
        .path
      return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }) else {
      return nil
    }
    return RielaWorkflowNoteLinkProposalProvider(
      workflowDefinitionDirectory: workflowDirectory,
      executablePath: environment["RIELA_NOTE_LINK_EXTRACT_RIELA_EXECUTABLE"],
      environment: environment
    )
  }
}

private struct RielaWorkflowRunResultEnvelope: Decodable {
  var result: RielaWorkflowRunResult
}

private struct RielaWorkflowRunResult: Decodable {
  var rootOutput: RielaWorkflowRootOutput?
}

private struct RielaWorkflowRootOutput: Decodable {
  var proposals: [RielaNoteLinkProposalDraft]?
}

private func runNoteLinkExtractWorkflow(
  executablePath: String,
  workflowDefinitionDirectory: String,
  noteId: String,
  noteRoot: String,
  query: String,
  limit: Int,
  environment: [String: String],
  deadlineSeconds: TimeInterval,
  processBox: RielaWorkflowProcessBox
) throws -> [RielaNoteLinkProposalDraft] {
  let subjectNote = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: noteRoot)).getNote(noteId)
  let process = Process()
  let executableArguments: [String]
  if executablePath == "/usr/bin/env" {
    process.executableURL = URL(fileURLWithPath: executablePath)
    executableArguments = ["riela"] + noteLinkExtractArguments(
      workflowDefinitionDirectory: workflowDefinitionDirectory,
      noteId: noteId,
      noteRoot: noteRoot,
      query: query,
      limit: limit,
      subjectBodyMarkdown: subjectNote.bodyMarkdown
    )
  } else {
    process.executableURL = URL(fileURLWithPath: executablePath)
    executableArguments = noteLinkExtractArguments(
      workflowDefinitionDirectory: workflowDefinitionDirectory,
      noteId: noteId,
      noteRoot: noteRoot,
      query: query,
      limit: limit,
      subjectBodyMarkdown: subjectNote.bodyMarkdown
    )
  }
  process.arguments = executableArguments
  process.environment = environment
  let outputPipe = Pipe()
  let errorPipe = Pipe()
  process.standardOutput = outputPipe
  process.standardError = errorPipe
  let outputDrain = RielaWorkflowPipeDrain(pipe: outputPipe, label: "riela.note-link-extract.stdout")
  let errorDrain = RielaWorkflowPipeDrain(pipe: errorPipe, label: "riela.note-link-extract.stderr")
  let drainGroup = DispatchGroup()
  try process.run()
  processBox.set(process)
  defer {
    processBox.clear(process)
  }
  outputDrain.start(group: drainGroup)
  errorDrain.start(group: drainGroup)
  let deadline = Date().addingTimeInterval(max(1, deadlineSeconds))
  while process.isRunning {
    if Task.isCancelled {
      process.terminate()
      drainGroup.wait()
      throw CancellationError()
    }
    if Date() >= deadline {
      process.terminate()
      drainGroup.wait()
      throw RielaWorkflowNoteLinkProposalError.timedOut
    }
    Thread.sleep(forTimeInterval: 0.05)
  }
  drainGroup.wait()
  let output = outputDrain.stringValue()
  let error = errorDrain.stringValue()
  guard process.terminationStatus == 0 else {
    throw RielaWorkflowNoteLinkProposalError.workflowFailed(error.trimmingCharacters(in: .whitespacesAndNewlines))
  }
  guard let proposals = parseNoteLinkExtractProposals(from: output) else {
    throw RielaWorkflowNoteLinkProposalError.invalidOutput
  }
  return proposals
}

private func noteLinkExtractArguments(
  workflowDefinitionDirectory: String,
  noteId: String,
  noteRoot: String,
  query: String,
  limit: Int,
  subjectBodyMarkdown: String
) -> [String] {
  let variables: [String: Any] = [
    "noteRoot": noteRoot,
    "workflowInput": [
      "noteId": noteId,
      "subjectBodyMarkdown": subjectBodyMarkdown,
      "query": query,
      "limit": limit
    ]
  ]
  let variablesData = try? JSONSerialization.data(withJSONObject: variables, options: [.sortedKeys])
  let variablesJSON = variablesData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
  return [
    "workflow",
    "run",
    "note-link-extract",
    "--workflow-definition-dir",
    workflowDefinitionDirectory,
    "--variables",
    variablesJSON,
    "--output",
    "jsonl"
  ]
}

private func parseNoteLinkExtractProposals(from output: String) -> [RielaNoteLinkProposalDraft]? {
  let decoder = JSONDecoder()
  for line in output.split(separator: "\n").reversed() {
    guard let data = line.data(using: .utf8),
          let envelope = try? decoder.decode(RielaWorkflowRunResultEnvelope.self, from: data),
          let proposals = envelope.result.rootOutput?.proposals else {
      continue
    }
    return proposals
  }
  return nil
}

private func resolvedRielaExecutablePath(_ configuredPath: String?, environment: [String: String]) -> String {
  if let configuredPath, FileManager.default.isExecutableFile(atPath: configuredPath) {
    return configuredPath
  }
  if let environmentPath = environment["RIELA_APP_RIELA_EXECUTABLE"],
     FileManager.default.isExecutableFile(atPath: environmentPath) {
    return environmentPath
  }
  if let sibling = Bundle.main.executableURL?
    .deletingLastPathComponent()
    .appendingPathComponent("riela")
    .path,
    FileManager.default.isExecutableFile(atPath: sibling) {
    return sibling
  }
  return "/usr/bin/env"
}

private func defaultWorkflowDirectoryCandidates(environment: [String: String]) -> [String] {
  var candidates: [String] = []
  if let configured = environment["RIELA_NOTE_LINK_EXTRACT_WORKFLOW_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
     !configured.isEmpty {
    candidates.append(configured)
  }
  if let resource = Bundle.main.resourceURL?.appendingPathComponent("examples", isDirectory: true).path {
    candidates.append(resource)
  }
  candidates.append(
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("examples", isDirectory: true)
      .path
  )
  return candidates
}

public enum RielaWorkflowNoteLinkProposalError: Error, Equatable, Sendable {
  case workflowFailed(String)
  case invalidOutput
  case timedOut
}

private final class RielaWorkflowProcessBox: @unchecked Sendable {
  private let lock = NSLock()
  private var process: Process?

  func set(_ process: Process) {
    lock.lock()
    self.process = process
    lock.unlock()
  }

  func clear(_ process: Process) {
    lock.lock()
    if self.process === process {
      self.process = nil
    }
    lock.unlock()
  }

  func terminate() {
    lock.lock()
    let process = self.process
    lock.unlock()
    if process?.isRunning == true {
      process?.terminate()
    }
  }
}

private final class RielaWorkflowPipeDrain: @unchecked Sendable {
  private let pipe: Pipe
  private let queue: DispatchQueue
  private let lock = NSLock()
  private var data = Data()

  init(pipe: Pipe, label: String) {
    self.pipe = pipe
    queue = DispatchQueue(label: label)
  }

  func start(group: DispatchGroup) {
    group.enter()
    queue.async { [self] in
      let drained = pipe.fileHandleForReading.readDataToEndOfFile()
      lock.lock()
      data = drained
      lock.unlock()
      group.leave()
    }
  }

  func stringValue() -> String {
    lock.lock()
    let data = data
    lock.unlock()
    return String(data: data, encoding: .utf8) ?? ""
  }
}
#endif
