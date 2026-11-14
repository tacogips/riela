import ArgumentParser
import Foundation
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
      let home = URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory(environment: environment), isDirectory: true)
      let request = RielaRetentionRequest(trigger: .manual, homeDirectory: home,
        projectDirectory: URL(fileURLWithPath: parsed.workingDirectory, isDirectory: true),
        explicitSessionStore: parsed.sessionStore, environment: environment, scope: parsed.scope,
        overrides: try parsed.overrides, dryRun: parsed.dryRun)
      let report = try RielaRetentionService().run(request)
      let stdout = parsed.output == "text" ? renderText(report) : try sortedJSON(report)
      return CLICommandResult(exitCode: report.hasFailure ? .failure : .success, stdout: stdout)
    } catch let error as RielaRetentionUsageError {
      return CLICommandResult(exitCode: .usage, stderr: error.localizedDescription)
    } catch let error as RielaRetentionConfigurationError {
      return CLICommandResult(exitCode: .usage, stderr: error.localizedDescription)
    } catch {
      return CLICommandResult(exitCode: .failure, stderr: error.localizedDescription)
    }
  }

  private func sortedJSON(_ report: RielaRetentionReport) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return (String(data: try encoder.encode(report), encoding: .utf8) ?? "") + "\n"
  }

  private func renderText(_ report: RielaRetentionReport) -> String {
    var lines: [String] = []
    for target in report.targets {
      lines.append("\(target.kind.rawValue) \(target.root): \(target.status)")
      lines.append(contentsOf: [renderCategory("results", target.results, dryRun: report.dryRun),
        renderCategory("messages", target.messages, dryRun: report.dryRun),
        renderCategory("logs", target.logs, dryRun: report.dryRun)])
      lines.append("generated: removed \(target.generated.removedEntryCount) (\(target.generated.removedBytes) bytes)")
      if let orphan = target.orphanLocks {
        lines.append("orphan locks: removed \(orphan.removedCount) of \(orphan.selectedCount); busy \(orphan.skippedBusy)")
      }
      lines.append(contentsOf: target.reclamation.map {
        "database \($0.action) reclaimed=\($0.reclaimedBytes) reusable=\($0.reusableFreeBytes)"
      })
      lines.append(contentsOf: target.warnings.map { "Warning: \($0)" })
    }
    return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
  }

  private func renderCategory(_ name: String, _ category: RetentionCategoryReport, dryRun: Bool) -> String {
    let verb = dryRun ? "would remove" : "removed"
    let count = dryRun ? category.selectedCount : category.removedCount
    let bytes = dryRun ? category.selectedBytes : category.removedBytes
    let cap: String
    if category.policySource == .builtInDefault {
      if let days = category.policy?.maxAgeDays {
        cap = "older than \(days) days (built-in default)"
      } else {
        cap = "follow results (built-in default)"
      }
    } else if category.state == .active {
      cap = category.capAchieved.map { $0 ? "cap achieved" : "cap not achieved" } ?? "no cap"
    } else {
      cap = category.state.rawValue
    }
    let protected = category.protected.keys.sorted().map { "\($0)=\(category.protected[$0] ?? 0)" }.joined(separator: ",")
    return "\(name): \(verb) \(count) (\(bytes) bytes); \(cap); protected: \(protected)"
  }
}

private struct ParsedGarbageCollectionOptions: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "riela gc", abstract: "Apply Riela runtime retention policy.",
    discussion: "Defaults: results and logs older than 30 days; messages follow results; no byte cap. " +
      "Set keepForever to true per category to retain it. Set automatic to false or " +
      "RIELA_RETENTION_AUTOMATIC=0 to disable automatic passes.")

  @Option(help: "Storage scope: user, project, or all.")
  var scope: RielaGarbageCollectionScope = .all

  @Option(name: [.customLong("working-dir"), .customLong("working-directory")])
  var workingDirectory = FileManager.default.currentDirectoryPath

  @Option(name: .customLong("session-store"), help: "Explicit session store root.")
  var sessionStore: String?

  @Flag(help: "Report what would be removed without changing files.")
  var dryRun = false

  @Option(help: "Override results age limit in days.") var resultsMaxAgeDays: Int?
  @Option(help: "Override results byte cap.") var resultsMaxTotalBytes: String?
  @Option(help: "Override messages age limit in days.") var messagesMaxAgeDays: Int?
  @Option(help: "Override messages byte cap.") var messagesMaxTotalBytes: String?
  @Option(help: "Override logs age limit in days.") var logsMaxAgeDays: Int?
  @Option(help: "Override logs byte cap.") var logsMaxTotalBytes: String?

  @Option(help: ArgumentHelp("Output format.", valueName: "text|json"))
  var output: String = "text"

  var overrides: RielaRetentionOverrides {
    get throws {
      RielaRetentionOverrides(resultsMaxAgeDays: resultsMaxAgeDays,
        resultsMaxTotalBytes: try byteCount(resultsMaxTotalBytes),
        messagesMaxAgeDays: messagesMaxAgeDays, messagesMaxTotalBytes: try byteCount(messagesMaxTotalBytes),
        logsMaxAgeDays: logsMaxAgeDays, logsMaxTotalBytes: try byteCount(logsMaxTotalBytes))
    }
  }

  mutating func validate() throws {
    guard ["text", "json"].contains(output) else { throw ValidationError("--output must be text or json") }
    _ = try overrides
    for (name, value) in [("results", resultsMaxAgeDays), ("messages", messagesMaxAgeDays), ("logs", logsMaxAgeDays)] {
      if let value, !(1...36_500).contains(value) { throw ValidationError("--\(name)-max-age-days must be between 1 and 36500") }
    }
  }

  private func byteCount(_ value: String?) throws -> Int64? {
    guard let value else { return nil }
    if let integer = Int64(value), integer > 0, integer <= (Int64(1) << 50) { return integer }
    do { return try RielaByteSize.parse(value) } catch { throw ValidationError(error.localizedDescription) }
  }
}

extension RielaGarbageCollectionScope: ExpressibleByArgument {}
