import Foundation
import RielaAdapters
import RielaAddons
import RielaCore
import RielaEvents
import RielaGraphQL
import RielaHook
import RielaServer

public struct WorkflowCheckoutCommandResult: Codable, Equatable, Sendable {
  public var workflowName: String
  public var sourceDirectory: String
  public var destinationDirectory: String
  public var scope: WorkflowScope
  public var overwritten: Bool
}

public struct WorkflowCreateCommandResult: Codable, Equatable, Sendable {
  public var workflowName: String
  public var workflowDirectory: String
  public var scope: WorkflowScope
  public var files: [String]
}

public struct WorkflowSelfImproveCommandResult: Codable, Equatable, Sendable {
  public var workflowName: String
  public var dryRun: Bool
  public var mutated: Bool
  public var backupDirectory: String?
  public var reportPath: String?
  public var report: [String]
}

public struct WorkflowPackageCommandResult: Codable, Equatable, Sendable {
  public var scope: String
  public var command: String
  public var target: String?
  public var packages: [WorkflowPackageSummary]
  public var destinationDirectory: String?
  public var dryRun: Bool
  public var message: String
  public var runSessionId: String?
}

public struct WorkflowPackageSummary: Codable, Equatable, Sendable {
  public var name: String
  public var version: String?
  public var kind: WorkflowPackageKind
  public var packageDirectory: String
  public var workflowDirectory: String?
  public var valid: Bool
  public var issues: [WorkflowPackageValidationIssue]
}

public struct WorkflowPackageRegistryConfig: Codable, Equatable, Sendable {
  public var defaultRegistryId: String
  public var registries: [WorkflowPackageRegistryEntry]
}

public struct WorkflowPackageRegistryEntry: Codable, Equatable, Sendable {
  public var id: String
  public var url: String
  public var defaultBranch: String
  public var localPath: String?
  public var registeredAt: String
  public var updatedAt: String
}

public struct ScopedParityCommandResult: Codable, Equatable, Sendable {
  public var scope: String
  public var command: String?
  public var target: String?
  public var status: String
  public var records: [String]
}

public struct WorkflowScaffoldCommand: Sendable {
  public init() {}

  public func checkout(_ options: CLICommandOptions) -> CLICommandResult {
    do {
      guard let checkoutTarget = options.target, !checkoutTarget.isEmpty else {
        throw CLIUsageError("workflow checkout requires a GitHub workflow directory URL")
      }
      let parsed = try ParsedParityOptions(options.arguments)
      let workflowName: String
      if isGitHubWorkflowDirectoryURL(checkoutTarget) {
        workflowName = try workflowNameFromGitHubDirectoryURL(checkoutTarget)
      } else if parsed.source != nil {
        workflowName = checkoutTarget
      } else {
        throw CLIUsageError("workflow checkout requires a GitHub workflow directory URL")
      }
      guard isSafeScopedWorkflowName(workflowName) else {
        throw CLIUsageError("invalid scoped workflow name '\(workflowName)'")
      }
      let workingDirectory = URL(fileURLWithPath: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath, isDirectory: true)
      let destinationScope = parsed.scope
      let destinationRoot = scopedWorkflowRoot(scope: destinationScope, workingDirectory: workingDirectory)
      let destination = destinationRoot.appendingPathComponent(workflowName, isDirectory: true)
      let source = try checkoutSource(workflowName: workflowName, checkoutTarget: checkoutTarget, parsed: parsed, workingDirectory: workingDirectory)
      let existed = FileManager.default.fileExists(atPath: destination.path)
      if existed {
        guard parsed.overwrite else {
          throw CLIUsageError("workflow checkout destination already exists: \(destination.path); pass --overwrite to replace it")
        }
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: source, to: destination)
      try writeWorkflowCheckoutRecord(
        workflowName: workflowName,
        checkoutTarget: checkoutTarget,
        source: source,
        destination: destination,
        scope: destinationScope,
        workingDirectory: workingDirectory
      )
      let result = WorkflowCheckoutCommandResult(
        workflowName: workflowName,
        sourceDirectory: source.path,
        destinationDirectory: destination.path,
        scope: destinationScope,
        overwritten: existed
      )
      return try render(result, options: options) { result in
        "checked out workflow \(result.workflowName) to \(result.destinationDirectory)\n"
      }
    } catch let error as CLIUsageError {
      return failure(error.message, output: options.output, options: options)
    } catch {
      return failure("\(error)", output: options.output, options: options)
    }
  }

  public func create(_ options: CLICommandOptions) -> CLICommandResult {
    do {
      guard let workflowName = options.target, !workflowName.isEmpty else {
        throw CLIUsageError("workflow create requires a workflow name")
      }
      guard isSafeScopedWorkflowName(workflowName) else {
        throw CLIUsageError("invalid scoped workflow name '\(workflowName)'")
      }
      let parsed = try ParsedParityOptions(options.arguments)
      let workingDirectory = URL(fileURLWithPath: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath, isDirectory: true)
      let destinationRoot = parsed.destination.map { absoluteURL($0, relativeTo: workingDirectory) }
        ?? scopedWorkflowRoot(scope: parsed.scope, workingDirectory: workingDirectory)
      let workflowDirectory = destinationRoot.appendingPathComponent(workflowName, isDirectory: true)
      if FileManager.default.fileExists(atPath: workflowDirectory.path) {
        guard parsed.overwrite else {
          throw CLIUsageError("workflow create destination already exists: \(workflowDirectory.path); pass --overwrite to replace it")
        }
        try FileManager.default.removeItem(at: workflowDirectory)
      }
      let nodesDirectory = workflowDirectory.appendingPathComponent("nodes", isDirectory: true)
      try FileManager.default.createDirectory(at: nodesDirectory, withIntermediateDirectories: true)
      let workflowPath = workflowDirectory.appendingPathComponent("workflow.json")
      let nodePath = nodesDirectory.appendingPathComponent("node-main-worker.json")
      try scaffoldWorkflowJSON(workflowName: workflowName).write(to: workflowPath, atomically: true, encoding: .utf8)
      try scaffoldNodeJSON().write(to: nodePath, atomically: true, encoding: .utf8)
      let result = WorkflowCreateCommandResult(
        workflowName: workflowName,
        workflowDirectory: workflowDirectory.path,
        scope: parsed.scope,
        files: [workflowPath.path, nodePath.path]
      )
      return try render(result, options: options) { result in
        "created workflow \(result.workflowName) at \(result.workflowDirectory)\n"
      }
    } catch let error as CLIUsageError {
      return failure(error.message, output: options.output, options: options)
    } catch {
      return failure("\(error)", output: options.output, options: options)
    }
  }

  public func selfImprove(_ options: CLICommandOptions) -> CLICommandResult {
    do {
      guard let workflowName = options.target, !workflowName.isEmpty else {
        throw CLIUsageError("workflow self-improve requires a workflow name")
      }
      let parsed = try ParsedParityOptions(options.arguments)
      let workingDirectory = URL(fileURLWithPath: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath, isDirectory: true)
      let bundle = try FileSystemWorkflowBundleResolver().resolve(WorkflowResolutionOptions(
        workflowName: workflowName,
        scope: parsed.scope,
        workflowDefinitionDir: parsed.workflowDefinitionDir,
        workingDirectory: workingDirectory.path
      ))
      let report: [String]
      let backupDirectory: String?
      let reportPath: String?
      if parsed.dryRun {
        backupDirectory = nil
        reportPath = nil
        report = [
          "Swift self-improve dry run completed without mutation.",
          "dryRun=true",
          "workflow=\(workflowName)",
          "workflowDirectory=\(bundle.workflowDirectory)",
          "steps=\(bundle.workflow.steps.count)"
        ]
      } else {
        guard parsed.overwrite else {
          throw CLIUsageError("workflow self-improve write mode needs explicit --yes or --force approval")
        }
        let mutation = try applySelfImproveMutation(
          workflowName: workflowName,
          workflowDirectory: URL(fileURLWithPath: bundle.workflowDirectory, isDirectory: true),
          workingDirectory: workingDirectory
        )
        backupDirectory = mutation.backupDirectory
        reportPath = mutation.reportPath
        report = mutation.report
      }
      let result = WorkflowSelfImproveCommandResult(
        workflowName: workflowName,
        dryRun: parsed.dryRun,
        mutated: !parsed.dryRun,
        backupDirectory: backupDirectory,
        reportPath: reportPath,
        report: report
      )
      return try render(result, options: options) { result in
        result.report.joined(separator: "\n") + "\n"
      }
    } catch let error as CLIUsageError {
      return failure(error.message, output: options.output, options: options)
    } catch {
      return failure("\(error)", output: options.output, options: options)
    }
  }

  private struct SelfImproveMutationResult {
    var backupDirectory: String
    var reportPath: String
    var report: [String]
  }

  private func applySelfImproveMutation(
    workflowName: String,
    workflowDirectory: URL,
    workingDirectory: URL
  ) throws -> SelfImproveMutationResult {
    let workflowJSON = workflowDirectory.appendingPathComponent("workflow.json")
    guard FileManager.default.fileExists(atPath: workflowJSON.path) else {
      throw CLIUsageError("workflow self-improve requires workflow.json at \(workflowJSON.path)")
    }
    let stamp = "2026-06-16T00-00-00Z"
    let backupDirectory = workingDirectory
      .appendingPathComponent(".riela/self-improve/backups", isDirectory: true)
      .appendingPathComponent("\(workflowName)-\(stamp)", isDirectory: true)
    let reportDirectory = workingDirectory.appendingPathComponent(".riela/self-improve/reports", isDirectory: true)
    let reportURL = reportDirectory.appendingPathComponent("\(workflowName)-\(stamp).json")
    try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
    let backupWorkflow = backupDirectory.appendingPathComponent("workflow.json")
    if FileManager.default.fileExists(atPath: backupWorkflow.path) {
      try FileManager.default.removeItem(at: backupWorkflow)
    }
    try FileManager.default.copyItem(at: workflowJSON, to: backupWorkflow)

    let data = try Data(contentsOf: workflowJSON)
    guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw CLIUsageError("workflow self-improve requires workflow.json root object")
    }
    let reviewedDescription = "self-improve-reviewed"
    if let existingDescription = object["description"] as? String, !existingDescription.contains(reviewedDescription) {
      object["description"] = "\(existingDescription) \(reviewedDescription)"
    } else if object["description"] == nil {
      object["description"] = reviewedDescription
    }
    object["selfImproveMutation"] = [
      "mode": "reviewed-patch",
      "reviewedAt": stamp,
      "rollbackMetadata": backupWorkflow.path
    ]
    let updated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try updated.write(to: workflowJSON, options: .atomic)

    let markerURL = workflowDirectory.appendingPathComponent(".riela-self-improve-patch.json")
    try jsonString([
      "workflowName": .string(workflowName),
      "mode": .string("reviewed-patch"),
      "backupWorkflow": .string(backupWorkflow.path),
      "reportPath": .string(reportURL.path),
      "rollbackMetadata": .string(backupWorkflow.path)
    ] as JSONObject).write(to: markerURL, atomically: true, encoding: .utf8)
    try jsonString([
      "workflowName": .string(workflowName),
      "mutated": .bool(true),
      "mutationMode": .string("reviewed-patch"),
      "backupDirectory": .string(backupDirectory.path),
      "rollbackMetadata": .string(backupWorkflow.path),
      "workflowJSON": .string(workflowJSON.path)
    ] as JSONObject).write(to: reportURL, atomically: true, encoding: .utf8)

    return SelfImproveMutationResult(
      backupDirectory: backupDirectory.path,
      reportPath: reportURL.path,
      report: [
        "Swift self-improve write mode applied reviewed patch.",
        "dryRun=false",
        "workflow=\(workflowName)",
        "workflowDirectory=\(workflowDirectory.path)",
        "backupDirectory=\(backupDirectory.path)",
        "reportPath=\(reportURL.path)",
        "rollbackMetadata=\(backupWorkflow.path)"
      ]
    )
  }

  private func checkoutSource(workflowName: String, checkoutTarget: String, parsed: ParsedParityOptions, workingDirectory: URL) throws -> URL {
    if let source = parsed.source {
      let url = absoluteURL(source, relativeTo: workingDirectory)
      let workflowJSON = url.appendingPathComponent("workflow.json")
      guard FileManager.default.fileExists(atPath: workflowJSON.path) else {
        throw CLIUsageError("workflow checkout source must contain workflow.json: \(url.path)")
      }
      return url
    }
    if isGitHubWorkflowDirectoryURL(checkoutTarget) {
      return try resolveGitHubWorkflowDirectory(checkoutTarget, workingDirectory: workingDirectory)
    }
    let roots = [scopedWorkflowRoot(scope: .project, workingDirectory: workingDirectory), scopedWorkflowRoot(scope: .user, workingDirectory: workingDirectory)]
    for root in roots {
      let candidate = root.appendingPathComponent(workflowName, isDirectory: true)
      if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("workflow.json").path) {
        return candidate
      }
    }
    throw CLIUsageError("workflow checkout source not found for \(workflowName); pass --source <workflow-dir>")
  }

  private func isGitHubWorkflowDirectoryURL(_ value: String) -> Bool {
    guard let url = URL(string: value), url.scheme == "https", url.host == "github.com" else {
      return false
    }
    return url.pathComponents.contains("tree")
  }

  private struct GitHubWorkflowDirectoryReference {
    var owner: String
    var repository: String
    var branch: String
    var workflowPath: String
  }

  private func resolveGitHubWorkflowDirectory(_ value: String, workingDirectory: URL) throws -> URL {
    let reference = try parseGitHubWorkflowDirectoryURL(value)
    let cacheRoot = workingDirectory.appendingPathComponent(".riela/workflow-checkout-sources", isDirectory: true)
    let cacheDirectory = cacheRoot.appendingPathComponent(gitHubCheckoutCacheKey(reference), isDirectory: true)
    let workflowDirectory = cacheDirectory.appendingPathComponent(reference.workflowPath, isDirectory: true)
    if FileManager.default.fileExists(atPath: workflowDirectory.appendingPathComponent("workflow.json").path) {
      return workflowDirectory
    }
    if FileManager.default.fileExists(atPath: cacheDirectory.path) {
      try FileManager.default.removeItem(at: cacheDirectory)
    }
    try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    let repositoryURL = "https://github.com/\(reference.owner)/\(reference.repository).git"
    try runGit(["clone", "--depth", "1", "--filter=blob:none", "--sparse", "--branch", reference.branch, repositoryURL, cacheDirectory.path])
    try runGit(["-C", cacheDirectory.path, "sparse-checkout", "set", reference.workflowPath])
    guard FileManager.default.fileExists(atPath: workflowDirectory.appendingPathComponent("workflow.json").path) else {
      throw CLIUsageError("workflow checkout GitHub URL did not resolve to a workflow.json: \(value)")
    }
    return workflowDirectory
  }

  private func parseGitHubWorkflowDirectoryURL(_ value: String) throws -> GitHubWorkflowDirectoryReference {
    guard let url = URL(string: value), url.scheme == "https", url.host == "github.com" else {
      throw CLIUsageError("workflow checkout requires a GitHub workflow directory URL")
    }
    let components = url.pathComponents.filter { $0 != "/" }
    guard components.count >= 5, components[2] == "tree" else {
      throw CLIUsageError("workflow checkout requires a GitHub workflow directory URL")
    }
    let owner = components[0]
    let repository = components[1]
    let branch = components[3]
    let workflowPath = components.dropFirst(4).joined(separator: "/")
    guard
      isSafeGitHubCheckoutComponent(owner),
      isSafeGitHubCheckoutComponent(repository),
      isSafeGitHubCheckoutComponent(branch),
      !workflowPath.isEmpty,
      workflowPath.split(separator: "/").allSatisfy({ isSafeGitHubCheckoutComponent(String($0)) })
    else {
      throw CLIUsageError("workflow checkout GitHub URL contains unsafe path components")
    }
    return GitHubWorkflowDirectoryReference(owner: owner, repository: repository, branch: branch, workflowPath: workflowPath)
  }

  private func gitHubCheckoutCacheKey(_ reference: GitHubWorkflowDirectoryReference) -> String {
    let raw = [reference.owner, reference.repository, reference.branch, reference.workflowPath].joined(separator: "-")
    let sanitized = raw.unicodeScalars.map { scalar in
      isParityASCIIAlphaNumeric(scalar) || scalar == "." || scalar == "_" || scalar == "-"
        ? String(Character(scalar))
        : "-"
    }.joined()
    return "github-\(sanitized)"
  }

  private func isSafeGitHubCheckoutComponent(_ value: String) -> Bool {
    guard !value.isEmpty, value != ".", value != "..", value.unicodeScalars.count <= 120 else {
      return false
    }
    return value.unicodeScalars.allSatisfy { scalar in
      isParityASCIIAlphaNumeric(scalar) || scalar == "." || scalar == "_" || scalar == "-"
    }
  }

  private func runGit(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    let stderrPipe = Pipe()
    process.standardError = stderrPipe
    process.standardOutput = Pipe()
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      throw CLIUsageError("workflow checkout failed to start git: \(error)")
    }
    guard process.terminationStatus == 0 else {
      let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw CLIUsageError("workflow checkout git failed: \(stderr ?? "exit \(process.terminationStatus)")")
    }
  }

  private func workflowNameFromGitHubDirectoryURL(_ value: String) throws -> String {
    guard let url = URL(string: value), url.host == "github.com" else {
      throw CLIUsageError("workflow checkout requires a GitHub workflow directory URL")
    }
    let components = url.pathComponents.filter { $0 != "/" }
    guard let treeIndex = components.firstIndex(of: "tree"), components.count > treeIndex + 2 else {
      throw CLIUsageError("workflow checkout requires a GitHub workflow directory URL")
    }
    let name = components.last ?? ""
    guard isSafeScopedWorkflowName(name) else {
      throw CLIUsageError("invalid scoped workflow name '\(name)'")
    }
    return name
  }

  private func writeWorkflowCheckoutRecord(
    workflowName: String,
    checkoutTarget: String,
    source: URL,
    destination: URL,
    scope: WorkflowScope,
    workingDirectory: URL
  ) throws {
    let recordRoot = workingDirectory.appendingPathComponent(".riela/workflow-checkouts", isDirectory: true)
    try FileManager.default.createDirectory(at: recordRoot, withIntermediateDirectories: true)
    try jsonString([
      "workflowName": .string(workflowName),
      "checkoutUrl": .string(checkoutTarget),
      "sourceDirectory": .string(source.path),
      "destinationDirectory": .string(destination.path),
      "scope": .string(scope.rawValue),
      "installType": .string("workflow-checkout"),
      "managedBy": .string("workflow checkout")
    ] as JSONObject).write(to: recordRoot.appendingPathComponent("\(workflowName).json"), atomically: true, encoding: .utf8)
  }
}
