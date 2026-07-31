import Foundation

#if os(macOS)
import Darwin

public struct RielaNoteWorkflowNotebookCompactProvider: RielaNoteNotebookExpansionProviding {
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

  public func compactNotebook(
    noteRoot: String,
    request: RielaNoteNotebookCompactRequest
  ) async throws -> RielaNoteNotebookCompactDraft {
    try await run(
      variables: noteNotebookCompactVariables(noteRoot: noteRoot, request: request),
      outputType: RielaNoteNotebookCompactDraft.self
    )
  }

  public func answerNotebookExpansion(
    request: RielaNoteNotebookExpansionRequest
  ) async throws -> RielaNoteNotebookExpansionAnswer {
    try await run(
      variables: noteNotebookExpansionAnswerVariables(request: request),
      outputType: RielaNoteNotebookExpansionAnswer.self
    )
  }

  public static func defaultProvider(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default,
    allowEnvironmentOverrides: Bool = true
  ) -> RielaNoteWorkflowNotebookCompactProvider? {
    let candidates = defaultWorkflowDirectoryCandidates(
      environment: environment,
      workflowDirectoryEnvironmentName: "RIELA_NOTE_NOTEBOOK_COMPACT_WORKFLOW_DIR",
      allowEnvironmentOverrides: allowEnvironmentOverrides
    )
    guard let executablePath = resolvedRielaExecutablePath(
      environment["RIELA_NOTE_NOTEBOOK_COMPACT_RIELA_EXECUTABLE"],
      environment: environment,
      allowEnvironmentOverrides: allowEnvironmentOverrides
    ) else {
      return nil
    }
    guard let workflowDirectory = candidates.first(where: { candidate in
      var isDirectory: ObjCBool = false
      let path = URL(fileURLWithPath: candidate, isDirectory: true)
        .appendingPathComponent("note-notebook-compact", isDirectory: true)
        .appendingPathComponent("workflow.json")
        .path
      return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }) else {
      return nil
    }
    return RielaNoteWorkflowNotebookCompactProvider(
      workflowDefinitionDirectory: workflowDirectory,
      executablePath: executablePath,
      environment: environment,
      allowEnvironmentOverrides: allowEnvironmentOverrides
    )
  }

  private func run<Output: Decodable & Sendable>(
    variables: [String: Any],
    outputType: Output.Type
  ) async throws -> Output {
    guard let resolvedExecutablePath = resolvedRielaExecutablePath(
      executablePath,
      environment: environment,
      allowEnvironmentOverrides: allowEnvironmentOverrides
    ) else {
      throw RielaNoteNotebookExpansionError.notConfigured
    }
    let request = RielaNoteNotebookCompactWorkflowRequest(
      executablePath: resolvedExecutablePath,
      workflowDefinitionDirectory: workflowDefinitionDirectory,
      variables: variables,
      environment: rielaWorkflowSanitizedEnvironment(from: environment),
      deadlineSeconds: deadlineSeconds
    )
    let processBox = RielaWorkflowProcessBox()
    return try await withTaskCancellationHandler {
      try await Task.detached {
        return try runNoteNotebookCompactWorkflow(
          request: request,
          processBox: processBox,
          outputType: outputType
        )
      }.value
    } onCancel: {
      processBox.terminate()
    }
  }
}

struct RielaNoteNotebookCompactWorkflowRequest: @unchecked Sendable {
  var executablePath: String
  var workflowDefinitionDirectory: String
  var variables: [String: Any]
  var environment: [String: String]
  var deadlineSeconds: TimeInterval
}

func runNoteNotebookCompactWorkflow<Output: Decodable>(
  request: RielaNoteNotebookCompactWorkflowRequest,
  processBox: RielaWorkflowProcessBox,
  outputType: Output.Type
) throws -> Output {
  if processBox.isCancelled {
    throw CancellationError()
  }
  let invocationDirectory = try RielaWorkflowInvocationDirectory()
  let variablesFile = try RielaWorkflowVariablesFile(
    variables: request.variables,
    directory: invocationDirectory.rootURL
  )
  let arguments = rielaWorkflowRunArguments(
    workflowName: "note-notebook-compact",
    workflowDefinitionDirectory: request.workflowDefinitionDirectory,
    variablesFilePath: variablesFile.path,
    sessionStorePath: invocationDirectory.sessionStorePath
  )
  let outputPipe = Pipe()
  let errorPipe = Pipe()
  let outputDrain = RielaWorkflowPipeDrain(pipe: outputPipe, label: "riela.note-notebook-compact.stdout")
  let errorDrain = RielaWorkflowPipeDrain(pipe: errorPipe, label: "riela.note-notebook-compact.stderr")
  let drainGroup = DispatchGroup()
  if processBox.isCancelled {
    throw CancellationError()
  }
  let process = try RielaWorkflowSpawnedProcess(
    executablePath: request.executablePath,
    arguments: arguments,
    environment: request.environment,
    workingDirectory: invocationDirectory.rootURL,
    outputPipe: outputPipe,
    errorPipe: errorPipe
  )
  processBox.setProcessGroup(process.processGroupID)
  defer { processBox.clearProcessGroup(process.processGroupID) }
  outputDrain.start(group: drainGroup)
  errorDrain.start(group: drainGroup)
  let deadline = Date().addingTimeInterval(max(1, request.deadlineSeconds))
  while process.isRunning {
    if processBox.isCancelled {
      rielaWorkflowTerminateProcessGroup(process.processGroupID)
      _ = process.terminationStatus
      rielaWorkflowWaitForDrain(drainGroup, drains: [outputDrain, errorDrain])
      throw CancellationError()
    }
    if Date() >= deadline {
      rielaWorkflowTerminateProcessGroup(process.processGroupID)
      _ = process.terminationStatus
      rielaWorkflowWaitForDrain(drainGroup, drains: [outputDrain, errorDrain])
      throw RielaNoteNotebookExpansionError.timedOut
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
    throw RielaNoteNotebookExpansionError.workflowFailed(
      error.trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }
  guard let decoded = rielaWorkflowRunRootOutput(from: output, as: outputType) else {
    throw RielaNoteNotebookExpansionError.invalidOutput
  }
  return decoded
}

private final class RielaWorkflowSpawnedProcess {
  let processGroupID: pid_t
  private var waitStatus: Int32?

  init(
    executablePath: String,
    arguments: [String],
    environment: [String: String],
    workingDirectory: URL,
    outputPipe: Pipe,
    errorPipe: Pipe
  ) throws {
    var fileActions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    try rielaWorkflowCheckSpawn(
      posix_spawn_file_actions_init(&fileActions),
      operation: "initialize file actions"
    )
    try rielaWorkflowCheckSpawn(
      posix_spawnattr_init(&attributes),
      operation: "initialize spawn attributes"
    )
    defer {
      posix_spawn_file_actions_destroy(&fileActions)
      posix_spawnattr_destroy(&attributes)
    }

    let outputRead = outputPipe.fileHandleForReading.fileDescriptor
    let outputWrite = outputPipe.fileHandleForWriting.fileDescriptor
    let errorRead = errorPipe.fileHandleForReading.fileDescriptor
    let errorWrite = errorPipe.fileHandleForWriting.fileDescriptor
    try rielaWorkflowCheckSpawn(
      posix_spawn_file_actions_addopen(
        &fileActions,
        STDIN_FILENO,
        "/dev/null",
        O_RDONLY,
        0
      ),
      operation: "redirect stdin"
    )
    try rielaWorkflowCheckSpawn(
      posix_spawn_file_actions_adddup2(&fileActions, outputWrite, STDOUT_FILENO),
      operation: "redirect stdout"
    )
    try rielaWorkflowCheckSpawn(
      posix_spawn_file_actions_adddup2(&fileActions, errorWrite, STDERR_FILENO),
      operation: "redirect stderr"
    )
    for descriptor in [outputRead, outputWrite, errorRead, errorWrite] {
      try rielaWorkflowCheckSpawn(
        posix_spawn_file_actions_addclose(&fileActions, descriptor),
        operation: "close inherited pipe"
      )
    }
    try workingDirectory.path.withCString { path in
      try rielaWorkflowCheckSpawn(
        posix_spawn_file_actions_addchdir_np(&fileActions, path),
        operation: "set working directory"
      )
    }
    let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
    try rielaWorkflowCheckSpawn(
      posix_spawnattr_setflags(&attributes, flags),
      operation: "set process-group flags"
    )
    try rielaWorkflowCheckSpawn(
      posix_spawnattr_setpgroup(&attributes, 0),
      operation: "create process group"
    )

    let argv = RielaWorkflowCStringArray([executablePath] + arguments)
    let envp = RielaWorkflowCStringArray(environment.map { "\($0.key)=\($0.value)" })
    var processID = pid_t()
    let result = executablePath.withCString { executable in
      argv.withUnsafeMutableBufferPointer { argumentPointer in
        envp.withUnsafeMutableBufferPointer { environmentPointer in
          posix_spawn(
            &processID,
            executable,
            &fileActions,
            &attributes,
            argumentPointer,
            environmentPointer
          )
        }
      }
    }
    try rielaWorkflowCheckSpawn(result, operation: "spawn workflow")
    processGroupID = processID
    try? outputPipe.fileHandleForWriting.close()
    try? errorPipe.fileHandleForWriting.close()
  }

  var isRunning: Bool {
    updateWaitStatus()
    return waitStatus == nil
  }

  var terminationStatus: Int32 {
    updateWaitStatus(blocking: true)
    guard let waitStatus else {
      return -1
    }
    if waitStatus & 0x7f == 0 {
      return (waitStatus >> 8) & 0xff
    }
    return -(waitStatus & 0x7f)
  }

  private func updateWaitStatus(blocking: Bool = false) {
    guard waitStatus == nil else {
      return
    }
    var status = Int32()
    let result = waitpid(processGroupID, &status, blocking ? 0 : WNOHANG)
    if result == processGroupID {
      waitStatus = status
    }
  }
}

private final class RielaWorkflowCStringArray {
  private let values: [UnsafeMutablePointer<CChar>?]

  init(_ strings: [String]) {
    values = strings.map { strdup($0) } + [nil]
  }

  deinit {
    values.forEach { pointer in
      if let pointer {
        free(pointer)
      }
    }
  }

  func withUnsafeMutableBufferPointer<Result>(
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Result
  ) -> Result {
    var mutableValues = values
    return mutableValues.withUnsafeMutableBufferPointer { buffer in
      body(buffer.baseAddress)
    }
  }
}

private func rielaWorkflowCheckSpawn(_ result: Int32, operation: String) throws {
  guard result == 0 else {
    throw NSError(
      domain: NSPOSIXErrorDomain,
      code: Int(result),
      userInfo: [NSLocalizedDescriptionKey: "Failed to \(operation): \(String(cString: strerror(result)))"]
    )
  }
}

func noteNotebookCompactVariables(
  noteRoot: String,
  request: RielaNoteNotebookCompactRequest
) -> [String: Any] {
  [
    "noteRoot": noteRoot,
    "workflowInput": [
      "operation": "compact",
      "notebookId": request.notebookId,
      "notebookTitle": request.notebookTitle,
      "sourceNotes": request.sourceNotes.map { source in
        [
          "noteId": source.noteId,
          "noteNumber": source.noteNumber,
          "bodyMarkdown": source.bodyMarkdown
        ] as [String: Any]
      }
    ] as [String: Any]
  ]
}

func noteNotebookExpansionAnswerVariables(
  request: RielaNoteNotebookExpansionRequest
) -> [String: Any] {
  [
    "workflowInput": [
      "operation": "answer",
      "compactSummaryMarkdown": request.compactSummaryMarkdown,
      "questionMarkdown": request.questionMarkdown
    ]
  ]
}
#endif
