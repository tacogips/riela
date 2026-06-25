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
    var issues = WorkflowPackageManifestValidator.validate(manifest)
    issues.append(contentsOf: WorkflowPackageManifestValidator.validateWorkflowBundle(manifest, packageRoot: packageRoot))
    issues.append(contentsOf: WorkflowPackageManifestValidator.validateLoopPromotionArtifacts(manifest.loop, packageRoot: packageRoot))
    return issues
  }
}
