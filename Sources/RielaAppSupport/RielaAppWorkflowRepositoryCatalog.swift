#if os(macOS)
import Foundation

private enum MinimalDependencyCodingKeys: String, CodingKey {
  case packageId
}

public struct RielaAppRemoteWorkflowListing: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case workflowDirectory
    case packageWorkflow
  }

  public var repositoryId: String
  public var workflowId: String
  public var title: String
  public var summary: String
  public var relativePath: String
  public var installSourceURL: URL
  public var workflowDirectoryURL: URL
  public var kind: Kind
  public var packageName: String?

  public init(
    repositoryId: String,
    workflowId: String,
    title: String,
    summary: String,
    relativePath: String,
    installSourceURL: URL,
    workflowDirectoryURL: URL? = nil,
    kind: Kind,
    packageName: String? = nil
  ) {
    self.repositoryId = repositoryId
    self.workflowId = workflowId
    self.title = title
    self.summary = summary
    self.relativePath = relativePath
    self.installSourceURL = installSourceURL
    self.workflowDirectoryURL = workflowDirectoryURL ?? installSourceURL
    self.kind = kind
    self.packageName = packageName
  }
}

public struct RielaAppWorkflowRepositoryCatalog: Equatable, Sendable {
  public var repository: RielaAppWorkflowRepositoryReference
  public var workflows: [RielaAppRemoteWorkflowListing]

  public init(repository: RielaAppWorkflowRepositoryReference, workflows: [RielaAppRemoteWorkflowListing]) {
    self.repository = repository
    self.workflows = workflows
  }
}

public enum RielaAppWorkflowRepositoryCatalogScanner {
  static let manifestFileName = "riela-package.json"
  static let workflowFileName = "workflow.json"
  static let maximumScanDepth = 8

  private struct MinimalWorkflow: Decodable {
    var workflowId: String
    var description: String?
    var steps: [MinimalStep]?
  }

  private struct MinimalStep: Decodable {
    var transitions: [MinimalTransition]?
  }

  private struct MinimalTransition: Decodable {
    var toWorkflowId: String?
  }

  private struct MinimalManifestWorkflow: Decodable {
    var title: String?
    var description: String?
  }

  private struct MinimalManifest: Decodable {
    var name: String?
    var title: String?
    var description: String?
    var workflow: MinimalManifestWorkflow?
    var workflows: [MinimalManifestWorkflow]?
    var dependencies: [MinimalDependency]?
  }

  private struct MinimalDependency: Decodable {
    var packageId: String

    init(from decoder: Decoder) throws {
      if let packageId = try? decoder.singleValueContainer().decode(String.self) {
        self.packageId = packageId
        return
      }
      let container = try decoder.container(keyedBy: MinimalDependencyCodingKeys.self)
      self.packageId = try container.decode(String.self, forKey: .packageId)
    }
  }

  public static func scan(repositoryRoot: URL, repositoryId: String) -> [RielaAppRemoteWorkflowListing] {
    let repositoryRoot = repositoryRoot.standardizedFileURL
    var workflowDirectories: [URL] = []
    collectWorkflowDirectories(in: repositoryRoot, depth: 0, into: &workflowDirectories)
    var seen = Set<String>()
    var listings: [RielaAppRemoteWorkflowListing] = []
    for workflowDirectory in workflowDirectories {
      guard let listing = listing(
        workflowDirectory: workflowDirectory,
        repositoryRoot: repositoryRoot,
        repositoryId: repositoryId
      ) else {
        continue
      }
      let key = "\(listing.relativePath)\u{1f}\(listing.workflowId)"
      guard !seen.contains(key) else {
        continue
      }
      seen.insert(key)
      listings.append(listing)
    }
    let rootListings = rootWorkflowListings(from: listings)
    return rootListings.sorted {
      if $0.title.localizedCaseInsensitiveCompare($1.title) != .orderedSame {
        return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
      }
      return $0.relativePath < $1.relativePath
    }
  }

  private static func rootWorkflowListings(
    from listings: [RielaAppRemoteWorkflowListing]
  ) -> [RielaAppRemoteWorkflowListing] {
    let listedWorkflowIds = Set(listings.map(\.workflowId))
    let listedPackageNames = Set(listings.compactMap(\.packageName))
    let calledWorkflowIds = Set(listings.flatMap { listing in
      referencedWorkflowIds(in: listing.workflowDirectoryURL)
    }).intersection(listedWorkflowIds)
    let dependencyPackageNames = Set(listings.flatMap { listing in
      guard listing.kind == .packageWorkflow,
        let manifest = decodeManifest(at: listing.installSourceURL) else {
        return [String]()
      }
      return (manifest.dependencies ?? []).map(\.packageId)
    }).intersection(listedPackageNames)
    return listings.filter { listing in
      !calledWorkflowIds.contains(listing.workflowId)
        && !dependencyPackageNames.contains(listing.packageName ?? "")
    }
  }

  private static func referencedWorkflowIds(in workflowDirectory: URL) -> [String] {
    let workflowURL = workflowDirectory.appendingPathComponent(workflowFileName)
    guard let data = try? Data(contentsOf: workflowURL),
      let workflow = try? JSONDecoder().decode(MinimalWorkflow.self, from: data) else {
      return []
    }
    return (workflow.steps ?? []).flatMap { step in
      (step.transitions ?? []).compactMap(\.toWorkflowId)
    }
  }

  private static func collectWorkflowDirectories(in directory: URL, depth: Int, into results: inout [URL]) {
    guard depth <= maximumScanDepth else {
      return
    }
    // Child URLs are built from names so every URL keeps the repository root's
    // path prefix; contentsOfDirectory(at:) would return canonicalized paths
    // (e.g. /private/var vs /var) that break relative-path derivation.
    let childNames = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
      .filter { !$0.hasPrefix(".") }
      .sorted()
    if childNames.contains(workflowFileName) {
      results.append(directory)
    }
    for childName in childNames {
      let child = directory.appendingPathComponent(childName, isDirectory: true)
      guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
        values.isDirectory == true,
        values.isSymbolicLink != true else {
        continue
      }
      collectWorkflowDirectories(in: child, depth: depth + 1, into: &results)
    }
  }

  private static func listing(
    workflowDirectory: URL,
    repositoryRoot: URL,
    repositoryId: String
  ) -> RielaAppRemoteWorkflowListing? {
    let workflowURL = workflowDirectory.appendingPathComponent(workflowFileName)
    guard
      let data = try? Data(contentsOf: workflowURL),
      let workflow = try? JSONDecoder().decode(MinimalWorkflow.self, from: data),
      !workflow.workflowId.isEmpty
    else {
      return nil
    }
    let packageRoot = enclosingPackageRoot(of: workflowDirectory, repositoryRoot: repositoryRoot)
    let manifest = packageRoot.flatMap(decodeManifest(at:))
    let installSource = packageRoot ?? workflowDirectory
    let manifestWorkflow = manifest.flatMap(singleManifestWorkflow)
    let title = manifestWorkflow?.title ?? workflow.workflowId
    let summary = firstNonEmpty([
      workflow.description,
      manifestWorkflow?.description,
      manifest?.description
    ]) ?? ""
    return RielaAppRemoteWorkflowListing(
      repositoryId: repositoryId,
      workflowId: workflow.workflowId,
      title: title,
      summary: summary,
      relativePath: relativePath(of: installSource, under: repositoryRoot),
      installSourceURL: installSource,
      workflowDirectoryURL: workflowDirectory,
      kind: packageRoot == nil ? .workflowDirectory : .packageWorkflow,
      packageName: manifest?.name
    )
  }

  private static func enclosingPackageRoot(of workflowDirectory: URL, repositoryRoot: URL) -> URL? {
    var current = workflowDirectory
    let rootPath = repositoryRoot.path
    while current.path.hasPrefix(rootPath) {
      if FileManager.default.fileExists(atPath: current.appendingPathComponent(manifestFileName).path) {
        return current
      }
      guard current.path != rootPath else {
        return nil
      }
      current = current.deletingLastPathComponent().standardizedFileURL
    }
    return nil
  }

  private static func decodeManifest(at packageRoot: URL) -> MinimalManifest? {
    let manifestURL = packageRoot.appendingPathComponent(manifestFileName)
    guard let data = try? Data(contentsOf: manifestURL) else {
      return nil
    }
    return try? JSONDecoder().decode(MinimalManifest.self, from: data)
  }

  private static func singleManifestWorkflow(_ manifest: MinimalManifest) -> MinimalManifestWorkflow? {
    if let workflow = manifest.workflow, (manifest.workflows ?? []).isEmpty {
      return workflow
    }
    if manifest.workflow == nil, let workflows = manifest.workflows, workflows.count == 1 {
      return workflows[0]
    }
    return nil
  }

  private static func firstNonEmpty(_ values: [String?]) -> String? {
    values.compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }

  private static func relativePath(of directory: URL, under repositoryRoot: URL) -> String {
    let rootComponents = repositoryRoot.pathComponents
    let directoryComponents = directory.pathComponents
    guard directoryComponents.count >= rootComponents.count,
      Array(directoryComponents.prefix(rootComponents.count)) == rootComponents else {
      return directory.lastPathComponent
    }
    let relative = directoryComponents.dropFirst(rootComponents.count).joined(separator: "/")
    return relative.isEmpty ? "." : relative
  }
}
#endif
