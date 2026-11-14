import Foundation

public struct RielaNoteEditRewriteDraft: Codable, Equatable, Sendable {
  public var rewrittenMarkdown: String
  public var summary: String?

  public init(rewrittenMarkdown: String, summary: String? = nil) {
    self.rewrittenMarkdown = rewrittenMarkdown
    self.summary = summary
  }
}

public protocol RielaNoteEditRewriteProviding: Sendable {
  func proposeRewrite(
    noteId: String,
    noteRoot: String,
    instruction: String,
    bodyMarkdown: String,
    selectedText: String?,
    selectionStart: Int?,
    selectionEnd: Int?
  ) async throws -> RielaNoteEditRewriteDraft
}

public enum RielaNoteEditRewriteError: Error, Equatable, Sendable {
  case notConfigured
  case workflowFailed(String)
  case invalidOutput
  case timedOut
}

#if os(macOS)
public struct RielaWorkflowNoteEditRewriteProvider: RielaNoteEditRewriteProviding {
  public static let defaultDeadlineSeconds: TimeInterval = 120
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

  public func proposeRewrite(
    noteId: String,
    noteRoot: String,
    instruction: String,
    bodyMarkdown: String,
    selectedText: String?,
    selectionStart: Int?,
    selectionEnd: Int?
  ) async throws -> RielaNoteEditRewriteDraft {
    let processBox = RielaWorkflowProcessBox()
    return try await withTaskCancellationHandler {
      try await Task.detached {
        guard let resolvedExecutablePath = resolvedRielaExecutablePath(
          executablePath,
          environment: environment,
          allowEnvironmentOverrides: allowEnvironmentOverrides
        ) else {
          throw RielaNoteEditRewriteError.notConfigured
        }
        return try runNoteEditRewriteWorkflow(
          request: RielaNoteEditRewriteWorkflowRequest(
            executablePath: resolvedExecutablePath,
            workflowDefinitionDirectory: workflowDefinitionDirectory,
            noteId: noteId,
            noteRoot: noteRoot,
            instruction: instruction,
            bodyMarkdown: bodyMarkdown,
            selectedText: selectedText,
            selectionStart: selectionStart,
            selectionEnd: selectionEnd,
            environment: rielaWorkflowSanitizedEnvironment(from: environment),
            deadlineSeconds: deadlineSeconds
          ),
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
    allowEnvironmentOverrides: Bool = true
  ) -> RielaWorkflowNoteEditRewriteProvider? {
    let candidates = defaultWorkflowDirectoryCandidates(
      environment: environment,
      workflowDirectoryEnvironmentName: "RIELA_NOTE_EDIT_REWRITE_WORKFLOW_DIR",
      allowEnvironmentOverrides: allowEnvironmentOverrides
    )
    guard let executablePath = resolvedRielaExecutablePath(
      environment["RIELA_NOTE_EDIT_REWRITE_RIELA_EXECUTABLE"],
      environment: environment,
      allowEnvironmentOverrides: allowEnvironmentOverrides
    ) else {
      return nil
    }
    guard let workflowDirectory = candidates.first(where: { candidate in
      var isDirectory: ObjCBool = false
      let path = URL(fileURLWithPath: candidate, isDirectory: true)
        .appendingPathComponent("note-edit-rewrite", isDirectory: true)
        .appendingPathComponent("workflow.json")
        .path
      return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }) else {
      return nil
    }
    return RielaWorkflowNoteEditRewriteProvider(
      workflowDefinitionDirectory: workflowDirectory,
      executablePath: executablePath,
      environment: environment,
      allowEnvironmentOverrides: allowEnvironmentOverrides
    )
  }
}

struct RielaNoteEditRewriteWorkflowRequest: Sendable {
  var executablePath: String
  var workflowDefinitionDirectory: String
  var noteId: String
  var noteRoot: String
  var instruction: String
  var bodyMarkdown: String
  var selectedText: String?
  var selectionStart: Int?
  var selectionEnd: Int?
  var environment: [String: String]
  var deadlineSeconds: TimeInterval
}

func runNoteEditRewriteWorkflow(
  request: RielaNoteEditRewriteWorkflowRequest,
  processBox: RielaWorkflowProcessBox
) throws -> RielaNoteEditRewriteDraft {
  let process = Process()
  let workflowArguments = noteEditRewriteArguments(
    workflowDefinitionDirectory: request.workflowDefinitionDirectory,
    noteId: request.noteId,
    noteRoot: request.noteRoot,
    instruction: request.instruction,
    bodyMarkdown: request.bodyMarkdown,
    selectedText: request.selectedText,
    selectionStart: request.selectionStart,
    selectionEnd: request.selectionEnd
  )
  process.executableURL = URL(fileURLWithPath: request.executablePath)
  process.arguments = workflowArguments
  process.environment = request.environment
  let outputPipe = Pipe()
  let errorPipe = Pipe()
  process.standardOutput = outputPipe
  process.standardError = errorPipe
  let outputDrain = RielaWorkflowPipeDrain(pipe: outputPipe, label: "riela.note-edit-rewrite.stdout")
  let errorDrain = RielaWorkflowPipeDrain(pipe: errorPipe, label: "riela.note-edit-rewrite.stderr")
  let drainGroup = DispatchGroup()
  try process.run()
  processBox.set(process)
  defer {
    processBox.clear(process)
  }
  outputDrain.start(group: drainGroup)
  errorDrain.start(group: drainGroup)
  let deadline = Date().addingTimeInterval(max(1, request.deadlineSeconds))
  while process.isRunning {
    if Task.isCancelled {
      process.terminateWithEscalation()
      rielaWorkflowWaitForDrain(drainGroup, drains: [outputDrain, errorDrain])
      throw CancellationError()
    }
    if Date() >= deadline {
      process.terminateWithEscalation()
      rielaWorkflowWaitForDrain(drainGroup, drains: [outputDrain, errorDrain])
      throw RielaNoteEditRewriteError.timedOut
    }
    Thread.sleep(forTimeInterval: 0.05)
  }
  rielaWorkflowWaitForDrain(drainGroup, drains: [outputDrain, errorDrain])
  let output = outputDrain.stringValue()
  let error = errorDrain.stringValue()
  guard process.terminationStatus == 0 else {
    throw RielaNoteEditRewriteError.workflowFailed(error.trimmingCharacters(in: .whitespacesAndNewlines))
  }
  guard let draft = parseNoteEditRewriteDraft(from: output) else {
    throw RielaNoteEditRewriteError.invalidOutput
  }
  return draft
}

func noteEditRewriteArguments(
  workflowDefinitionDirectory: String,
  noteId: String,
  noteRoot: String,
  instruction: String,
  bodyMarkdown: String,
  selectedText: String?,
  selectionStart: Int?,
  selectionEnd: Int?
) -> [String] {
  var workflowInput: [String: Any] = [
    "noteId": noteId,
    "bodyMarkdown": bodyMarkdown,
    "instruction": instruction
  ]
  if let selectedText {
    workflowInput["selectedText"] = selectedText
  }
  if let selectionStart {
    workflowInput["selectionStart"] = selectionStart
  }
  if let selectionEnd {
    workflowInput["selectionEnd"] = selectionEnd
  }
  let variables: [String: Any] = [
    "noteRoot": noteRoot,
    "workflowInput": workflowInput
  ]
  let variablesData = try? JSONSerialization.data(withJSONObject: variables, options: [.sortedKeys])
  let variablesJSON = variablesData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
  return [
    "workflow",
    "run",
    "note-edit-rewrite",
    "--workflow-definition-dir",
    workflowDefinitionDirectory,
    "--variables",
    variablesJSON,
    "--output",
    "jsonl"
  ]
}

func parseNoteEditRewriteDraft(from output: String) -> RielaNoteEditRewriteDraft? {
  rielaWorkflowRunRootOutput(from: output, as: RielaNoteEditRewriteDraft.self)
}
#endif
