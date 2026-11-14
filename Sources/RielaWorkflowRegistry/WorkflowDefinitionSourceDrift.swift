import Foundation
import RielaCore

public enum WorkflowDefinitionSourceDriftResult: String, Codable, Equatable, Sendable {
  case inSync, autoSync, drift, sourceInvalid, sourceUnavailable
}

public struct WorkflowDefinitionSourceDriftReport: Codable, Equatable, Sendable {
  public var workflowName: String
  public var currentVersionId: String
  public var lastFileVersionId: String
  public var sourceDirectory: String
  public var result: WorkflowDefinitionSourceDriftResult
  public var fileDigest: String?
  public var baselineDigest: String?
  public var currentDigest: String
  public var detail: String?
}

public struct WorkflowDefinitionSourceSyncOutcome: Sendable {
  public var report: WorkflowDefinitionSourceDriftReport
  public var bundle: ResolvedWorkflowBundle
  public var diagnostics: [WorkflowValidationDiagnostic]
  public var syncedVersion: WorkflowDefinitionVersion?
  public var audit: WorkflowDefinitionAuditRecord?
}

public enum WorkflowDefinitionSourceDrift {
  public static let autoSyncActorId = "service-auto-sync"

  public static func classify(fileDigest: String?, fileProblem: WorkflowDefinitionSourceDriftResult?,
                              baselineDigest: String?, currentDigest: String, currentVersionId: String,
                              lastFileVersionId: String, currentOperation: WorkflowDefinitionOperation) -> WorkflowDefinitionSourceDriftResult {
    if let fileProblem { return fileProblem }
    if let fileDigest, fileDigest == baselineDigest || fileDigest == currentDigest { return .inSync }
    let untouched = currentVersionId == lastFileVersionId
    if baselineDigest == nil {
      return untouched && [.seed, .import, .forceUpdate].contains(currentOperation) ? .autoSync : .drift
    }
    return untouched ? .autoSync : .drift
  }

  public static func diagnostic(for report: WorkflowDefinitionSourceDriftReport, path: String,
                                syncedVersionId: String?, auditId: String?) -> WorkflowValidationDiagnostic {
    let name = report.workflowName
    var message = "Workflow \(name): current version \(report.currentVersionId), last-file version \(report.lastFileVersionId), "
      + "file digest \(report.fileDigest ?? "unavailable"), baseline digest \(report.baselineDigest ?? "unavailable"), "
      + "current digest \(report.currentDigest)."
    switch path {
    case "definitionStore.sourceDrift":
      message += " Inspect with riela workflow definition diff \(name) --file; adopt with riela instance reload or "
        + "riela workflow definition import \(name) --force --reason; or export with "
        + "riela workflow definition export \(name) --to-source --overwrite."
    case "definitionStore.sourceInvalid":
      message += " \(report.detail ?? "Invalid source"); fix the file; the stored head stays in use."
    case "definitionStore.autoSynced":
      message += " Auto-synced version \(syncedVersionId ?? "unavailable"), audit \(auditId ?? "unavailable")."
    default:
      if let detail = report.detail { message += " \(detail)" }
    }
    return WorkflowValidationDiagnostic(severity: .warning, path: path, message: message)
  }
}
