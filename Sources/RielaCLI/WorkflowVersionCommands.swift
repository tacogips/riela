#if canImport(Darwin)
#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RielaCore

public enum WorkflowVersionDifferenceKind: String, Codable, Equatable, Sendable {
  case added
  case removed
  case contentModified = "content-modified"
  case executableBitOnly = "executable-bit-only"
}

public struct WorkflowVersionDifference: Codable, Equatable, Sendable {
  public var relativePath: String
  public var kind: WorkflowVersionDifferenceKind
  public var from: WorkflowBundleSnapshotFile?
  public var to: WorkflowBundleSnapshotFile?
  public var content: WorkflowVersionContentDiff?
}

public struct WorkflowVersionsCommandResult: Codable, Equatable, Sendable {
  public var workflow: WorkflowBundleIdentity
  public var snapshots: [WorkflowSnapshotReference]
  public var nextBeforeSnapshotId: String?
}

public struct WorkflowVersionShowCommandResult: Codable, Equatable, Sendable {
  public var workflow: WorkflowBundleIdentity
  public var manifest: WorkflowBundleSnapshotManifest
  public var integrityVerified: Bool
  public var mutationReferences: [String]
  public var restoreReferences: [String]
}

public struct WorkflowVersionDiffCommandResult: Codable, Equatable, Sendable {
  public var workflow: WorkflowBundleIdentity
  public var from: String
  public var to: String
  public var differences: [WorkflowVersionDifference]
}

public struct WorkflowRestoreCommandResult: Codable, Equatable, Sendable {
  public var workflow: WorkflowBundleIdentity
  public var sourceSnapshotId: String
  public var dryRun: Bool
  public var approved: Bool
  public var restored: Bool
  public var beforeBundleDigest: String
  public var requestedBundleDigest: String
  public var preRestoreSnapshotId: String?
  public var restoreId: String?
  public var transactionId: String?
  public var restoredFiles: [String]
  public var dirtyConflicts: [String]
  public var validation: [LoopVerificationEvidence]
  public var reason: String?
  public var definitionVersionId: String?
  public var definitionAuditId: String?
  public var definitionWarnings: [String]?
}

public struct WorkflowVersionCommand: Sendable {
  private let service: WorkflowSnapshotService

  public init() { service = WorkflowSnapshotService() }

  init(resolver: any WorkflowBundleResolving, mutableRegistry: WorkflowMutableRegistry) {
    service = WorkflowSnapshotService(resolver: resolver, mutableRegistry: mutableRegistry)
  }

  public func run(_ options: WorkflowVersionCommandOptions) -> CLICommandResult {
    do {
      let parsed = try ParsedParityOptions(options.arguments)
      let output = try parseOutputOnly(options.arguments, allowTableOutput: false, defaultOutput: .json)
      let request = WorkflowSnapshotTargetRequest(workflowName: options.workflowName, scope: parsed.scope,
        workflowDefinitionDir: parsed.workflowDefinitionDir,
        workingDirectory: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath)
      switch options.kind {
      case .list:
        let result = try service.list(request, limit: parsed.limit ?? 100, beforeSnapshotId: parsed.beforeSnapshot)
        return try render(result, output: output) { $0.snapshots.map { "\($0.snapshotId) \($0.bundleDigest) integrity=verified" }.joined(separator: "\n") + "\n" }
      case .show:
        let result = try service.show(request, snapshotId: require(options.firstReference, "workflow version show requires a snapshot id"))
        return try render(result, output: output) { "snapshot \($0.manifest.snapshotId) \($0.manifest.bundleDigest) files=\($0.manifest.files.count) integrity=verified\n" }
      case .diff:
        let result = try service.diff(request, from: require(options.firstReference, "workflow version diff requires a from reference"),
          to: require(options.secondReference, "workflow version diff requires a to reference"), includeContent: parsed.content)
        return try render(result, output: output) { result in
          result.differences.map { difference in
            "\(difference.kind.rawValue) \(difference.relativePath)" + (difference.content?.unified.map { "\n" + $0.trimmingCharacters(in: .newlines) } ?? "")
          }.joined(separator: "\n") + "\n"
        }
      case .restore:
        let result = try service.restore(request, snapshotId: require(options.firstReference, "workflow restore requires a snapshot id"),
          approved: parsed.exactYes, reason: parsed.reason, actor: WorkflowDefinitionActor(kind: .cli, id: NSUserName()))
        return try render(result, output: output) {
          "restore snapshot=\($0.sourceSnapshotId) dryRun=\($0.dryRun) restored=\($0.restored) files=\($0.restoredFiles.count) conflicts=\($0.dirtyConflicts.count)\n"
            + ($0.definitionWarnings ?? []).map { "\($0)\n" }.joined()
        }
      }
    } catch let error as CLIUsageError {
      return CLICommandResult(exitCode: .usage, stderr: error.message + "\n")
    } catch {
      return CLICommandResult(exitCode: .failure, stderr: "\(error)\n")
    }
  }

  private func require(_ value: String?, _ message: String) throws -> String {
    guard let value else { throw CLIUsageError(message) }
    return value
  }

  private func render<T: Encodable>(
    _ value: T,
    output: WorkflowOutputFormat,
    text: (T) -> String
  ) throws -> CLICommandResult {
    if output == .text { return CLICommandResult(exitCode: .success, stdout: text(value)) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    guard let json = String(data: try encoder.encode(value), encoding: .utf8) else {
      throw CLIUsageError("unable to encode workflow version command output as UTF-8")
    }
    return CLICommandResult(exitCode: .success, stdout: json + "\n")
  }
}
