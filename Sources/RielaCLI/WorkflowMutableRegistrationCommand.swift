import Foundation
import RielaCore

public struct WorkflowMutableRegistrationOptions: Equatable, Sendable {
  public var inputPath: String
  public var mutable: Bool
  public var usedDeprecatedTemporaryAlias: Bool
  public var overwrite: Bool
  public var workingDirectory: String
  public var output: WorkflowOutputFormat

  public init(
    inputPath: String,
    mutable: Bool,
    usedDeprecatedTemporaryAlias: Bool = false,
    overwrite: Bool,
    workingDirectory: String,
    output: WorkflowOutputFormat
  ) {
    self.inputPath = inputPath
    self.mutable = mutable
    self.usedDeprecatedTemporaryAlias = usedDeprecatedTemporaryAlias
    self.overwrite = overwrite
    self.workingDirectory = workingDirectory
    self.output = output
  }
}

public struct MutableWorkflowRegistrationResult: Codable, Equatable, Sendable {
  public var workflowId: String
  public var scope: WorkflowScope
  public var sourceKind: WorkflowSourceKind
  public var provenance: WorkflowProvenance
  public var mutable: Bool
  public var activationState: WorkflowActivationState
  public var workflowDirectory: String
  public var inputPath: String
  public var overwritten: Bool
}

public struct MutableWorkflowRegistrationFailure: Codable, Equatable, Sendable {
  public var registered: Bool
  public var inputPath: String
  public var provenance: WorkflowProvenance
  public var error: String
  public var exitCode: Int32
}

public struct WorkflowMutableRegistrationCommand: Sendable {
  public var registry: WorkflowMutableRegistry

  public init(registry: WorkflowMutableRegistry = WorkflowMutableRegistry()) {
    self.registry = registry
  }

  public func run(_ options: WorkflowMutableRegistrationOptions) -> CLICommandResult {
    guard options.mutable else {
      return failure(options, exitCode: .usage, message: "workflow register requires --mutable")
    }
    do {
      let workingDirectory = URL(fileURLWithPath: options.workingDirectory, isDirectory: true)
      let input = absoluteURL(options.inputPath, relativeTo: workingDirectory).standardizedFileURL
      let mutation = try WorkflowRegistryService(registry: registry).register(
        input: input,
        overwrite: options.overwrite,
        workingDirectory: options.workingDirectory
      )
      guard let registered = mutation.workflow else {
        throw WorkflowRegistryError(code: .registryIOFailure, message: "registration result omitted workflow")
      }
      let result = MutableWorkflowRegistrationResult(
        workflowId: registered.workflowId,
        scope: .user,
        sourceKind: .workflow,
        provenance: .mutable,
        mutable: true,
        activationState: .active,
        workflowDirectory: registered.workflowDirectory,
        inputPath: input.path,
        overwritten: mutation.overwritten
      )
      return CLICommandResult(exitCode: .success, stdout: try render(result, output: options.output))
    } catch let error as CLIUsageError {
      return failure(options, exitCode: .usage, message: error.message)
    } catch {
      return failure(options, exitCode: .failure, message: "mutable workflow registration failed: \(error)")
    }
  }

  private func render(
    _ result: MutableWorkflowRegistrationResult,
    output: WorkflowOutputFormat
  ) throws -> String {
    switch output {
    case .json, .jsonl:
      return try jsonString(result)
    case .text:
      return "registered mutable workflow \(result.workflowId) at \(result.workflowDirectory)\n"
    case .table:
      return [
        "WORKFLOW\tSCOPE\tSOURCE\tPROVENANCE\tMUTABLE\tACTIVATION\tOVERWRITTEN\tDIRECTORY",
        "\(result.workflowId)\tuser\tworkflow\tmutable\ttrue\tactive\t\(result.overwritten)\t\(result.workflowDirectory)"
      ].joined(separator: "\n") + "\n"
    }
  }

  private func failure(
    _ options: WorkflowMutableRegistrationOptions,
    exitCode: CLIExitCode,
    message: String
  ) -> CLICommandResult {
    guard options.output.isStructured else {
      return CLICommandResult(exitCode: exitCode, stderr: message + "\n")
    }
    let result = MutableWorkflowRegistrationFailure(
      registered: false,
      inputPath: options.inputPath,
      provenance: .mutable,
      error: message,
      exitCode: exitCode.rawValue
    )
    return CLICommandResult(
      exitCode: exitCode,
      stdout: (try? jsonString(result)) ?? ""
    )
  }
}

public let workflowRegisterHelpText = """
Usage:
  riela workflow register <path> --mutable [--overwrite]
    [--working-dir <dir>] [--output jsonl|json|text|table]

Registers a validated mutable workflow in the user registry.
--mutable is required. --temporary is a deprecated alias supported until the next major release.
--overwrite replaces an existing mutable workflow with the same workflowId.
""" + "\n"
