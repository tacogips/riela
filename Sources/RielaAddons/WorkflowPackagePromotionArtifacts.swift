import Foundation

extension WorkflowPackageManifestValidator {
  public static func validateLoopPromotionArtifacts(
    _ loop: WorkflowPackageLoopMetadata?,
    packageRoot: URL
  ) -> [WorkflowPackageValidationIssue] {
    guard let loop, loop.promotionReady else {
      return []
    }
    return loopPromotionArtifactIssues(loop, packageRoot: packageRoot)
  }

  /// Ungated variant for advisory promotion reporting (`loop promote`):
  /// checks the declared promotion artifacts regardless of `promotionReady`.
  public static func loopPromotionArtifactIssues(
    _ loop: WorkflowPackageLoopMetadata?,
    packageRoot: URL
  ) -> [WorkflowPackageValidationIssue] {
    guard let loop else {
      return []
    }
    var issues: [WorkflowPackageValidationIssue] = []
    validatePromotionArtifactFiles(
      loop.requiredMockScenarios,
      path: "loop.requiredMockScenarios",
      packageRoot: packageRoot,
      into: &issues
    )
    validatePromotionArtifactFiles(
      loop.expectedResults,
      path: "loop.expectedResults",
      packageRoot: packageRoot,
      into: &issues
    )
    return issues
  }

  private static func validatePromotionArtifactFiles(
    _ paths: [String],
    path: String,
    packageRoot: URL,
    into issues: inout [WorkflowPackageValidationIssue]
  ) {
    for (index, rawPath) in paths.enumerated() {
      guard let normalized = normalizePackageRelativePath(rawPath), normalized != "." else {
        continue
      }
      let url = packageRoot.appendingPathComponent(normalized, isDirectory: false)
      var isDirectory: ObjCBool = false
      if !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) || isDirectory.boolValue {
        issues.append(.init(
          code: "MISSING_PROMOTION_ARTIFACT",
          path: "\(path)[\(index)]",
          message: "required promotion artifact not found: \(normalized)"
        ))
      }
    }
  }
}
