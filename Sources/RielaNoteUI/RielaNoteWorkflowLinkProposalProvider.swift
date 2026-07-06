import Foundation

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

public struct RielaWorkflowNoteLinkProposalProvider: RielaNoteLinkProposalProviding {
  public var workflowDefinitionDirectory: String
  public var executablePath: String?
  public var environment: [String: String]

  public init(
    workflowDefinitionDirectory: String,
    executablePath: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.workflowDefinitionDirectory = workflowDefinitionDirectory
    self.executablePath = executablePath
    self.environment = environment
  }

  public func proposeLinkDrafts(
    noteId: String,
    noteRoot: String,
    query: String,
    limit: Int
  ) async throws -> [RielaNoteLinkProposalDraft] {
    try await Task.detached {
      try runNoteLinkExtractWorkflow(
        executablePath: resolvedRielaExecutablePath(executablePath, environment: environment),
        workflowDefinitionDirectory: workflowDefinitionDirectory,
        noteId: noteId,
        noteRoot: noteRoot,
        query: query,
        limit: limit,
        environment: environment
      )
    }.value
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
  environment: [String: String]
) throws -> [RielaNoteLinkProposalDraft] {
  let process = Process()
  let executableArguments: [String]
  if executablePath == "/usr/bin/env" {
    process.executableURL = URL(fileURLWithPath: executablePath)
    executableArguments = ["riela"] + noteLinkExtractArguments(
      workflowDefinitionDirectory: workflowDefinitionDirectory,
      noteId: noteId,
      noteRoot: noteRoot,
      query: query,
      limit: limit
    )
  } else {
    process.executableURL = URL(fileURLWithPath: executablePath)
    executableArguments = noteLinkExtractArguments(
      workflowDefinitionDirectory: workflowDefinitionDirectory,
      noteId: noteId,
      noteRoot: noteRoot,
      query: query,
      limit: limit
    )
  }
  process.arguments = executableArguments
  process.environment = environment
  let outputPipe = Pipe()
  let errorPipe = Pipe()
  process.standardOutput = outputPipe
  process.standardError = errorPipe
  try process.run()
  process.waitUntilExit()
  let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
  let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
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
  limit: Int
) -> [String] {
  let variables: [String: Any] = [
    "noteRoot": noteRoot,
    "workflowInput": [
      "noteId": noteId,
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
}
