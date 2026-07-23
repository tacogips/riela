import ArgumentParser
import Foundation
import RielaCore

public struct SessionDiscoveryCommand: Sendable {
  public init() {}

  public func run(_ options: CLICommandOptions) -> CLICommandResult {
    do {
      let parsed = try parseOptions(options.arguments)
      if options.command == "latest", parsed.workflowName == nil {
        throw CLIUsageError("session latest requires --workflow <name>")
      }
      let storeRoot = CLIWorkflowSessionStore.resolveRootDirectory(
        sessionStore: parsed.sessionStore,
        scope: parsed.scope,
        workingDirectory: parsed.workingDirectory
      )
      let limit = options.command == "latest" ? 1 : parsed.limit
      let rows = try CLIWorkflowSessionStore(rootDirectory: storeRoot)
        .list(workflowName: parsed.workflowName, status: parsed.status, limit: limit)
        .map { SessionDiscoveryRow(record: $0, sessionStore: storeRoot) }
      if options.command == "latest" {
        guard let latest = rows.first else {
          return failure(output: options.output, error: "session not found", exitCode: .failure)
        }
        return renderLatest(latest, output: options.output)
      }
      return renderList(rows, output: options.output)
    } catch let error as CLIUsageError {
      return CLICommandResult(exitCode: .usage, stderr: error.message)
    } catch {
      return failure(output: options.output, error: "\(error)", exitCode: .failure)
    }
  }

  private struct ParsedOptions: ParsableArguments {
    @Option(name: .customLong("workflow")) var workflowName: String?
    @Option(name: .customLong("status")) private var statusRawValue: String?
    @Option var limit = 10
    @Option var scope = WorkflowScope.auto
    @Option(name: [.customLong("working-dir"), .customLong("working-directory")])
    var workingDirectory = FileManager.default.currentDirectoryPath
    @Option var sessionStore: String?
    @Option private var output: String?
    var status: WorkflowSessionStatus?

    init() {}

    init(_ arguments: [String]) throws {
      do {
        self = try Self.parse(arguments)
      } catch {
        throw CLIUsageError(Self.message(for: error))
      }
      if let statusRawValue {
        guard let status = WorkflowSessionStatus(rawValue: statusRawValue) else {
          throw CLIUsageError("invalid --status value; expected created, running, completed, or failed")
        }
        self.status = status
      }
      guard limit > 0 else {
        throw CLIUsageError("--limit requires a positive integer")
      }
      limit = min(limit, 100)
      guard scope != .direct else {
        throw CLIUsageError("invalid --scope value; expected auto, project, or user")
      }
    }
  }

  private func parseOptions(_ arguments: [String]) throws -> ParsedOptions {
    try ParsedOptions(arguments)
  }

  private func renderList(_ rows: [SessionDiscoveryRow], output: WorkflowOutputFormat) -> CLICommandResult {
    switch output {
    case .json, .jsonl:
      return CLICommandResult(exitCode: .success, stdout: (try? jsonString(rows)) ?? "[]\n")
    case .text, .table:
      let lines = rows.map { row in
        [
          row.sessionId,
          row.workflowName,
          row.status.rawValue,
          row.failureKind?.rawValue ?? "-",
          row.currentStepId ?? "-",
          String(row.executionCount),
          sessionDiscoveryISO8601String(row.updatedAt),
          row.sessionStore,
          row.parentSessionId ?? "-",
          row.rootSessionId
        ].joined(separator: "\t")
      }
      return CLICommandResult(
        exitCode: .success,
        stdout: lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
      )
    }
  }

  private func renderLatest(_ row: SessionDiscoveryRow, output: WorkflowOutputFormat) -> CLICommandResult {
    switch output {
    case .json, .jsonl:
      return CLICommandResult(exitCode: .success, stdout: (try? jsonString(row)) ?? "{}\n")
    case .text, .table:
      return CLICommandResult(
        exitCode: .success,
        stdout: """
        sessionId: \(row.sessionId)
        parentSessionId: \(row.parentSessionId ?? "-")
        rootSessionId: \(row.rootSessionId)
        workflow: \(row.workflowName)
        status: \(row.status.rawValue)
        failureKind: \(row.failureKind?.rawValue ?? "-")
        currentStepId: \(row.currentStepId ?? "-")
        executionCount: \(row.executionCount)
        updatedAt: \(sessionDiscoveryISO8601String(row.updatedAt))
        sessionStore: \(row.sessionStore)

        """
      )
    }
  }

  private func failure(
    output: WorkflowOutputFormat,
    error: String,
    exitCode: CLIExitCode
  ) -> CLICommandResult {
    guard output.isStructured else {
      return CLICommandResult(exitCode: exitCode, stderr: error)
    }
    let payload = SessionCommandFailureResult(
      sessionId: "",
      error: error,
      exitCode: exitCode.rawValue
    )
    return CLICommandResult(exitCode: exitCode, stdout: (try? jsonString(payload)) ?? "")
  }
}

private func sessionDiscoveryISO8601String(_ date: Date) -> String {
  ISO8601DateFormatter().string(from: date)
}
