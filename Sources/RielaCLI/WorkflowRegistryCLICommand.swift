import ArgumentParser
import Foundation
import RielaCore

private struct ParsedWorkflowRegistryTargetOptions: RielaClientFamilyArguments {
  @Option var scope = "auto"
  @Option var originId: String?
  @Option(name: [.customLong("working-dir"), .customLong("working-directory")])
  var workingDirectory = FileManager.default.currentDirectoryPath
  @Option var output: WorkflowOutputFormat?
}

private struct ParsedWorkflowRegistryUpdateOptions: RielaClientFamilyArguments {
  @Argument var inputPath: String
  @Option var scope = "auto"
  @Option var originId: String?
  @Option(name: [.customLong("working-dir"), .customLong("working-directory")])
  var workingDirectory = FileManager.default.currentDirectoryPath
  @Option var output: WorkflowOutputFormat?
}

private struct ParsedWorkflowConsolidateOptions: RielaClientFamilyArguments {
  @Option var source: [String] = []
  @Option var sourceOrigin: [String] = []
  @Option var replacement: String
  @Option var retire: String
  @Option var scope = "auto"
  @Option(name: [.customLong("working-dir"), .customLong("working-directory")])
  var workingDirectory = FileManager.default.currentDirectoryPath
  @Option var output: WorkflowOutputFormat?
}

struct WorkflowRegistryCLICommand: Sendable {
  private let service = WorkflowRegistryService()

  func run(_ options: CLICommandOptions) -> CLICommandResult {
    do {
      let result: WorkflowRegistryMutationResult
      switch options.command {
      case "update":
        let workflowId = try requiredTarget(options)
        let parsed = try ParsedWorkflowRegistryUpdateOptions.parseCLI(options.arguments)
        result = try service.update(
          target: try target(workflowId: workflowId, scope: parsed.scope, originId: parsed.originId),
          input: absoluteURL(
            parsed.inputPath,
            relativeTo: URL(fileURLWithPath: parsed.workingDirectory, isDirectory: true)
          ),
          workingDirectory: parsed.workingDirectory
        )
      case "delete", "activate", "deactivate":
        let workflowId = try requiredTarget(options)
        let parsed = try ParsedWorkflowRegistryTargetOptions.parseCLI(options.arguments)
        let target = try target(workflowId: workflowId, scope: parsed.scope, originId: parsed.originId)
        if options.command == "delete" {
          result = try service.delete(target: target, workingDirectory: parsed.workingDirectory)
        } else {
          let state: WorkflowActivationState = options.command == "activate" ? .active : .deactivated
          result = try service.setActivation(state, target: target, workingDirectory: parsed.workingDirectory)
        }
      case "consolidate":
        let parsed = try ParsedWorkflowConsolidateOptions.parseCLI(options.arguments)
        guard parsed.source.count >= 2 else {
          throw CLIUsageError("workflow consolidate requires at least two --source values")
        }
        guard let scope = WorkflowRegistryScope(rawValue: parsed.scope), scope != .direct else {
          throw CLIUsageError("invalid --scope value; expected auto, project, or user")
        }
        guard let retireMode = WorkflowRetireMode(rawValue: parsed.retire) else {
          throw WorkflowRegistryError(code: .invalidRetireMode, message: "--retire must be deactivate or delete")
        }
        let originIds = try sourceOrigins(parsed.sourceOrigin)
        let sources = parsed.source.map {
          WorkflowRegistryTarget(workflowId: $0, scope: scope, originId: originIds[$0])
        }
        result = try service.consolidate(
          sources: sources,
          replacement: absoluteURL(
            parsed.replacement,
            relativeTo: URL(fileURLWithPath: parsed.workingDirectory, isDirectory: true)
          ),
          retireMode: retireMode,
          workingDirectory: parsed.workingDirectory
        )
      default:
        throw CLIUsageError("unsupported workflow registry command")
      }
      return CLICommandResult(exitCode: .success, stdout: try render(result, output: options.output))
    } catch let error as WorkflowRegistryError {
      return failure(error, output: options.output)
    } catch let error as CLIUsageError {
      return failure(
        WorkflowRegistryError(code: .invalidWorkflow, message: error.message, workflowId: options.target),
        output: options.output,
        exitCode: .usage
      )
    } catch {
      return failure(
        WorkflowRegistryError(code: .registryIOFailure, message: "\(error)", workflowId: options.target),
        output: options.output
      )
    }
  }

  private func requiredTarget(_ options: CLICommandOptions) throws -> String {
    guard let target = options.target, !target.isEmpty else {
      throw CLIUsageError("workflow \(options.command ?? "mutation") requires a workflow id")
    }
    return target
  }

  private func target(workflowId: String, scope: String, originId: String?) throws -> WorkflowRegistryTarget {
    guard let parsedScope = WorkflowRegistryScope(rawValue: scope), parsedScope != .direct else {
      throw CLIUsageError("invalid --scope value; expected auto, project, or user")
    }
    return WorkflowRegistryTarget(workflowId: workflowId, scope: parsedScope, originId: originId)
  }

  private func sourceOrigins(_ values: [String]) throws -> [String: String] {
    var result: [String: String] = [:]
    for value in values {
      let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
      guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, result[parts[0]] == nil else {
        throw WorkflowRegistryError(
          code: .invalidOrigin,
          message: "--source-origin must use unique WORKFLOW_ID=ORIGIN_ID values"
        )
      }
      result[parts[0]] = parts[1]
    }
    return result
  }

  private func render(_ result: WorkflowRegistryMutationResult, output: WorkflowOutputFormat) throws -> String {
    switch output {
    case .json, .jsonl:
      return try jsonString(result)
    case .text, .table:
      if let workflow = result.workflow {
        return "accepted: \(workflow.workflowId) \(workflow.provenance.rawValue) \(workflow.activationState.rawValue)\n"
      }
      let retired = result.retiredWorkflows.map(\.workflowId).joined(separator: ",")
      return "accepted: true retired: \(retired)\n"
    }
  }

  private func failure(
    _ error: WorkflowRegistryError,
    output: WorkflowOutputFormat,
    exitCode: CLIExitCode = .failure
  ) -> CLICommandResult {
    if output.isStructured {
      let result = WorkflowRegistryMutationResult(accepted: false, errors: [error])
      return CLICommandResult(exitCode: exitCode, stdout: (try? jsonString(result)) ?? "")
    }
    return CLICommandResult(exitCode: exitCode, stderr: "\(error.code.rawValue): \(error.message)\n")
  }
}
