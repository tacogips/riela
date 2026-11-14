import ArgumentParser
import Foundation

struct ParsedWorkflowManifestOptions: ParsableArguments {
  @Argument var manifestPath: String?
  @Option var workflowManifest: String?
  @Option var output = WorkflowOutputFormat.jsonl
  @Flag var executable = false
  @Option(name: [.customLong("working-dir"), .customLong("working-directory")])
  var workingDirectory = FileManager.default.currentDirectoryPath

  init() {}

  init(_ tokens: [String]) throws {
    do {
      self = try Self.parse(tokens)
    } catch {
      throw CLIUsageError(Self.message(for: error))
    }
    if manifestPath != nil && workflowManifest != nil {
      throw CLIUsageError("workflow manifest validate accepts at most one manifest path")
    }
    if output == .table {
      throw CLIUsageError(
        "`--output table` is only supported for workflow list, workflow status, package search, and package list"
      )
    }
  }

  func resolvedManifestPath(environment: [String: String]) throws -> String {
    let path = manifestPath
      ?? workflowManifest
      ?? environment["RIELA_WORKFLOW_MANIFEST"].flatMap { $0.isEmpty ? nil : $0 }
    guard let path, !path.isEmpty else {
      throw CLIUsageError(
        "workflow manifest validate requires a manifest path, --workflow-manifest, or RIELA_WORKFLOW_MANIFEST"
      )
    }
    return path
  }
}
