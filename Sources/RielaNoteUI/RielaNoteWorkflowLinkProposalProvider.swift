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
  public var allowEnvironmentOverrides: Bool

  public init(
    workflowDefinitionDirectory: String,
    executablePath: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    deadlineSeconds: TimeInterval = Self.defaultDeadlineSeconds,
    allowEnvironmentOverrides: Bool = false
  ) {
    self.workflowDefinitionDirectory = workflowDefinitionDirectory
    self.executablePath = executablePath
    self.environment = environment
    self.deadlineSeconds = deadlineSeconds
    self.allowEnvironmentOverrides = allowEnvironmentOverrides
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
        guard let resolvedExecutablePath = resolvedRielaExecutablePath(
          executablePath,
          environment: environment,
          allowEnvironmentOverrides: allowEnvironmentOverrides
        ) else {
          throw RielaWorkflowNoteLinkProposalError.notConfigured
        }
        return try runNoteLinkExtractWorkflow(
          executablePath: resolvedExecutablePath,
          workflowDefinitionDirectory: workflowDefinitionDirectory,
          noteId: noteId,
          noteRoot: noteRoot,
          query: query,
          limit: limit,
          environment: rielaWorkflowSanitizedEnvironment(from: environment),
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
    fileManager: FileManager = .default,
    allowEnvironmentOverrides: Bool = false
  ) -> RielaWorkflowNoteLinkProposalProvider? {
    let candidates = defaultWorkflowDirectoryCandidates(
      environment: environment,
      workflowDirectoryEnvironmentName: "RIELA_NOTE_LINK_EXTRACT_WORKFLOW_DIR",
      allowEnvironmentOverrides: allowEnvironmentOverrides
    )
    guard let executablePath = resolvedRielaExecutablePath(
      environment["RIELA_NOTE_LINK_EXTRACT_RIELA_EXECUTABLE"],
      environment: environment,
      allowEnvironmentOverrides: allowEnvironmentOverrides
    ) else {
      return nil
    }
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
      executablePath: executablePath,
      environment: environment,
      allowEnvironmentOverrides: allowEnvironmentOverrides
    )
  }
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
  process.executableURL = URL(fileURLWithPath: executablePath)
  process.arguments = noteLinkExtractArguments(
    workflowDefinitionDirectory: workflowDefinitionDirectory,
    noteId: noteId,
    noteRoot: noteRoot,
    query: query,
    limit: limit,
    subjectBodyMarkdown: subjectNote.bodyMarkdown
  )
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
      process.terminateWithEscalation()
      rielaWorkflowWaitForDrain(drainGroup, drains: [outputDrain, errorDrain])
      throw CancellationError()
    }
    if Date() >= deadline {
      process.terminateWithEscalation()
      rielaWorkflowWaitForDrain(drainGroup, drains: [outputDrain, errorDrain])
      throw RielaWorkflowNoteLinkProposalError.timedOut
    }
    Thread.sleep(forTimeInterval: 0.05)
  }
  rielaWorkflowWaitForDrain(drainGroup, drains: [outputDrain, errorDrain])
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
  rielaWorkflowRunRootOutput(from: output, as: RielaWorkflowRootOutput.self)?.proposals
}

public enum RielaWorkflowNoteLinkProposalError: Error, Equatable, Sendable {
  case notConfigured
  case workflowFailed(String)
  case invalidOutput
  case timedOut
}
#endif
