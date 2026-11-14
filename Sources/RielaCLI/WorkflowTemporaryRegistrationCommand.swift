import Foundation

public struct WorkflowTemporaryRegistrationOptions: Equatable, Sendable {
  public var inputPath: String
  public var temporary: Bool
  public var overwrite: Bool
  public var workingDirectory: String
  public var output: WorkflowOutputFormat

  public init(
    inputPath: String,
    temporary: Bool,
    overwrite: Bool,
    workingDirectory: String,
    output: WorkflowOutputFormat
  ) {
    self.inputPath = inputPath
    self.temporary = temporary
    self.overwrite = overwrite
    self.workingDirectory = workingDirectory
    self.output = output
  }
}

public struct TemporaryWorkflowRegistrationResult: Codable, Equatable, Sendable {
  public var workflowId: String
  public var scope: WorkflowScope
  public var sourceKind: WorkflowSourceKind
  public var temporary: Bool
  public var mutable: Bool
  public var workflowDirectory: String
  public var inputPath: String
  public var overwritten: Bool
}

public struct TemporaryWorkflowRegistrationFailure: Codable, Equatable, Sendable {
  public var registered: Bool
  public var inputPath: String
  public var temporary: Bool
  public var error: String
  public var exitCode: Int32
}

public struct WorkflowTemporaryRegistrationCommand: Sendable {
  public var registry: WorkflowTemporaryRegistry

  public init(registry: WorkflowTemporaryRegistry = WorkflowTemporaryRegistry()) {
    self.registry = registry
  }

  public func run(_ options: WorkflowTemporaryRegistrationOptions) -> CLICommandResult {
    guard options.temporary else {
      return failure(options, exitCode: .usage, message: "workflow register requires --temporary")
    }
    do {
      let workingDirectory = URL(fileURLWithPath: options.workingDirectory, isDirectory: true)
      let input = absoluteURL(options.inputPath, relativeTo: workingDirectory).standardizedFileURL
      let registered = try registry.register(input: input, overwrite: options.overwrite)
      let result = TemporaryWorkflowRegistrationResult(
        workflowId: registered.workflowId,
        scope: .user,
        sourceKind: .workflow,
        temporary: true,
        mutable: true,
        workflowDirectory: registered.workflowDirectory,
        inputPath: registered.inputPath,
        overwritten: registered.overwritten
      )
      return CLICommandResult(exitCode: .success, stdout: try render(result, output: options.output))
    } catch let error as CLIUsageError {
      return failure(options, exitCode: .usage, message: error.message)
    } catch {
      return failure(options, exitCode: .failure, message: "temporary workflow registration failed: \(error)")
    }
  }

  private func render(
    _ result: TemporaryWorkflowRegistrationResult,
    output: WorkflowOutputFormat
  ) throws -> String {
    switch output {
    case .json, .jsonl:
      return try jsonString(result)
    case .text:
      return "registered temporary workflow \(result.workflowId) at \(result.workflowDirectory)\n"
    case .table:
      return [
        "WORKFLOW\tSCOPE\tSOURCE\tPROVENANCE\tMUTABLE\tOVERWRITTEN\tDIRECTORY",
        "\(result.workflowId)\tuser\tworkflow\ttemporary\ttrue\t\(result.overwritten)\t\(result.workflowDirectory)"
      ].joined(separator: "\n") + "\n"
    }
  }

  private func failure(
    _ options: WorkflowTemporaryRegistrationOptions,
    exitCode: CLIExitCode,
    message: String
  ) -> CLICommandResult {
    guard options.output.isStructured else {
      return CLICommandResult(exitCode: exitCode, stderr: message + "\n")
    }
    let result = TemporaryWorkflowRegistrationFailure(
      registered: false,
      inputPath: options.inputPath,
      temporary: true,
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
  riela workflow register <path> --temporary [--overwrite]
    [--working-dir <dir>] [--output jsonl|json|text|table]

Registers a validated temporary (adhoc) workflow in the user registry.
--temporary is required. --overwrite replaces an existing workflow with the same workflowId.
""" + "\n"
