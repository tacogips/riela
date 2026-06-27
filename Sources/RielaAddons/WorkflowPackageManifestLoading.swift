import Foundation

public protocol WorkflowPackageManifestLoading: Sendable {
  func loadManifest(from url: URL) async throws -> WorkflowPackageManifest
  func validate(_ manifest: WorkflowPackageManifest, packageRoot: URL) async -> [WorkflowPackageValidationIssue]
}

public enum WorkflowPackageManifestLoadingError: Error, Equatable, Sendable {
  case nonFileURL(String)
}

public struct FileWorkflowPackageManifestLoader: WorkflowPackageManifestLoading {
  public init() {}

  public func loadManifest(from url: URL) async throws -> WorkflowPackageManifest {
    guard url.isFileURL else {
      throw WorkflowPackageManifestLoadingError.nonFileURL(url.absoluteString)
    }
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(WorkflowPackageManifest.self, from: data)
  }

  public func validate(_ manifest: WorkflowPackageManifest, packageRoot: URL) async -> [WorkflowPackageValidationIssue] {
    WorkflowPackageManifestValidator.validatePackageSource(manifest, packageRoot: packageRoot)
  }
}

public extension WorkflowPackageManifestValidator {
  static func validatePackageSource(
    _ manifest: WorkflowPackageManifest,
    packageRoot: URL
  ) -> [WorkflowPackageValidationIssue] {
    var issues = validate(manifest)
    issues.append(contentsOf: validateWorkflowBundle(manifest, packageRoot: packageRoot))
    issues.append(contentsOf: validateLoopPromotionArtifacts(manifest.loop, packageRoot: packageRoot))
    return issues
  }
}
