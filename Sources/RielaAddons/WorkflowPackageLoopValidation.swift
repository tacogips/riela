import Foundation

extension WorkflowPackageManifestValidator {
  static func validateLoopMetadata(_ loop: WorkflowPackageLoopMetadata?, into issues: inout [WorkflowPackageValidationIssue]) {
    guard let loop else {
      return
    }
    validatePromotionPaths(loop.requiredMockScenarios, path: "loop.requiredMockScenarios", into: &issues)
    validatePromotionPaths(loop.expectedResults, path: "loop.expectedResults", into: &issues)
    validateNonEmptyValues(loop.requiredGates, path: "loop.requiredGates", into: &issues)
    validateNonEmptyValues(loop.requiredPolicies, path: "loop.requiredPolicies", into: &issues)
    if let version = loop.minimumEvidenceSchemaVersion, version <= 0 {
      issues.append(.init(
        code: "INVALID_MANIFEST",
        path: "loop.minimumEvidenceSchemaVersion",
        message: "minimumEvidenceSchemaVersion must be greater than zero"
      ))
    }
    guard loop.promotionReady else {
      return
    }
    appendPromotionReadinessIssues(loop, into: &issues)
  }

  /// Ungated variant for advisory promotion reporting (`loop promote`):
  /// evaluates the promotion-ready manifest requirements regardless of
  /// `promotionReady`. Absent loop metadata reports a single issue rather
  /// than pretending the package is promotable.
  public static func loopPromotionReadinessIssues(
    _ loop: WorkflowPackageLoopMetadata?
  ) -> [WorkflowPackageValidationIssue] {
    guard let loop else {
      return [.init(
        code: "LOOP_PROMOTION",
        path: "loop",
        message: "package manifest declares no loop metadata"
      )]
    }
    var issues: [WorkflowPackageValidationIssue] = []
    appendPromotionReadinessIssues(loop, into: &issues)
    return issues
  }

  private static func appendPromotionReadinessIssues(
    _ loop: WorkflowPackageLoopMetadata,
    into issues: inout [WorkflowPackageValidationIssue]
  ) {
    if !loop.usageContract {
      issues.append(.init(
        code: "INVALID_MANIFEST",
        path: "loop.usageContract",
        message: "promotion-ready packages require usageContract"
      ))
    }
    requireNonEmptyList(loop.requiredMockScenarios, path: "loop.requiredMockScenarios", into: &issues)
    requireNonEmptyList(loop.expectedResults, path: "loop.expectedResults", into: &issues)
    requireNonEmptyList(loop.requiredGates, path: "loop.requiredGates", into: &issues)
    requireNonEmptyList(loop.requiredPolicies, path: "loop.requiredPolicies", into: &issues)
    if loop.minimumEvidenceSchemaVersion == nil {
      issues.append(.init(
        code: "INVALID_MANIFEST",
        path: "loop.minimumEvidenceSchemaVersion",
        message: "promotion-ready packages require minimumEvidenceSchemaVersion"
      ))
    }
  }

  private static func validatePromotionPaths(
    _ paths: [String],
    path: String,
    into issues: inout [WorkflowPackageValidationIssue]
  ) {
    for (index, value) in paths.enumerated() {
      guard normalizePackageRelativePath(value) != nil else {
        issues.append(.init(code: "INVALID_MANIFEST", path: "\(path)[\(index)]", message: "\(path) entries must be safe package-relative paths"))
        continue
      }
      if value == "." {
        issues.append(.init(code: "INVALID_MANIFEST", path: "\(path)[\(index)]", message: "\(path) entries must point to files"))
      }
    }
  }

  private static func validateNonEmptyValues(
    _ values: [String],
    path: String,
    into issues: inout [WorkflowPackageValidationIssue]
  ) {
    for (index, value) in values.enumerated() where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      issues.append(.init(code: "INVALID_MANIFEST", path: "\(path)[\(index)]", message: "\(path) entries must be non-empty"))
    }
  }

  private static func requireNonEmptyList(
    _ values: [String],
    path: String,
    into issues: inout [WorkflowPackageValidationIssue]
  ) {
    if values.isEmpty {
      issues.append(.init(code: "INVALID_MANIFEST", path: path, message: "promotion-ready packages require \(path)"))
    }
  }
}
