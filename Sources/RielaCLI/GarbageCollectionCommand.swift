import Foundation
import ArgumentParser
import RielaCore

public struct GarbageCollectionCommand: Sendable {
  public init() {}

  public func run(_ options: CLICommandOptions) -> CLICommandResult {
    let parsed: ParsedGarbageCollectionOptions
    do {
      parsed = try ParsedGarbageCollectionOptions.parse(options.arguments)
    } catch {
      let message = ParsedGarbageCollectionOptions.fullMessage(for: error)
      if options.arguments.contains("--help") || options.arguments.contains("-h") {
        return CLICommandResult(exitCode: .success, stdout: message + "\n")
      }
      return CLICommandResult(exitCode: .usage, stderr: message)
    }
    do {
      let environment = CLIRuntimeEnvironment.mergedProcessEnvironment()
      let homeDirectory = URL(
        fileURLWithPath: CLIRuntimeEnvironment.homeDirectory(environment: environment),
        isDirectory: true
      )
      let configuration = try RielaGarbageCollectionConfiguration.load(
        homeDirectory: homeDirectory,
        environment: environment
      )
      let retentionDays = parsed.retentionDays ?? configuration.gc.retentionDays
      let report = RielaDataGarbageCollector().collect(
        retentionDays: retentionDays,
        scope: parsed.scope,
        homeDirectory: homeDirectory,
        projectDirectory: URL(fileURLWithPath: parsed.workingDirectory, isDirectory: true),
        dryRun: parsed.dryRun
      )
      if options.output.isStructured {
        return CLICommandResult(exitCode: .success, stdout: try jsonString(report))
      }
      return CLICommandResult(exitCode: .success, stdout: renderText(report))
    } catch let error as CLIUsageError {
      return CLICommandResult(exitCode: .usage, stderr: error.message)
    } catch {
      return CLICommandResult(exitCode: .failure, stderr: error.localizedDescription)
    }
  }

  private func renderText(_ report: RielaGarbageCollectionReport) -> String {
    guard report.enabled else {
      return "GC is off. Configure gc.retentionDays in ~/.riela/config.json, set RIELA_GC_RETENTION_DAYS, or pass --retention-days.\n"
    }
    let mode = report.dryRun ? "Would remove" : "Removed"
    var lines = [
      "\(mode) \(report.removedSessionCount) session(s) and \(report.removedEntryCount) stored entries.",
      "Reclaimable bytes: \(report.reclaimedBytes)",
      "Retention: \(report.retentionDays ?? 0) day(s)"
    ]
    lines.append(contentsOf: report.diagnostics.map { "Warning: \($0)" })
    return lines.joined(separator: "\n") + "\n"
  }
}

private struct ParsedGarbageCollectionOptions: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "riela gc",
    abstract: "Remove expired Riela runtime data."
  )

  @Option(help: "Remove generated data older than this number of days.")
  var retentionDays: Int?

  @Option(help: "Storage scope to collect: user, project, or all.")
  var scope: RielaGarbageCollectionScope = .all

  @Option(name: [.customLong("working-dir"), .customLong("working-directory")])
  var workingDirectory = FileManager.default.currentDirectoryPath

  @Flag(help: "Report what would be removed without changing files.")
  var dryRun = false

  @Option(help: ArgumentHelp("Output format.", valueName: "text|json|jsonl"))
  var output: String = "text"

  mutating func validate() throws {
    if let retentionDays, retentionDays <= 0 {
      throw ValidationError("--retention-days requires a positive integer")
    }
  }
}

extension RielaGarbageCollectionScope: ExpressibleByArgument {}
