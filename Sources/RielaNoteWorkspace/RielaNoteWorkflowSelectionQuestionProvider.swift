import Foundation

public struct RielaNoteSelectionAnswerDraft: Codable, Equatable, Sendable {
  public var answerMarkdown: String
  public var summary: String?

  public init(answerMarkdown: String, summary: String? = nil) {
    self.answerMarkdown = answerMarkdown
    self.summary = summary
  }
}

public protocol RielaNoteSelectionQuestionProviding: Sendable {
  func answerQuestion(
    noteId: String,
    noteRoot: String,
    question: String,
    bodyMarkdown: String,
    selectedText: String,
    selectionStart: Int,
    selectionEnd: Int
  ) async throws -> RielaNoteSelectionAnswerDraft
}

public enum RielaNoteSelectionQuestionError: Error, Equatable, Sendable {
  case notConfigured
  case workflowFailed(String)
  case invalidOutput
  case timedOut
}

#if os(macOS)
public struct RielaWorkflowNoteSelectionQuestionProvider: RielaNoteSelectionQuestionProviding {
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

  public func answerQuestion(
    noteId: String,
    noteRoot: String,
    question: String,
    bodyMarkdown: String,
    selectedText: String,
    selectionStart: Int,
    selectionEnd: Int
  ) async throws -> RielaNoteSelectionAnswerDraft {
    let processBox = RielaWorkflowProcessBox()
    return try await withTaskCancellationHandler {
      try await Task.detached {
        guard let resolvedExecutablePath = resolvedRielaExecutablePath(
          executablePath,
          environment: environment,
          allowEnvironmentOverrides: allowEnvironmentOverrides
        ) else {
          throw RielaNoteSelectionQuestionError.notConfigured
        }
        return try runNoteSelectionQuestionWorkflow(
          request: RielaNoteSelectionQuestionWorkflowRequest(
            executablePath: resolvedExecutablePath,
            workflowDefinitionDirectory: workflowDefinitionDirectory,
            noteId: noteId,
            noteRoot: noteRoot,
            question: question,
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
  ) -> RielaWorkflowNoteSelectionQuestionProvider? {
    let candidates = defaultWorkflowDirectoryCandidates(
      environment: environment,
      workflowDirectoryEnvironmentName: "RIELA_NOTE_SELECTION_QUESTION_WORKFLOW_DIR",
      allowEnvironmentOverrides: allowEnvironmentOverrides
    )
    guard let executablePath = resolvedRielaExecutablePath(
      environment["RIELA_NOTE_SELECTION_QUESTION_RIELA_EXECUTABLE"],
      environment: environment,
      allowEnvironmentOverrides: allowEnvironmentOverrides
    ) else {
      return nil
    }
    guard let workflowDirectory = candidates.first(where: { candidate in
      var isDirectory: ObjCBool = false
      let path = URL(fileURLWithPath: candidate, isDirectory: true)
        .appendingPathComponent("note-selection-question", isDirectory: true)
        .appendingPathComponent("workflow.json")
        .path
      return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }) else {
      return nil
    }
    return RielaWorkflowNoteSelectionQuestionProvider(
      workflowDefinitionDirectory: workflowDirectory,
      executablePath: executablePath,
      environment: environment,
      allowEnvironmentOverrides: allowEnvironmentOverrides
    )
  }
}

struct RielaNoteSelectionQuestionWorkflowRequest: Sendable {
  var executablePath: String
  var workflowDefinitionDirectory: String
  var noteId: String
  var noteRoot: String
  var question: String
  var bodyMarkdown: String
  var selectedText: String
  var selectionStart: Int
  var selectionEnd: Int
  var environment: [String: String]
  var deadlineSeconds: TimeInterval
}

func runNoteSelectionQuestionWorkflow(
  request: RielaNoteSelectionQuestionWorkflowRequest,
  processBox: RielaWorkflowProcessBox
) throws -> RielaNoteSelectionAnswerDraft {
  if processBox.isCancelled {
    throw CancellationError()
  }
  let variablesFile = try RielaWorkflowVariablesFile(variables: noteSelectionQuestionVariables(
    noteId: request.noteId,
    noteRoot: request.noteRoot,
    question: request.question,
    bodyMarkdown: request.bodyMarkdown,
    selectedText: request.selectedText,
    selectionStart: request.selectionStart,
    selectionEnd: request.selectionEnd
  ))
  let process = Process()
  process.executableURL = URL(fileURLWithPath: request.executablePath)
  process.arguments = rielaWorkflowRunArguments(
    workflowName: "note-selection-question",
    workflowDefinitionDirectory: request.workflowDefinitionDirectory,
    variablesFilePath: variablesFile.path
  )
  process.environment = request.environment
  let outputPipe = Pipe()
  let errorPipe = Pipe()
  process.standardOutput = outputPipe
  process.standardError = errorPipe
  let outputDrain = RielaWorkflowPipeDrain(pipe: outputPipe, label: "riela.note-selection-question.stdout")
  let errorDrain = RielaWorkflowPipeDrain(pipe: errorPipe, label: "riela.note-selection-question.stderr")
  let drainGroup = DispatchGroup()
  if processBox.isCancelled {
    throw CancellationError()
  }
  try process.run()
  processBox.set(process)
  defer {
    processBox.clear(process)
  }
  outputDrain.start(group: drainGroup)
  errorDrain.start(group: drainGroup)
  let deadline = Date().addingTimeInterval(max(1, request.deadlineSeconds))
  while process.isRunning {
    // Terminate here too: `terminate()` from onCancel can race `processBox.set`
    // and miss the process, so the loop finishes the kill it started.
    if processBox.isCancelled {
      process.terminateWithEscalation()
      rielaWorkflowWaitForDrain(drainGroup, drains: [outputDrain, errorDrain])
      throw CancellationError()
    }
    if Date() >= deadline {
      process.terminateWithEscalation()
      rielaWorkflowWaitForDrain(drainGroup, drains: [outputDrain, errorDrain])
      throw RielaNoteSelectionQuestionError.timedOut
    }
    Thread.sleep(forTimeInterval: 0.05)
  }
  rielaWorkflowWaitForDrain(drainGroup, drains: [outputDrain, errorDrain])
  if processBox.isCancelled {
    throw CancellationError()
  }
  let output = outputDrain.stringValue()
  let error = errorDrain.stringValue()
  guard process.terminationStatus == 0 else {
    throw RielaNoteSelectionQuestionError.workflowFailed(error.trimmingCharacters(in: .whitespacesAndNewlines))
  }
  guard let draft = parseNoteSelectionAnswerDraft(from: output) else {
    throw RielaNoteSelectionQuestionError.invalidOutput
  }
  return draft
}

func noteSelectionQuestionVariables(
  noteId: String,
  noteRoot: String,
  question: String,
  bodyMarkdown: String,
  selectedText: String,
  selectionStart: Int,
  selectionEnd: Int
) -> [String: Any] {
  [
    "noteRoot": noteRoot,
    "workflowInput": [
      "noteId": noteId,
      "bodyMarkdown": bodyMarkdown,
      "question": question,
      "selectedText": selectedText,
      "selectionStart": selectionStart,
      "selectionEnd": selectionEnd
    ]
  ]
}

func parseNoteSelectionAnswerDraft(from output: String) -> RielaNoteSelectionAnswerDraft? {
  rielaWorkflowRunRootOutput(from: output, as: RielaNoteSelectionAnswerDraft.self)
}
#endif
